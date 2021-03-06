defmodule Kastlex.API.V1.MessageController do

  require Logger
  require Record

  use Kastlex.Web, :controller

  import Record, only: [defrecord: 2, extract: 2]
  defrecord :kafka_message, extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  defrecord :kpro_rsp, extract(:kpro_rsp, from_lib: "kafka_protocol/include/kpro.hrl")

  plug Kastlex.Plug.EnsurePermissions

  def produce(conn, %{"topic" => topic, "partition" => partition} = params) do
    {partition, _} = Integer.parse(partition)
    key = Map.get(params, "key", "")
    {:ok, value, conn} = read_body(conn)
    try_produce(conn, topic, [partition], key, value, nil)
  end

  # no partition, use random partitioner
  def produce(conn, %{"topic" => topic} = params) do
    key = Map.get(params, "key", "")
    {:ok, value, conn} = read_body(conn)
    case :brod_client.get_partitions_count(:kastlex, topic) do
      {:ok, partitions_cnt} ->
        partitions = :lists.seq(0, partitions_cnt - 1) |> Enum.shuffle
        try_produce(conn, topic, partitions, key, value, nil)
      {:error, :UnknownTopicOrPartition} = error ->
        Logger.error("#{inspect error}")
        send_json(conn, 404, Map.new([error]))
      {:error, _} = error ->
        Logger.error("#{inspect error}")
        send_json(conn, 503, Map.new([error]))
    end
  end

  defp try_produce(conn, _topic, [], _key, _value, error) do
    Logger.error("#{inspect error}")
    send_json(conn, 503, Map.new([error]))
  end
  defp try_produce(conn, topic, [p | partitions], key, value, _last_error) do
    case :brod.produce_sync(:kastlex, topic, p, key, value) do
      :ok ->
        send_resp(conn, 204, "")
      {:error, :UnknownTopicOrPartition} = error ->
        Logger.error("#{inspect error}")
        # does not make sense to try other partitions
        send_json(conn, 404, Map.new([error]))
      {:error, {:producer_not_found, _topic}} = error ->
        Logger.error("#{inspect error}")
        # does not make sense to try other partitions
        send_json(conn, 404, Map.new([{:error, :UnknownTopicOrPartition}]))
      {:error, {:producer_not_found, _topic, _p}} = error ->
        Logger.error("#{inspect error}")
        # does not make sense to try other partitions
        send_json(conn, 404, Map.new([{:error, :UnknownTopicOrPartition}]))
      {:error, :LeaderNotAvailable} = error ->
        Logger.error("#{inspect error}")
        try_produce(conn, topic, partitions, key, value, error)
      {:error, :NotLeaderForPartition} = error ->
        Logger.error("#{inspect error}")
        try_produce(conn, topic, partitions, key, value, error)
      error ->
        Logger.error("#{inspect error}")
        send_json(conn, 503, Map.new([error]))
    end
  end

  def fetch(%{assigns: %{type: type}} = conn, params) do
    topic = params["topic"]
    {partition, _} = Integer.parse(params["partition"])
    orig_offset = Map.get(params, "offset", "latest")
    case :brod_client.get_partitions_count(Kastlex.get_brod_client_id(), topic) do
      {:ok, partitions_cnt} when partition >= 0 and partition < partitions_cnt ->
        case :brod_client.get_leader_connection(Kastlex.get_brod_client_id(), topic, partition) do
          {:ok, pid} ->
            case resolve_offset(pid, topic, partition, orig_offset) do
              {:ok, offset} ->
                {max_wait_time, _} = Integer.parse(Map.get(params, "max_wait_time", "1000"))
                {min_bytes, _} = Integer.parse(Map.get(params, "min_bytes", "1"))
                {max_bytes, _} = Integer.parse(Map.get(params, "max_bytes", "104857600")) # 100 kB
                request = :kpro.fetch_request(_vsn = 0,
                                              topic,
                                              partition,
                                              offset,
                                              max_wait_time,
                                              min_bytes,
                                              max_bytes)
                response = :brod_sock.request_sync(pid, request, :infinity) |> handle_fetch_response(type, offset)
                respond(conn, response, type)
              error ->
                Logger.error "Cannot resolve logical offset #{orig_offset}: #{inspect error}"
                send_json(conn, 503, %{error: "Cannot resolve logical offset #{orig_offset}"})
            end
          {:error, :UnknownTopicOrPartition} = error ->
            send_json(conn, 404, Map.new([error]))
          {:error, :LeaderNotAvailable} = error ->
            send_json(conn, 503, Map.new([error]))
        end
      {:error, :UnknownTopicOrPartition} = error ->
        send_json(conn, 404, Map.new([error]))
      {:error, _} = error ->
        send_json(conn, 503, Map.new([error]))
    end
  end

  defp handle_fetch_response({:error, _} = error, _type, _offset), do: error
  defp handle_fetch_response({:ok, response}, type, offset) do
    [topic_response] = kpro_rsp(response)[:msg][:responses]
    [partition_response] = topic_response[:partition_responses]
    messages = :brod_utils.decode_messages(offset, partition_response[:record_set])
    case type do
      "json" ->
        messages = messages |> Enum.map(&transform_kafka_message/1)
        resp = %{size: nil,
                 highWmOffset: partition_response[:partition_header][:high_watermark],
                 error_code: partition_response[:partition_header][:error_code],
                 messages: messages
                }
        {:ok, resp}
      "binary" ->
        payload = messages |> hd |> kafka_message(:value) |> undef_to_empty
        resp = %{payload: payload,
                 high_watermark: partition_response[:partition_header][:high_watermark]
                }
        {:ok, resp}
    end
  end

  defp transform_kafka_message(raw_msg) do
    msg = kafka_message(raw_msg)
    %{key: undef_to_nil(msg[:key]),
      value: undef_to_nil(msg[:value]),
      offset: msg[:offset],
      crc: msg[:crc]
     }
  end

  defp undef_to_nil(:undefined), do: nil
  defp undef_to_nil(x),          do: x

  defp undef_to_empty(:undefined), do: ""
  defp undef_to_empty(x),          do: x

  defp respond(conn, {:ok, resp}, "json"), do: json(conn, resp)
  defp respond(conn, {:ok, resp}, "binary") do
    conn
    |> put_resp_content_type("application/binary")
    |> put_resp_header("x-high-wm-offset", Integer.to_string(resp.high_watermark))
    |> send_resp(200, resp.payload)
  end
  defp respond(conn, {:error, reason}, "json") do
    send_json(conn, 503, %{error: reason})
  end
  defp respond(conn, {:error, reason}, "binary") do
    send_resp(conn, 503, "error: #{inspect reason}")
  end

  defp resolve_offset(pid, t, p, orig_offset) do
    offset = Kastlex.KafkaUtils.parse_logical_offset(orig_offset)
    case offset < 0 do
      true ->
        do_resolve_offset(pid, t, p, offset)
      false ->
        {:ok, offset}
    end
  end

  defp do_resolve_offset(pid, t, p, logical_offset) do
    case :brod_utils.resolve_offset(pid, t, p, logical_offset) do
      {:ok, offset} ->
        case logical_offset == -1 do # latest
          true -> {:ok, offset-1}
          false -> {:ok, offset}
        end
      {:error, _} = error ->
        error
    end
  end

end

