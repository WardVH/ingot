import Config

config :golden_record_api,
  # no HTTP listener in tests — Plug.Test drives the routers directly
  server: false,
  db: [
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "55432")),
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    database: System.get_env("PGDATABASE", "golden_record_api_test")
  ],
  product_token: "test-product-token",
  steward_token: "test-steward-token"
