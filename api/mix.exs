defmodule GoldenRecordApi.MixProject do
  use Mix.Project

  # The Product API for medipim (docs/plans/2026-06-10-medipim-product-api-design.md): a thin
  # Plug+Bandit shell around the engine. The engine itself (path dep on the repo root) stays
  # dependency-free — every dependency here is the API app's deliberate choice.
  def project do
    [
      app: :golden_record_api,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        golden_record_api: [
          include_executables_for: [:unix],
          applications: [golden_record_api: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Api.Application, []}
    ]
  end

  defp deps do
    [
      {:golden_record, path: "..", app: false},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:postgrex, "~> 0.19"}
    ]
  end
end
