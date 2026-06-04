# golden_record_test.exs — ExUnit suite for the engine (golden_record_core.ex).
#
#   Run:  elixir golden_record_test.exs
#
# No mix project needed: we require the core, start ExUnit, and let it autorun on exit.

Code.require_file("golden_record_core.ex", __DIR__)
ExUnit.start()

defmodule CodesTest do
  use ExUnit.Case, async: true

  describe "GTIN canonicalization (EAN 8-14 are one scheme at different widths)" do
    test "EAN-13 zero-fills to a 14-digit GTIN" do
      assert Codes.canonicalize({:ean, "5012345678900"}) == {:gtin, "05012345678900"}
    end

    test "UPC-12 and its EAN-13 form are the same trade item" do
      assert Codes.same?({:upc, "036000291452"}, {:ean, "0036000291452"})
    end

    test "EAN-8 zero-fills to 14 (its own allocation, padded — never derived from a longer code)" do
      assert Codes.canonicalize({:ean, "96385074"}) == {:gtin, "00000096385074"}
    end

    test "a GTIN-8 and that same value zero-padded to 12 are the SAME key (no need to 'set it to 8')" do
      assert Codes.same?({:gtin, "96385074"}, {:gtin, "000096385074"})
    end

    test "schemes unify: a UPC and its GTIN-14 form collapse to one (scheme :gtin)" do
      assert Codes.canonicalize({:upc, "036000291452"}) == {:gtin, "00036000291452"}
    end

    test "non-GTIN schemes pass through untouched" do
      assert Codes.canonicalize({:cnk, "3216547"}) == {:cnk, "3216547"}
    end

    test "non-GTIN-length numeric values pass through untouched (toy codes stay put)" do
      assert Codes.canonicalize({:gtin, "0111"}) == {:gtin, "0111"}
    end
  end

  describe "check-digit validation" do
    test "valid GTIN-13 and GTIN-8 pass" do
      assert Codes.valid_gtin?({:ean, "4006381333931"})
      assert Codes.valid_gtin?({:ean, "96385074"})
    end

    test "a transposed/typo'd check digit is rejected" do
      refute Codes.valid_gtin?({:ean, "4006381333930"})
    end

    test "valid constructed GTIN-14 case code passes" do
      assert Codes.valid_gtin?({:gtin, "15012345678907"})
    end
  end

  describe "GS1 structure" do
    test "indicator digit: 0 = base unit, 1 = a packaging level" do
      assert Codes.indicator({:ean, "5012345678900"}) == 0
      assert Codes.indicator({:gtin, "15012345678907"}) == 1
    end

    test "restricted-distribution prefixes (02, 20-29) are flagged, normal ones are not" do
      assert Codes.restricted?({:gtin, "2012345678905"})
      refute Codes.restricted?({:ean, "5012345678900"})
    end
  end
end

