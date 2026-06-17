# test/identity_conflict_explained_test.exs
#
# Plain-language tests, written so a non-technical reader can follow them top to bottom:
# each test states the INPUT in everyday words, then the EXPECTED OUTPUT in everyday words.
# The story: different shops/suppliers describe products using codes (a national code like a
# pharmacy "CNK", and a barcode like a "GTIN"), and the system has to decide when two descriptions
# are really the SAME product.

defmodule IdentityConflictExplainedTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @today ~D[2026-01-01]

  describe "Deciding when two descriptions are the same product" do
    test "WHEN two shops use the SAME barcode, THEN the system treats it as ONE product" do
      # ── INPUT (in plain words) ────────────────────────────────────────────────
      #   Shop A says:  "I have an item with national code 111 and barcode 5012345678900."
      #   Shop B says:  "I have an item with the barcode 5012345678900."
      #   Both used the same barcode.
      result =
        run([
          a_source_says("Shop A", national_code: "111", barcode: "5012345678900"),
          a_source_says("Shop B", barcode: "5012345678900")
        ])

      # ── EXPECTED OUTPUT (in plain words) ──────────────────────────────────────
      #   The system decides the two descriptions are the SAME real product, and combines them
      #   into ONE product that carries both the national code and the barcode.
      assert number_of_products(result) == 1
      assert product_has_code?(result, {:cnk, "111"})
      assert product_has_code?(result, {:gtin, "5012345678900"})
    end

    # The reason the "identity guarding" toggle exists. NOT built yet (see bead gr-ake), so this is
    # skipped — it documents, in plain words, the behaviour we want once guarding is switched on.
    @tag :skip
    test "WHEN two shops share a barcode but give DIFFERENT national codes, THEN the system must NOT silently merge them" do
      # ── INPUT (in plain words) ────────────────────────────────────────────────
      #   Shop A says:  "national code 111, barcode 5012345678900."
      #   Shop B says:  "national code 222, barcode 5012345678900."
      #   Same barcode, but two different national codes — a contradiction: a single product
      #   cannot truthfully have two different national codes.
      result =
        run([
          a_source_says("Shop A", national_code: "111", barcode: "5012345678900"),
          a_source_says("Shop B", national_code: "222", barcode: "5012345678900")
        ])

      # ── EXPECTED OUTPUT, with guarding ON (the behaviour we want) ──────────────
      #   The system does NOT glue 111 and 222 into one product. It keeps them as TWO products
      #   and flags the clash so a person can decide. (Better to under-merge and ask than to
      #   silently fuse two real products into one.)
      assert number_of_products(result) == 2
      assert a_clash_was_flagged?(result)
    end
  end

  # ── tiny helpers that turn the plain-language story into engine claims/calls ──

  defp a_source_says(name, fields) do
    codes =
      [
        fields[:national_code] && {:cnk, fields[:national_code]},
        fields[:barcode] && {:gtin, fields[:barcode]}
      ]
      |> Enum.reject(&is_nil/1)

    claim(String.to_atom(name), :identity, %{ref: name, codes: codes}, @today, @today)
  end

  defp run(claims) do
    {stamped, next} = stamp(claims, 1)

    decisions =
      IdentityLedger.decide(
        IdentityLedger.new(),
        {:reconcile, Cluster.variants(Substrate.current(stamped)), @today}
      )

    {decisions, _} = stamp(decisions, next)
    log = stamped ++ decisions
    %{log: log, products: History.now(log, Priority.new(%{}, []))}
  end

  defp number_of_products(%{products: products}), do: length(Enum.flat_map(products, & &1.variants))

  defp product_has_code?(%{products: products}, code) do
    products |> Enum.flat_map(& &1.variants) |> Enum.any?(&(Codes.canonicalize(code) in &1.codes))
  end

  defp a_clash_was_flagged?(%{log: log}), do: PublicId.collisions(:cnk, log) != []

  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}
end
