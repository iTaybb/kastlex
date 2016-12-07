defmodule Kastlex.CgStatusCollector do
  require Logger
  require Record
  use GenServer
  import Record, only: [defrecord: 2, extract: 2]
  defrecord :kafka_message_set, extract(:kafka_message_set, from_lib: "brod/include/brod.hrl")
  defrecord :kafka_message, extract(:kafka_message, from_lib: "brod/include/brod.hrl")

  @server __MODULE__
  @topic "__consumer_offsets"

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, [name: @server])
  end

  def init(options) do
    Kastlex.MetadataCache.sync()
    {:ok, topics} = Kastlex.MetadataCache.get_topics()
    case Enum.find(topics, nil, fn(x) -> x.topic == @topic end) do
      nil ->
        Logger.info "#{@topic} topic not found, skip cg_status_collector"
        :ignore
      _ ->
        send self(), {:post_init, options}
        {:ok, %{}}
    end
  end

  def handle_info({:post_init, options}, state) do
    client = options.brod_client_id
    cache_dir = Application.get_env(:kastlex, :cg_cache_dir, :priv)
    :ok = Kastlex.CgCache.init(cache_dir)
    cg_exclude_regex = Application.get_env(:kastlex, :cg_exclude_regex, nil)
    exclude =
      case cg_exclude_regex do
        nil ->
          fn(_group_id) -> false end
        regex ->
          re = Regex.compile!(regex)
          f = fn(group_id) -> Regex.match?(re, group_id) end
          :ok = Kastlex.CgCache.maybe_delete_excluded(f)
          f
      end
    {:ok, partitions_count} = :brod.get_partitions_count(client, @topic)
    :brod.start_consumer(client, @topic, [])
    workers = for partition <- 0..(partitions_count-1) do
                spawn_link fn -> subscriber(client, partition, exclude) end
              end
    {:noreply, Map.put(state, :workers, workers)}
  end

  def terminate(_reason, _state) do
    Kastlex.CgCache.close()
  end

  def subscriber(client, partition, exclude) do
    begin_offset =
      case Kastlex.CgCache.get_progress(partition) do
        false  -> :earliest
        offset -> offset + 1
      end
    options = [{:begin_offset, begin_offset},
               {:prefetch_count, 1_000}
              ]
    case :brod.subscribe(client, self(), @topic, partition, options) do
      {:ok, pid} ->
        _ = Process.monitor(pid)
        state = %{ client: client,
                   partition: partition,
                   exclude: exclude,
                   consumer_pid: pid
                 }
        __MODULE__.subscriber_loop(state)
      {:error, _reason} ->
        # consumer down, client down, etc.
        # try again later
        :timer.sleep(10_000)
        Logger.info "cg collector #{partition} retry subscription"
        __MODULE__.subscriber(client, partition, exclude)
    end
  end

  def subscriber_loop(%{ client: client,
                         partition: partition,
                         exclude: exclude,
                         consumer_pid: pid
                       } = state) do
    receive do
      {^pid, msg_set} ->
        messages = compact_messages(msg_set)
        last_offset = kafka_message(List.last(messages), :offset)
        ## ack now so consumer can fetch more while we are processing the compacted ones
        :ok = :brod.consume_ack(pid, last_offset)
        Enum.each(messages, fn(msg) -> handle_message(msg, exclude) end)
        ## commit offset locally in dets
        Kastlex.CgCache.update_progress(partition, last_offset)
        __MODULE__.subscriber_loop(state)
      {:DOWN, _ref, :process, ^pid, _reason} ->
        ## consumer pid died, we start over
        __MODULE__.subscriber(client, partition, exclude)
      unknown ->
        Logger.info "cg collector #{partition} discarded unknown message #{inspect unknown}"
        __MODULE__.subscriber_loop(state)
    after
      1_000 ->
        __MODULE__.subscriber_loop(state)
    end
    __MODULE__.subscriber_loop(state)
  end

  ## compaction might have not yet done in kafka log segment
  ## here we do the compaction to avoid excessive writes to dets
  defp compact_messages(msg_set) do
    messages = kafka_message_set(msg_set, :messages)
    ## scan the messages in reversed order
    compact_messages(Enum.reverse(messages), [], MapSet.new())
  end

  defp compact_messages([], acc, _key_set), do: acc
  defp compact_messages([msg | rest], acc, key_set) do
    key = kafka_message(msg, :key)
    case MapSet.member?(key_set, key) do
      true ->
        ## the messages are being scaned in a reversed order
        ## an 'already-seen' key means the key appeared in a
        ## 'later' offset, therefore we can discard it
        compact_messages(rest, acc, key_set)
      false ->
        compact_messages(rest, [msg | acc], MapSet.put(key_set, key))
    end
  end

  defp handle_message(msg, exclude) do
    key_bin = kafka_message(msg, :key)
    value_bin = kafka_message(msg, :value)
    {tag, key, value} = :kpro_consumer_group.decode(key_bin, value_bin)
    case exclude.(key[:group_id]) do
      true ->
        :ok
      false ->
        case tag do
          :offset -> Kastlex.CgCache.committed_offset(key, value)
          :group -> Kastlex.CgCache.new_cg_status(key, value)
        end
        :ok
    end
  end
end