defmodule EngineTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @d1 ~D[2026-01-10]
  @d2 ~D[2026-02-01]

  @priority Priority.new(
              %{
                weight_g: [[:manufacturer], [:supplier], [:marketplace]],
                color: [[:supplier, :manufacturer, :marketplace]],
                product: [[:manufacturer], [:supplier], [:marketplace]]
              },
              [[:manufacturer], [:supplier], [:marketplace]]
            )

  # ── helpers ──
  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}

  defp fold(events, state), do: Enum.reduce(events, state, &IdentityLedger.evolve(&2, &1))
  defp clusters(c, shared \\ MapSet.new()), do: Cluster.variants(Substrate.current(c), shared)

  # single resolution pass -> {log, ledger}
  defp resolve(claims, at \\ @d1) do
    {c, o} = stamp(claims, 1)
    res = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), at})
    {res, _} = stamp(res, o)
    {c ++ res, fold(res, IdentityLedger.new())}
  end

  defp variants(golden), do: Enum.flat_map(golden, & &1.variants)
  defp find_variant(golden, code), do: Enum.find(variants(golden), &(code in &1.codes))
  defp attr(variant, field), do: variant.attributes |> List.keyfind(field, 0) |> elem(1)

  describe "identity resolution" do
    test "two sources sharing a code merge into one variant" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @d1, @d1),
          claim(:manufacturer, :identity, %{ref: "B", codes: [{:gtin, "0111"}]}, @d1, @d1)
        ])

      assert [variant] = variants(History.now(log, @priority))
      assert {:gtin, "0111"} in variant.codes
      assert {:upc, "9111"} in variant.codes
    end

    test "equivalent EAN/GTIN representations from two sources resolve to ONE variant" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:ean, "5012345678900"}]}, @d1, @d1),
          claim(:manufacturer, :identity, %{ref: "B", codes: [{:gtin, "05012345678900"}]}, @d1, @d1)
        ])

      assert [variant] = variants(History.now(log, @priority))
      assert variant.codes == [{:gtin, "05012345678900"}]
    end
  end

  describe "survivorship" do
    test "the highest-priority source wins a contradicted field" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
          claim(:supplier, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 260}, @d1, @d1),
          claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 255}, @d1, @d1)
        ])

      d = History.now(log, @priority) |> find_variant({:gtin, "0111"}) |> attr(:weight_g)
      assert d.value == 255
      assert d.winner == :manufacturer
      assert d.status == :resolved
    end

    test "a 3-way tie among equally-trusted sources is undecidable -> needs_review" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0555"}]}, @d1, @d1),
          claim(:supplier, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "red"}, @d1, @d1),
          claim(:manufacturer, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "blue"}, @d1, @d1),
          claim(:marketplace, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "green"}, @d1, @d1)
        ])

      d = History.now(log, @priority) |> find_variant({:gtin, "0555"}) |> attr(:color)
      assert d.status == :needs_review
      assert length(d.candidates) == 3
    end
  end

  describe "code collisions" do
    test "a variant whose grouping points at >1 product is flagged and marked contested" do
      claims = [
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0777"}]}, @d1, @d1),
        claim(:supplier, :grouping, %{code: {:gtin, "0777"}, product: {:mpn, "ALPHA"}}, @d1, @d1),
        claim(:manufacturer, :grouping, %{code: {:gtin, "0777"}, product: {:mpn, "BETA"}}, @d1, @d1)
      ]

      {log, ledger} = resolve(claims)
      flags = Stewardship.detect_collisions(ledger.members, Substrate.current(claims), @d1)

      assert [%Events.ConflictFlagged{subject: {:collision, _}}] = flags
      variant = History.now(log, @priority) |> find_variant({:gtin, "0777"})
      assert variant.product.status == :needs_review
    end
  end

  describe "the steward merge gate" do
    test "a bridge across two established keys is PROPOSED, not auto-merged" do
      {c1, o} = stamp([
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
        claim(:supplier, :identity, %{ref: "B", codes: [{:gtin, "0222"}]}, @d1, @d1)
      ], 1)

      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @d1})
      {res1, o} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())

      {c2, o} = stamp([claim(:scraper, :identity, %{ref: "X", codes: [{:gtin, "0111"}, {:gtin, "0222"}]}, @d2, @d2)], o)
      res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @d2})
      {res2, _} = stamp(res2, o)
      ledger2 = fold(res2, ledger1)

      assert Enum.any?(res2, &match?(%Events.ConflictFlagged{subject: {:merge, _}}, &1))
      assert map_size(ledger2.members) == 2, "the merge must NOT have been applied automatically"
    end
  end

  describe "shared codes" do
    test "marking a code shared makes it non-bridging -> the wrongly-merged variant splits in two" do
      claims = [
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "7777"}, {:gtin, "1000"}]}, @d1, @d1),
        claim(:manufacturer, :identity, %{ref: "B", codes: [{:gtin, "7777"}, {:gtin, "2000"}]}, @d1, @d1)
      ]

      {c, o} = stamp(claims, 1)
      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), @d1})
      {res1, _} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())
      assert map_size(ledger1.members) == 1, "without the share, 7777 wrongly bridges them"

      shared = Stewardship.shared_codes(Stewardship.mark_shared({:gtin, "7777"}, :alice, @d2))
      res2 = IdentityLedger.decide(ledger1, {:reconcile, Cluster.variants(Substrate.current(c), shared), shared, @d2})
      ledger2 = fold(res2, ledger1)

      assert map_size(ledger2.members) == 2
      assert Enum.all?(Map.values(ledger2.members), &MapSet.member?(&1, {:gtin, "7777"})),
             "both resulting variants legitimately carry the shared code"
    end
  end

  describe "media re-homes by code" do
    test "an asset linked to a code follows that code through a split" do
      phase1 = [
        claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @d1, @d1),
        claim(:supplier, :grouping, %{code: {:gtin, "0111"}, product: {:mpn, "P1"}}, @d1, @d1),
        claim(:manufacturer, :media, %{asset: {:dam, "IMG"}, target: {:upc, "9111"}, role: :primary, uri: "cdn://x"}, @d1, @d1)
      ]

      {c1, o} = stamp(phase1, 1)
      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @d1})
      {res1, o} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())

      phase2 = [
        claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}]}, @d2, @d2),
        claim(:marketplace, :identity, %{ref: "M", codes: [{:upc, "9111"}]}, @d2, @d2),
        claim(:marketplace, :grouping, %{code: {:upc, "9111"}, product: {:mpn, "P2"}}, @d2, @d2)
      ]

      {c2, o} = stamp(phase2, o)
      res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @d2})
      {res2, _} = stamp(res2, o)
      golden = History.now(c1 ++ res1 ++ c2 ++ res2, @priority)

      with_9111 = find_variant(golden, {:upc, "9111"})
      with_0111 = find_variant(golden, {:gtin, "0111"})
      assert Enum.any?(with_9111.media, &(&1.asset == {:dam, "IMG"})), "media followed upc:9111"
      assert with_0111.media == [], "and is no longer on the gtin:0111 variant"
    end
  end

  describe "history" do
    test "transaction-time travel shows the old belief; a superseding claim changes 'now'" do
      claims = [
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
        claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 255}, @d1, @d1),
        # back-dated correction: effective Jan 1, but only recorded on @d2
        claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 250}, ~D[2026-01-01], @d2)
      ]

      {log, _} = resolve(claims)

      as_of_d1 = History.project_as_of(log, @d1, @priority) |> find_variant({:gtin, "0111"}) |> attr(:weight_g)
      now = History.now(log, @priority) |> find_variant({:gtin, "0111"}) |> attr(:weight_g)
      assert as_of_d1.value == 255
      assert now.value == 250
    end

    test "the live ledger is exactly the fold of the log (event-sourcing invariant)" do
      {log, ledger} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
          claim(:supplier, :identity, %{ref: "B", codes: [{:gtin, "0222"}]}, @d1, @d1)
        ])

      assert fold(log, IdentityLedger.new()).members == ledger.members
    end
  end
end
