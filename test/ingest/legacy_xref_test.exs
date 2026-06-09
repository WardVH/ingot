# test/ingest/legacy_xref_test.exs — ExUnit for the durable legacy -> new xref (bead gr-0c2).
#
#   Run:  mix test
#
# Drives the real 422156 fixture (quiet :stable convergence) plus two synthetic cases that make the
# xref do real work: two legacy entities sharing a CNK MERGE onto one key (each sees the other as a
# co-tenant), and one legacy entity whose two disjoint listings SPLIT across two keys (primary picks
# the spine-bearing key per the design's CNK ▸ GTIN heuristic, alternates disclosed). Mirrors the
# terse synthetic-envelope helpers in rederive_test.exs / claim_mapping_test.exs — no dependency on
# gr-bxf's fixtures.

defmodule LegacyXrefTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  # ── helpers (same shape as rederive_test.exs) ───────────────────────────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, op, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => op,
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  # ── the real 422156 fixture: stable 1:1 ──────────────────────────────────────
  describe "real entity 422156" do
    setup do
      {:ok, env} = HistoryEnvelope.load(@fixture)
      xref = LegacyXref.from_envelopes([env], 1)
      %{xref: xref}
    end

    test "all three listings converge -> SK_1 holds only 422156", %{xref: xref} do
      assert xref.key_to_legacy == %{"SK_1" => [422_156]}
    end

    test "422156 is stable on its sole key", %{xref: xref} do
      assert xref.legacy_to_key[422_156] == %{primary: "SK_1", all: ["SK_1"], relation: :stable}
    end

    test "resolve_legacy answers the primary with :stable", %{xref: xref} do
      assert LegacyXref.resolve_legacy(xref, 422_156) == {:ok, "SK_1", :stable}
    end

    test "an unknown legacy id is rejected", %{xref: xref} do
      assert LegacyXref.resolve_legacy(xref, 999_999) == {:error, :unknown_legacy}
    end
  end

  # ── synthetic MERGE: two entities share a CNK -> one key ──────────────────────
  describe "merge (two legacy entities, one surrogate key)" do
    setup do
      envs = [
        envelope(1, [id("A", "set", "cnk", "100", 10)]),
        envelope(2, [id("B", "set", "cnk", "100", 10)])
      ]

      %{xref: LegacyXref.from_envelopes(envs, 1)}
    end

    test "the single key holds BOTH legacy entities", %{xref: xref} do
      assert xref.key_to_legacy == %{"SK_1" => [1, 2]}
    end

    test "each entity's relation is {:merged, [the other]}", %{xref: xref} do
      assert xref.legacy_to_key[1] == %{primary: "SK_1", all: ["SK_1"], relation: {:merged, [2]}}
      assert xref.legacy_to_key[2] == %{primary: "SK_1", all: ["SK_1"], relation: {:merged, [1]}}
    end

    test "resolve_legacy discloses the co-tenant", %{xref: xref} do
      assert LegacyXref.resolve_legacy(xref, 1) == {:ok, "SK_1", {:merged, [2]}}
      assert LegacyXref.resolve_legacy(xref, 2) == {:ok, "SK_1", {:merged, [1]}}
    end
  end

  # ── synthetic OVER-MERGE GUARD: barcode-only bridge is SUSPECT (gr-ose) ────────
  describe "over-merge guard — suspect (bridged solely by a reused barcode)" do
    # Two distinct legacy entities sharing ONLY a reused/reassigned GTIN fuse onto one surrogate
    # key. The merge IS applied (codes win, one SK) but the relation is TAGGED :suspect so the
    # migration diff surfaces it as needs-review (medipim's ProductCodeIdentityMatch / MED-11207).
    setup do
      envs = [
        envelope(10, [id("A", "set", "gtin", "05012345678900", 10)]),
        envelope(20, [id("B", "set", "gtin", "05012345678900", 10)])
      ]

      %{xref: LegacyXref.from_envelopes(envs, 1)}
    end

    test "the single key holds BOTH legacy entities", %{xref: xref} do
      assert xref.key_to_legacy == %{"SK_1" => [10, 20]}
    end

    test "each entity's relation is the suspect 3-tuple {:merged, [other], :suspect}", %{xref: xref} do
      assert xref.legacy_to_key[10] == %{
               primary: "SK_1",
               all: ["SK_1"],
               relation: {:merged, [20], :suspect}
             }

      assert xref.legacy_to_key[20] == %{
               primary: "SK_1",
               all: ["SK_1"],
               relation: {:merged, [10], :suspect}
             }
    end

    test "resolve_legacy discloses the suspect over-merge", %{xref: xref} do
      assert LegacyXref.resolve_legacy(xref, 10) == {:ok, "SK_1", {:merged, [20], :suspect}}
      assert LegacyXref.resolve_legacy(xref, 20) == {:ok, "SK_1", {:merged, [10], :suspect}}
    end
  end

  # ── synthetic OVER-MERGE GUARD: a national-code bridge is TRUSTED (gr-ose) ─────
  describe "over-merge guard — trusted (bridged by a national code)" do
    # A cip_acl7 (national) bridge is the re-derivation working as intended — it stays the plain
    # 2-tuple, NOT suspect. (The CNK-merge describe above is the cnk equivalent and must stay green.)
    setup do
      envs = [
        envelope(30, [id("A", "set", "cipOrAcl7", "1234567", 10)]),
        envelope(40, [id("B", "set", "cipOrAcl7", "1234567", 10)])
      ]

      %{xref: LegacyXref.from_envelopes(envs, 1)}
    end

    test "the single key holds BOTH legacy entities", %{xref: xref} do
      assert xref.key_to_legacy == %{"SK_1" => [30, 40]}
    end

    test "each entity's relation is the plain 2-tuple (NOT suspect)", %{xref: xref} do
      assert xref.legacy_to_key[30] == %{primary: "SK_1", all: ["SK_1"], relation: {:merged, [40]}}
      assert xref.legacy_to_key[40] == %{primary: "SK_1", all: ["SK_1"], relation: {:merged, [30]}}
    end

    test "resolve_legacy discloses a plain merge, no :suspect tag", %{xref: xref} do
      assert LegacyXref.resolve_legacy(xref, 30) == {:ok, "SK_1", {:merged, [40]}}
      assert LegacyXref.resolve_legacy(xref, 40) == {:ok, "SK_1", {:merged, [30]}}
    end
  end

  # ── synthetic SPLIT: one entity fragments across two keys ─────────────────────
  describe "split (one legacy entity, two surrogate keys)" do
    # Entity 700 has two listings with DISJOINT bridging codes -> two clusters -> two keys.
    # Listing A bears a CNK (spine rank 2); listing B bears only a GTIN (spine rank 1). The keep
    # heuristic's first tier (CNK ▸ GTIN) must pick A's key as primary — exercising exactly the
    # CNK-outranks-GTIN ordering the engine's GTIN-only private has_spine?/1 does NOT cover.
    setup do
      envs = [
        envelope(700, [
          id("A", "set", "cnk", "555", 10),
          id("B", "set", "gtin", "05012345678900", 10)
        ])
      ]

      xref = LegacyXref.from_envelopes(envs, 1)
      # which key got the CNK vs the GTIN (key ids depend on Cluster's min-code sort).
      result = Rederivation.run(envs, 1)

      cnk_key =
        Enum.find_value(result.ledger.members, fn {k, codes} ->
          MapSet.member?(codes, {:cnk, "555"}) && k
        end)

      %{xref: xref, cnk_key: cnk_key}
    end

    test "entity 700 is :split across both keys", %{xref: xref} do
      assert %{relation: :split, all: all} = xref.legacy_to_key[700]
      assert length(all) == 2
      assert Enum.sort_by(all, fn "SK_" <> n -> String.to_integer(n) end) == all
    end

    test "primary is the spine-bearing (CNK) key per the heuristic", %{xref: xref, cnk_key: cnk_key} do
      assert xref.legacy_to_key[700].primary == cnk_key
    end

    test "both keys trace their provenance back to 700", %{xref: xref} do
      for {_key, entities} <- xref.key_to_legacy do
        assert entities == [700]
      end
    end

    test "resolve_legacy answers the primary and discloses both keys", %{xref: xref, cnk_key: cnk_key} do
      assert {:ok, ^cnk_key, {:split, all}} = LegacyXref.resolve_legacy(xref, 700)
      assert length(all) == 2
      assert cnk_key in all
    end
  end
end
