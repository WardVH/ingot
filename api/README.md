# golden-record-api — the Product API for medipim

The engine (`../lib/golden_record_core.ex`) as a Docker-native service: contract-C backfill +
live claims in; golden records (by **legacy medipim ID** — backwards compatible), code
resolution, as-of time travel, a change feed, and a steward queue out.

Full contract: **`../docs/API.md`** · design: `../docs/plans/2026-06-10-medipim-product-api-design.md`.

```bash
# the whole stack (from the repo root)
docker compose -f api/docker-compose.yml up --build     # API on :4000, Postgres included

# development
docker run -d --name gr-api-test-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:16-alpine
cd api && mix deps.get && mix test                      # incl. the E2E truth suite
iex -S mix                                              # dev server on :4000
```

Layout: `lib/api/` — `store` (append-only events + disposable snapshot, advisory-locked single
writer) · `state` (the incremental fold) · `writes` (backfill + live claims → fold-forward
reconcile) · `reads` (products, by-code, as-of, changes) · `steward` (+ the EEx queue page) ·
`auth` (two tokens, basic-auth for the browser) · `router` (single- and split-port modes).

Runtime knobs are documented in `../docs/API.md`: batch limits, `Idempotency-Key` behavior for
live claims, and optional source-priority JSON for survivorship.

The engine stays dependency-free; bandit/plug/postgrex live here, deliberately.
