#!/usr/bin/env bash
# php/bench/run.sh — the 4-cell cold/warm × Elixir/PHP fold benchmark.
#
# Workload (all cells): load the medipim-422156 fixture + run the full ingest fold to the final
# golden record. Writes php/bench/RESULTS.md (a 2×2 table) with versions, machine info, and ratios.
#
#   WARM cells: the bench process loads the fixture once then folds N times; we report median µs/fold.
#   COLD cells: we time ~COLD_RUNS fresh interpreter invocations (each does exactly one fold) and
#               average the wall clock. Cold therefore INCLUDES BEAM / PHP startup — that is the
#               point of the cold/warm split, and it is called out honestly in RESULTS.md.
#
# Run from the repo root:  bash php/bench/run.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_DIR="$REPO_ROOT/php/bench"
cd "$REPO_ROOT"

ITERATIONS="${ITERATIONS:-2000}"
COLD_RUNS="${COLD_RUNS:-20}"

PHP_BIN="${PHP_BIN:-php}"
PHP_OPTS=(-d opcache.enable_cli=1)

echo "==> precompiling the Elixir engine (so cold cells don't pay a one-off compile)…"
mix compile >/dev/null 2>&1 || true

# ── warm cells ────────────────────────────────────────────────────────────────
echo "==> Elixir warm ($ITERATIONS folds)…"
ELIXIR_WARM_JSON="$(mix run "$BENCH_DIR/fold_bench.exs" --iterations "$ITERATIONS" 2>/dev/null | tail -1)"

echo "==> PHP warm ($ITERATIONS folds)…"
PHP_WARM_JSON="$("$PHP_BIN" "${PHP_OPTS[@]}" "$BENCH_DIR/fold_bench.php" --iterations="$ITERATIONS" 2>/dev/null)"

# extract median_us from a JSON blob via a tiny PHP helper (no jq dependency)
median_of() { "$PHP_BIN" -r '$d=json_decode(file_get_contents("php://stdin"),true); echo $d["median_us"];'; }

ELIXIR_WARM_US="$(printf '%s' "$ELIXIR_WARM_JSON" | median_of)"
PHP_WARM_US="$(printf '%s' "$PHP_WARM_JSON" | median_of)"

# ── cold cells — average wall clock of COLD_RUNS fresh invocations ─────────────
# Returns the mean wall-clock in milliseconds.
avg_cold_ms() {
  local runs="$1"; shift
  "$PHP_BIN" -r '
    $runs = (int)$argv[1];
    $cmd = $argv[2];
    $total = 0.0;
    for ($i = 0; $i < $runs; $i++) {
      $t0 = hrtime(true);
      exec($cmd . " > /dev/null 2>&1");
      $total += (hrtime(true) - $t0) / 1e6; // ns -> ms
    }
    echo round($total / $runs, 2);
  ' "$runs" "$*"
}

echo "==> Elixir cold ($COLD_RUNS fresh invocations)…"
ELIXIR_COLD_MS="$(avg_cold_ms "$COLD_RUNS" mix run "$BENCH_DIR/fold_bench.exs" --cold)"

echo "==> PHP cold ($COLD_RUNS fresh invocations)…"
ELIXIR_COLD_MS="${ELIXIR_COLD_MS}"
PHP_COLD_MS="$(avg_cold_ms "$COLD_RUNS" "$PHP_BIN" "${PHP_OPTS[@]}" "$BENCH_DIR/fold_bench.php" --cold)"

# ── machine + versions ────────────────────────────────────────────────────────
ARCH="$(uname -m)"
CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null || echo unknown)"
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
OS="$(uname -s) $(uname -r)"
PHP_VER="$("$PHP_BIN" -r 'echo PHP_VERSION;')"
ELIXIR_VERSION_OUT="$(elixir --version 2>/dev/null)"
ELIXIR_VER="$(printf '%s' "$ELIXIR_VERSION_OUT" | grep -m1 Elixir | sed 's/Elixir //;s/ .*//' | tr -d '\n')"
OTP_REL="$(printf '%s' "$ELIXIR_VERSION_OUT" | grep -m1 Erlang | sed -n 's/.*Erlang\/OTP \([0-9]*\).*/\1/p' | tr -d '\n')"
ERTS_VER="$(printf '%s' "$ELIXIR_VERSION_OUT" | grep -m1 Erlang | sed -n 's/.*\[erts-\([0-9.]*\)\].*/\1/p' | tr -d '\n')"

# ── ratios ────────────────────────────────────────────────────────────────────
ratio() { "$PHP_BIN" -r 'printf("%.2f", (float)$argv[1] / max(1e-9,(float)$argv[2]));' "$1" "$2"; }
WARM_RATIO="$(ratio "$PHP_WARM_US" "$ELIXIR_WARM_US")"      # PHP / Elixir (warm µs)
COLD_RATIO="$(ratio "$PHP_COLD_MS" "$ELIXIR_COLD_MS")"      # PHP / Elixir (cold ms)

# ── write RESULTS.md ──────────────────────────────────────────────────────────
OUT="$BENCH_DIR/RESULTS.md"
cat > "$OUT" <<EOF
# Fold benchmark — medipim-422156 (cold/warm × Elixir/PHP)

Workload (every cell): **load the 422156 fixture + run the full ingest fold to the final golden
record** (\`GoldenRecords.from_envelopes/2\` in Elixir, \`GoldenRecords::fromEnvelopes\` in PHP).

| | Elixir | PHP | PHP / Elixir |
|---|---:|---:|---:|
| **cold** (per fresh process, ms) | ${ELIXIR_COLD_MS} ms | ${PHP_COLD_MS} ms | ${COLD_RATIO}× |
| **warm** (median µs/fold) | ${ELIXIR_WARM_US} µs | ${PHP_WARM_US} µs | ${WARM_RATIO}× |

- **Warm** = the fixture is loaded once, then the fold runs ${ITERATIONS}× in one process; the figure
  is the median per-fold time. This isolates the engine's steady-state cost.
- **Cold** = the mean wall-clock of ${COLD_RUNS} fresh interpreter invocations, each doing exactly one
  fold. **Cold deliberately includes runtime startup** — BEAM boot + \`mix run\` (which also
  re-loads the precompiled engine) on the Elixir side, and the PHP interpreter boot + autoload on the
  PHP side. So the cold numbers are dominated by startup, not by the fold itself; read them as
  "time to answer one cold request", not as engine speed.
- A ratio > 1 means PHP is slower; < 1 means PHP is faster.

## Environment

- **Machine:** ${ARCH}, ${CPU} (${CORES} cores)
- **OS:** ${OS}
- **PHP:** ${PHP_VER} (opcache CLI enabled)
- **Elixir:** ${ELIXIR_VER} / OTP ${OTP_REL} (erts ${ERTS_VER})
- Iterations (warm): ${ITERATIONS} · cold invocations averaged: ${COLD_RUNS}

## Raw warm JSON

\`\`\`json
${ELIXIR_WARM_JSON}
\`\`\`

\`\`\`json
${PHP_WARM_JSON}
\`\`\`
EOF

echo "==> wrote $OUT"
cat "$OUT"
