use Mix.Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kastlex, Kastlex.Endpoint,
  http: [port: 4001],
  server: false

# Print only warnings and errors during test
config :logger, level: :warn

# Configure your database
config :kastlex, Kastlex.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: "postgres",
  password: "postgres",
  database: "kastlex_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox

config :brod, :clients,
  kastlex: [
    endpoints: ["localhost": 9092],
    auto_start_producers: true
  ]
