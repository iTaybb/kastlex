defmodule Kastlex do
  use Application

  require Logger

  @anon "anonymous"

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    endpoint = Application.fetch_env!(:kastlex, Kastlex.Endpoint)
    http = endpoint[:http]
    port = system_env("KASTLEX_HTTP_PORT", http[:port])
    Logger.info "HTTP port: #{port}"
    http = Keyword.put(http, :port, port)
    Application.put_env(:kastlex, Kastlex.Endpoint, Keyword.put(endpoint, :http, http))

    maybe_init_https(System.get_env("KASTLEX_USE_HTTPS"))
    maybe_set_secret_key_base(System.get_env("KASTLEX_SECRET_KEY_BASE"))
    maybe_set_guardian_secret_key(System.get_env("KASTLEX_JWK_FILE"))
    kafka_endpoints = parse_endpoints(System.get_env("KASTLEX_KAFKA_CLUSTER"), [{'localhost', 9092}])
    Logger.info "Kafka endpoints: #{inspect kafka_endpoints}"

    permissions_file_path = system_env("KASTLEX_PERMISSIONS_FILE_PATH", "permissions.yml")
    Logger.info "Permissions file path: #{permissions_file_path}"
    passwd_file_path = system_env("KASTLEX_PASSWD_FILE_PATH", "passwd.yml")
    Logger.info "Passwd file path: #{passwd_file_path}"
    cg_cache_dir = system_env("KASTLEX_CG_CACHE_DIR", :priv)
    Logger.info "Consumer groups cache directory: #{cg_cache_dir}"
    cg_exclude_regex = system_env("KASTLEX_CG_EXCLUDE_REGEX", nil)
    maybe_log_parameter("Consumer groups exclude regexp", cg_exclude_regex)

    Application.put_env(:kastlex, :permissions_file_path, permissions_file_path)
    Application.put_env(:kastlex, :passwd_file_path, passwd_file_path)
    Application.put_env(:kastlex, :cg_cache_dir, cg_cache_dir)
    Application.put_env(:kastlex, :cg_exclude_regex, cg_exclude_regex)

    maybe_configure_token_storage(System.get_env("KASTLEX_ENABLE_TOKEN_STORAGE"))
    maybe_set_token_ttl(System.get_env("KASTLEX_TOKEN_TTL_SECONDS"))

    brod_client_config = [{:allow_topic_auto_creation, false},
                          {:auto_start_producers, true}]
    :ok = :brod.start_client(kafka_endpoints, :kastlex, brod_client_config)

    children = [
      # Start the endpoint when the application starts
      supervisor(Kastlex.Endpoint, []),
      supervisor(Phoenix.PubSub.PG2, [Kastlex.PubSub, []]),
      worker(Kastlex.Users, []),
      worker(Kastlex.TokenStorage, [%{brod_client_id: :kastlex}]),
      supervisor(Kastlex.Collectors, [])
    ]

    opts = [strategy: :one_for_one, name: Kastlex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    Kastlex.Endpoint.config_change(changed, removed)
    :ok
  end

  def get_user(name) do
    Kastlex.Users.get_user(name)
  end

  def get_anonymous(), do: get_user(@anon)

  def reload() do
    Kastlex.Users.reload()
  end

  def parse_endpoints(nil, default), do: default
  def parse_endpoints(endpoints, _default) do
    endpoints
      |> String.split(",")
      |> Enum.map(&String.split(&1, ":"))
      |> Enum.map(fn([host, port]) -> {:erlang.binary_to_list(host),
                                       :erlang.binary_to_integer(port)} end)
  end

  def token_storage_enabled?() do
    guardian = Application.fetch_env!(:guardian, Guardian)
    guardian[:hooks] == Kastlex.TokenStorage
  end

  defp maybe_init_https(nil), do: :ok
  defp maybe_init_https("true") do
    Logger.info "Using HTTPS"
    port = system_env("KASTLEX_HTTPS_PORT", 8093)
    Logger.info "HTTPS port: #{port}"
    keyfile = system_env("KASTLEX_KEYFILE", "/etc/kastlex/ssl/server.key")
    Logger.info "Keyfile: #{keyfile}"
    certfile = system_env("KASTLEX_CERTFILE", "/etc/kastlex/ssl/server.crt")
    Logger.info "certfile: #{certfile}"
    cacertfile = system_env("KASTLEX_CACERTFILE", "/etc/kastlex/ssl/ca-cert.crt")
    Logger.info "cacertfile: #{cacertfile}"
    config = [port: port, keyfile: keyfile, certfile: certfile, cacertfile: cacertfile]
    endpoint = Application.fetch_env!(:kastlex, Kastlex.Endpoint)
    Application.put_env(:kastlex, Kastlex.Endpoint, Keyword.put(endpoint, :https, config))
  end
  defp maybe_init_https(_), do: :ok

  defp maybe_set_secret_key_base(nil), do: :ok
  defp maybe_set_secret_key_base(secret_key_base) do
    Logger.info "Using custom secret key base from file: #{secret_key_base}"
    endpoint = Application.fetch_env!(:kastlex, Kastlex.Endpoint)
    Application.put_env(:kastlex, Kastlex.Endpoint,
                        Keyword.put(endpoint, :secret_key_base, secret_key_base))
  end

  defp maybe_set_guardian_secret_key(nil), do: :ok
  defp maybe_set_guardian_secret_key(file) do
    Logger.info "Using custom jwk from file: #{file}"
    jwk = JOSE.JWK.from_pem_file(file)
    guardian = Application.fetch_env!(:guardian, Guardian)
    Application.put_env(:guardian, Guardian,
                        Keyword.put(guardian, :secret_key, jwk))
  end

  defp maybe_configure_token_storage(nil), do: :ok
  defp maybe_configure_token_storage("1") do
    Logger.info "OS env override: enabling token storage"
    guardian = Application.fetch_env!(:guardian, Guardian)
    Application.put_env(:guardian, Guardian,
                        Keyword.put(guardian, :hooks, Kastlex.TokenStorage))
    case System.get_env("KASTLEX_TOKEN_STORAGE_TOPIC") do
      nil -> :ok
      topic ->
        Application.put_env(:kastlex, Kastlex.TokenStorage, [topic: topic])
        Logger.info "Custom token storage topic: #{topic}"
    end
  end
  defp maybe_configure_token_storage(_), do: :ok

  defp maybe_set_token_ttl(nil), do: :ok
  defp maybe_set_token_ttl(ttl) do
    Logger.info "Using custom token ttl: #{ttl} seconds"
    {ttl, _} = Integer.parse(ttl)
    guardian = Application.fetch_env!(:guardian, Guardian)
    Application.put_env(:guardian, Guardian,
                        Keyword.put(guardian, :ttl, {ttl, :seconds}))
  end

  defp system_env(variable, default) do
    case System.get_env(variable) do
      nil -> default
      value -> value
    end
  end

  defp maybe_log_parameter(_desc, nil), do: :ok
  defp maybe_log_parameter(desc, variable) do
    Logger.info "#{desc}: #{variable}"
  end
end
