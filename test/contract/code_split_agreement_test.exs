# test/contract/code_split_agreement_test.exs — the two "scheme:value" splits AGREE (bead gr-jh1).
#
# There are two independent implementations of the code-split rule in the ROOT project, and they
# MUST agree on which strings are valid codes (split on the FIRST colon, both halves non-empty):
#
#   * CanonicalClaims.parse_code/1 — the translator's split (wire → engine {scheme, value}).
#   * ClaimsValidator             — the executable contract's split (a malformed code is an
#                                   error-severity finding on the code field; the whole batch
#                                   rejects, so validate/1 returns {:error, _}).
#
# (api/lib/api/steward.ex just DELEGATES to CanonicalClaims.parse_code — it is not a third split.)
#
# A divergence here would let the validator bless a code the translator can't build (or vice
# versa), so this pins them against a table of representative inputs: known schemes, an opaque
# scheme, a value that itself contains a ':' (split keeps the FIRST colon only), and the three
# malformed shapes (no colon, empty scheme, empty value).

defmodule CodeSplitAgreementTest do
  use ExUnit.Case, async: true

  # raw "scheme:value" => is it a valid code (does the split accept it)?
  @table [
    {"cnk:1234567", true},
    {"gtin:05400101000000", true},
    {"ean:5012345678900", true},
    {"isbn:9780198526636", true},
    # a value that itself contains a ':' — split on the FIRST colon keeps "b:c" as the value
    {"a:b:c", true},
    # the three malformed shapes both implementations reject
    {"noscheme", false},
    {":value", false},
    {"scheme:", false}
  ]

  # CanonicalClaims.parse_code/1 accepts iff it returns {:ok, _}.
  defp canonical_accepts?(raw), do: match?({:ok, _}, CanonicalClaims.parse_code(raw))

  # ClaimsValidator accepts a code iff it raises no ERROR-severity finding on the code field.
  # A malformed code is a structural error, so validate/1 returns {:error, errors}; semantic
  # advisories (unknown scheme, GTIN mod-10) are warnings and ride along in {:ok, warnings}.
  defp validator_accepts?(raw) do
    claim = %{"kind" => "attribute", "source" => "s", "code" => raw, "field" => "f", "value" => "v"}

    case ClaimsValidator.validate([claim]) do
      {:ok, _warnings} -> true
      {:error, errors} -> not Enum.any?(errors, &(&1.field == "code"))
    end
  end

  test "ClaimsValidator and CanonicalClaims.parse_code/1 agree on every representative code" do
    for {raw, expected_valid} <- @table do
      assert canonical_accepts?(raw) == expected_valid,
             "CanonicalClaims.parse_code/1 disagrees on #{inspect(raw)} (expected valid? #{expected_valid})"

      assert validator_accepts?(raw) == expected_valid,
             "ClaimsValidator disagrees on #{inspect(raw)} (expected valid? #{expected_valid})"

      # and, the load-bearing claim: the two implementations agree WITH EACH OTHER
      assert canonical_accepts?(raw) == validator_accepts?(raw),
             "the two scheme:value split implementations disagree on #{inspect(raw)}"
    end
  end

  test "on an accepted code, parse_code/1 splits on the FIRST colon only" do
    # the value half keeps every colon after the first — this is the property both splits share
    assert {:ok, {_scheme, "b:c"}} = CanonicalClaims.parse_code("a:b:c")
  end
end
