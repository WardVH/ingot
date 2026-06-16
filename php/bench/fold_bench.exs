# php/bench/fold_bench.exs — the Elixir side of the cold/warm fold benchmark.
#
#   mix run php/bench/fold_bench.exs [--iterations N]   (warm)
#   mix run php/bench/fold_bench.exs --cold             (one fold then exit)
#
# Same workload as the PHP bench: load the 422156 fixture + run the full ingest fold to the final
# golden record (GoldenRecords.from_envelopes/2). WARM loads the fixture once then folds N times,
# timing each with System.monotonic_time, and reports median + p99 µs/fold as JSON. COLD folds once
# and exits — run.sh times ~20 fresh `elixir`/`mix run` invocations and averages the wall clock.

fixture = Path.join(__DIR__, "../../test/ingest/fixtures/medipim_be_422156.json")

{opts, _, _} = OptionParser.parse(System.argv(), strict: [cold: :boolean, iterations: :integer])
cold = Keyword.get(opts, :cold, false)
iterations = Keyword.get(opts, :iterations, 2000)

fold = fn env -> GoldenRecords.from_envelopes([env], 1) end

if cold do
  env = HistoryEnvelope.load!(fixture)
  %{records: records} = fold.(env)
  IO.puts(:stderr, "cold fold: #{length(records)} product(s)")
  System.halt(0)
end

env = HistoryEnvelope.load!(fixture)

# warm-up
Enum.each(1..50, fn _ -> fold.(env) end)

samples =
  for _ <- 1..iterations do
    t0 = System.monotonic_time(:nanosecond)
    fold.(env)
    (System.monotonic_time(:nanosecond) - t0) / 1000.0
  end

sorted = Enum.sort(samples)
n = length(sorted)
median = Enum.at(sorted, div(n, 2))
p99 = Enum.at(sorted, min(n - 1, trunc(n * 0.99)))
mean = Enum.sum(sorted) / n

doc = %{
  "lang" => "elixir",
  "mode" => "warm",
  "elixir_version" => System.version(),
  "otp_release" => :erlang.system_info(:otp_release) |> to_string(),
  "iterations" => iterations,
  "median_us" => Float.round(median, 2),
  "p99_us" => Float.round(p99, 2),
  "mean_us" => Float.round(mean, 2),
  "folds_per_sec" => Float.round(1_000_000 / median, 1)
}

IO.puts(JSON.encode!(doc))
