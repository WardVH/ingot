# Fold benchmark — medipim-422156 (cold/warm × Elixir/PHP)

Workload (every cell): **load the 422156 fixture + run the full ingest fold to the final golden
record** (`GoldenRecords.from_envelopes/2` in Elixir, `GoldenRecords::fromEnvelopes` in PHP).

| | Elixir | PHP | PHP / Elixir |
|---|---:|---:|---:|
| **cold** (per fresh process, ms) | 408.03 ms | 71.61 ms | 0.18× |
| **warm** (median µs/fold) | 901.21 µs | 1188.08 µs | 1.32× |

- **Warm** = the fixture is loaded once, then the fold runs 2000× in one process; the figure
  is the median per-fold time. This isolates the engine's steady-state cost.
- **Cold** = the mean wall-clock of 20 fresh interpreter invocations, each doing exactly one
  fold. **Cold deliberately includes runtime startup** — BEAM boot + `mix run` (which also
  re-loads the precompiled engine) on the Elixir side, and the PHP interpreter boot + autoload on the
  PHP side. So the cold numbers are dominated by startup, not by the fold itself; read them as
  "time to answer one cold request", not as engine speed.
- A ratio > 1 means PHP is slower; < 1 means PHP is faster.

## Environment

- **Machine:** arm64, Apple M1 (8 cores)
- **OS:** Darwin 25.1.0
- **PHP:** 8.5.1 (opcache CLI enabled)
- **Elixir:** 1.20.1 / OTP 29 (erts 17.0.2)
- Iterations (warm): 2000 · cold invocations averaged: 20

## Raw warm JSON

```json
{"elixir_version":"1.20.1","folds_per_sec":1109.6,"iterations":2000,"lang":"elixir","mean_us":918.51,"median_us":901.21,"mode":"warm","otp_release":"29","p99_us":1205.67}
```

```json
{
    "lang": "php",
    "mode": "warm",
    "php_version": "8.5.1",
    "iterations": 2000,
    "median_us": 1188.08,
    "p99_us": 3392.96,
    "mean_us": 1296.18,
    "folds_per_sec": 841.7
}
```
