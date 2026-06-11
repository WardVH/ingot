defmodule Mix.Tasks.Steward.Queue do
  @shortdoc "List the steward queue (merge proposals + attribute ties)"

  @moduledoc """
  A thin convenience wrapper over `Api.Steward.queue/0` — the same queue the HTTP surface and
  the HTML page read, against the same Postgres (configure via PGHOST/PGPORT/... or
  DATABASE_URL in prod). No listener is started; this is a read in your terminal.

      mix steward.queue
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    start_app!()

    queue = Api.Steward.queue()
    Mix.shell().info("#{queue.open} open")

    for m <- queue.merges do
      Mix.shell().info("\nmerge  #{Enum.join(m.keys, " + ")}")

      for {key, codes} <- m.members,
          do: Mix.shell().info("  #{key}: #{Enum.map_join(codes, " ", & &1.code)}")

      if m.shared != [],
        do: Mix.shell().info("  directly shared: #{Enum.join(m.shared, " ")}")

      for b <- m.bridges do
        Mix.shell().info(
          "  bridge: #{b.source} listing #{b.ref} (#{b.date}) claims " <>
            Enum.map_join(b.codes, " ", & &1.code)
        )
      end

      case m.proposal do
        nil ->
          Mix.shell().info("  no endorsement yet — needs two distinct stewards")

        p ->
          Mix.shell().info(
            "  endorsed by #{p.by}#{if p.reason, do: " — #{p.reason}"} · awaiting a second steward"
          )
      end
    end

    for a <- queue.attributes do
      candidates = Enum.map_join(a.candidates, ", ", &"#{&1.source} says #{inspect(&1.value)}")
      Mix.shell().info("\nattribute  #{a.field} on #{a.key}: #{candidates}")
    end

    :ok
  end

  @doc false
  def start_app! do
    # the CLI wants the DB pool, never a listener — safe next to a running server
    Application.put_env(:golden_record_api, :server, false)
    Mix.Task.run("app.start")
  end
end
