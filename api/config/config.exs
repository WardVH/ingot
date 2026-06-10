import Config

# Compile-time defaults; the per-env files refine them and config/runtime.exs (prod) reads the
# real values from the environment — the app is configured by env only (Docker-native).
config :golden_record_api,
  server: true,
  port: 4000,
  steward_port: nil

import_config "#{config_env()}.exs"
