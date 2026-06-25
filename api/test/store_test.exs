# Event-store contract (bead gr-l27): durable offsets, transactional append+snapshot, writer
# serialization, exact round-trips, disposable snapshots. async: false — these share the tables.

defmodule Api.StoreTest do
  use ExUnit.Case, async: false

  @d ~D[2026-03-01]

  setup do
    Postgrex.query!(Api.DB, "TRUNCATE events, snapshots, backfill_seen, live_batches", [])
    :ok
  end

  defp identity(source, ref, codes),
    do: Substrate.claim(source, :identity, %{ref: ref, codes: codes}, @d, @d)

  defp append!(events) do
    {:ok, :ok} = Api.Store.append(fn _state, _conn -> {:ok, events, :ok} end)
  end

  test "append stamps durable offsets as order and snapshots in the same transaction" do
    append!([identity(:a, "A", [{:cnk, "111"}]), identity(:b, "B", [{:gtin, "05012345678900"}])])

    state = Api.Store.state()
    assert state.offset == 2
    assert map_size(state.current) == 2
    assert Enum.map(Api.Store.log(), & &1.order) == [1, 2]

    # the snapshot row matches what reads return
    %{rows: [[offset]]} =
      Postgrex.query!(Api.DB, ~s(SELECT "offset" FROM snapshots WHERE id = 1), [])

    assert offset == 2
  end

  test "events round-trip EXACTLY — tuples, MapSets, Dates" do
    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new([{:cnk, "111"}, {:gtin, "05012345678900"}]),
      recorded_at: @d
    }

    claim = identity(:a, "A", [{:cnk, "111"}])
    append!([claim, mint])

    assert [decoded_claim, decoded_mint] = Api.Store.log()
    assert decoded_claim == %{claim | order: 1}
    assert decoded_mint == %{mint | order: 2}
  end

  test "the writer fun sees the CURRENT state; {:error, _} rolls everything back" do
    append!([identity(:a, "A", [{:cnk, "111"}])])

    assert {:error, :nope} =
             Api.Store.append(fn state, _conn ->
               assert state.offset == 1
               {:error, :nope}
             end)

    assert length(Api.Store.log()) == 1
    assert Api.Store.state().offset == 1
  end

  test "concurrent writers serialize under the advisory lock — unique offsets, consistent snapshot" do
    1..8
    |> Enum.map(fn i ->
      Task.async(fn ->
        Api.Store.append(fn _state, _conn ->
          {:ok, [identity(:"s#{i}", "R#{i}", [{:cnk, "#{1_000_000 + i}"}])], :ok}
        end)
      end)
    end)
    |> Task.await_many(30_000)

    offsets = Api.Store.log() |> Enum.map(& &1.order)
    assert offsets == Enum.to_list(1..8)
    assert Api.Store.state().offset == 8
  end

  test "snapshots are disposable: reads re-fold from zero when the snapshot is gone" do
    append!([identity(:a, "A", [{:cnk, "111"}]), identity(:b, "B", [{:cnk, "222"}])])
    Postgrex.query!(Api.DB, "TRUNCATE snapshots", [])

    state = Api.Store.state()
    assert state.offset == 2
    assert map_size(state.current) == 2
  end

  test "rebuild! verifies a healthy snapshot and repairs a corrupted one" do
    append!([identity(:a, "A", [{:cnk, "111"}])])
    assert {:ok, {:ok, 1}} = Api.Store.rebuild!()

    # corrupt the snapshot (derived state) — the log wins
    Postgrex.query!(Api.DB, ~s(UPDATE snapshots SET state = $1 WHERE id = 1), [
      Api.Codec.encode!(Api.State.new())
    ])

    assert {:ok, {:repaired, 1}} = Api.Store.rebuild!()
    assert Api.Store.state().offset == 1
  end

  test "events_since returns the decoded tail — the change feed's substrate" do
    append!([identity(:a, "A", [{:cnk, "111"}]), identity(:b, "B", [{:cnk, "222"}])])

    assert [%Events.ClaimAsserted{order: 2}] = Api.Store.events_since(1)
    assert Api.Store.events_since(2) == []
  end

  test "a snapshot persisted before :proposals existed decodes cleanly with the default" do
    append!([identity(:a, "A", [{:cnk, "111"}])])

    # simulate an OLD snapshot: a state serialized before Api.State gained :proposals — the
    # decoded struct lacks the key, so any read of state.proposals would raise KeyError.
    old = Map.delete(Api.Store.state(), :proposals)
    refute Map.has_key?(old, :proposals)

    Postgrex.query!(Api.DB, ~s(UPDATE snapshots SET state = $1 WHERE id = 1), [
      Api.Codec.encode!(old)
    ])

    state = Api.Store.state()
    assert state.proposals == %{}
  end
end
