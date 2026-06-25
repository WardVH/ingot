defmodule Api.Store do
  @moduledoc """
  The append-only event store + disposable snapshot.

  * `events` is the system of record: never updated, never deleted; `offset` is the engine's
    `order` made durable (assigned here, under the writer lock — not a serial, so the stored
    payload carries its own offset).
  * `snapshots` holds the materialized `Api.State` at an offset. Append + snapshot happen in ONE
    transaction under a Postgres advisory lock — the single writer; reads never block.
  * Snapshots are disposable: `rebuild!/0` re-folds the whole log from zero, verifies it matches
    the stored snapshot (the integrity check), and rewrites it.
  """

  @lock_key 726_001

  # ── schema ──────────────────────────────────────────────────────────────────
  def migrate!(conn \\ Api.DB) do
    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS events (
        "offset"    bigint PRIMARY KEY,
        type        text   NOT NULL,
        recorded_at date   NOT NULL,
        payload     bytea  NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS snapshots (
        id         int    PRIMARY KEY CHECK (id = 1),
        "offset"   bigint NOT NULL,
        state      bytea  NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS backfill_seen (
        legacy_entity bigint NOT NULL,
        fingerprint   text   NOT NULL,
        inserted_at   timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (legacy_entity, fingerprint)
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS live_batches (
        idempotency_key text PRIMARY KEY,
        fingerprint     text  NOT NULL,
        response        bytea NOT NULL,
        inserted_at     timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    :ok
  end

  @doc "Boot-time migrate with retry — the DB container may still be starting."
  def migrate_when_ready!(attempts \\ 60) do
    migrate!()
  rescue
    e ->
      if attempts > 1 do
        Process.sleep(500)
        migrate_when_ready!(attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  # ── the single writer ───────────────────────────────────────────────────────
  @doc """
  Run `fun.(state, conn)` under the writer lock — `conn` lets the writer touch side tables
  (e.g. `backfill_seen`) in the SAME transaction. `fun` returns `{:ok, events, result}` — the
  events are appended (each stamped with its durable offset as `order`), folded into the state,
  and the new snapshot stored transactionally — or `{:error, reason}` to roll back. Returns
  `{:ok, result}` / `{:error, reason}`.
  """
  def append(fun) do
    Postgrex.transaction(
      Api.DB,
      fn conn ->
        Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [@lock_key])
        state = load(conn)

        case fun.(state, conn) do
          {:ok, events, result} ->
            state = insert_and_fold(conn, state, events)
            save_snapshot(conn, state)
            result

          {:error, reason} ->
            Postgrex.rollback(conn, reason)
        end
      end,
      timeout: 60_000
    )
  end

  @doc "The current state, for reads: snapshot + any tail beyond it. Never takes the writer lock."
  def state(conn \\ Api.DB), do: load(conn)

  @doc "The full decoded log, offset order — for as-of projections and lineage."
  def log(conn \\ Api.DB) do
    %{rows: rows} = Postgrex.query!(conn, ~s(SELECT payload FROM events ORDER BY "offset"), [])
    Enum.map(rows, fn [bin] -> Api.Codec.decode!(bin) end)
  end

  @doc "Decoded events with offset > `offset` — the change feed."
  def events_since(offset, limit \\ 500, conn \\ Api.DB) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        ~s(SELECT payload FROM events WHERE "offset" > $1 ORDER BY "offset" LIMIT $2),
        [offset, limit]
      )

    Enum.map(rows, fn [bin] -> Api.Codec.decode!(bin) end)
  end

  @doc """
  The integrity check + repair: re-fold the ENTIRE log from offset 0, compare with the stored
  snapshot, rewrite it. Returns `{:ok, offset}` when they matched, `{:repaired, offset}` when the
  stored snapshot disagreed with the log (the log wins — snapshots are derived state).
  """
  def rebuild! do
    Postgrex.transaction(
      Api.DB,
      fn conn ->
        Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [@lock_key])

        %{rows: rows} =
          Postgrex.query!(conn, ~s(SELECT payload FROM events ORDER BY "offset"), [])

        refolded =
          Enum.reduce(rows, Api.State.new(), fn [bin], s ->
            Api.State.apply_event(s, Api.Codec.decode!(bin))
          end)

        stored = stored_snapshot(conn)
        save_snapshot(conn, refolded)

        if stored == nil or stored == refolded,
          do: {:ok, refolded.offset},
          else: {:repaired, refolded.offset}
      end,
      timeout: 300_000
    )
  end

  # ── internals ───────────────────────────────────────────────────────────────
  defp load(conn) do
    base = stored_snapshot(conn) || Api.State.new()

    # tail is normally empty (append + snapshot are one transaction); folding it anyway makes
    # reads correct even after manual surgery or a restored events-only backup.
    base |> Api.State.apply_all(events_since(base.offset, 1_000_000, conn))
  end

  defp stored_snapshot(conn) do
    case Postgrex.query!(conn, "SELECT state FROM snapshots WHERE id = 1", []) do
      %{rows: [[bin]]} -> upgrade(Api.Codec.decode!(bin))
      %{rows: []} -> nil
    end
  end

  # Snapshot upgrade path: a snapshot persisted before Api.State gained :proposals decodes
  # without that key, so any read of state.proposals would raise KeyError until rebuild!
  # re-folds. Backfill the field's default so an old snapshot decodes cleanly.
  defp upgrade(%Api.State{} = state), do: Map.put_new(state, :proposals, %{})

  defp insert_and_fold(conn, state, events) do
    Enum.reduce(events, state, fn event, s ->
      offset = s.offset + 1
      %Date{} = event.recorded_at
      stamped = %{event | order: offset}

      Postgrex.query!(
        conn,
        ~s{INSERT INTO events ("offset", type, recorded_at, payload) VALUES ($1, $2, $3, $4)},
        [offset, Api.Codec.type(stamped), stamped.recorded_at, Api.Codec.encode!(stamped)]
      )

      Api.State.apply_event(s, stamped)
    end)
  end

  defp save_snapshot(conn, state) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO snapshots (id, "offset", state) VALUES (1, $1, $2)
      ON CONFLICT (id) DO UPDATE SET "offset" = $1, state = $2, updated_at = now()
      """,
      [state.offset, Api.Codec.encode!(state)]
    )
  end
end
