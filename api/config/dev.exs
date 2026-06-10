import Config

config :golden_record_api,
  db: [
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "55432")),
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    database: System.get_env("PGDATABASE", "golden_record_api_dev")
  ],
  # nil disables auth locally — no tokens, no browser prompt. Set values to exercise auth in dev.
  product_token: nil,
  steward_token: nil
