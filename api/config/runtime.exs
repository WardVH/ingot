import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required, e.g. postgres://user:pass@host:5432/golden_record_api"

  uri = URI.parse(database_url)
  [username, password] = uri.userinfo |> String.split(":", parts: 2)

  config :golden_record_api,
    db: [
      hostname: uri.host,
      port: uri.port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "/golden_record_api", "/")
    ],
    port: String.to_integer(System.get_env("PORT", "4000")),
    steward_port:
      System.get_env("STEWARD_PORT") && String.to_integer(System.get_env("STEWARD_PORT")),
    product_token: System.fetch_env!("PRODUCT_API_TOKEN"),
    steward_token: System.fetch_env!("STEWARD_API_TOKEN")
end
