# test/contract/claims_validator_test.exs — the executable claims contract (bead gr-f6t).
#
# ClaimsValidator is what a customer's mapping script hits first (spec: docs/CLAIMS_CONTRACT.md):
# structural rules reject with per-index, per-field reasons; semantic advisories (unknown scheme,
# GTIN canonicalization/checksum, forgiving media role) WARN — the engine accepts them.

defmodule ClaimsValidatorTest do
  use ExUnit.Case, async: true

  @valid_batch [
    %{
      "kind" => "identity",
      "source" => "medipim",
      "ref" => "P-1",
      "codes" => ["cnk:1000001", "gtin:05012345678900"],
      "valid_from" => "2024-03-01"
    },
    %{
      "kind" => "attribute",
      "source" => "medipim",
      "code" => "cnk:1000001",
      "field" => "name",
      "value" => "Sunscreen"
    },
    %{
      "kind" => "media",
      "source" => "medipim",
      "asset" => "img-001",
      "target" => "cnk:1000001",
      "uri" => "https://cdn.example/img-001.jpg",
      "role" => "primary"
    },
    %{"kind" => "grouping", "source" => "medipim", "code" => "cnk:1000001", "product" => 422_156}
  ]

  describe "valid batches" do
    test "a batch with all four kinds validates clean — no errors, no warnings" do
      assert ClaimsValidator.validate(@valid_batch) == {:ok, []}
    end

    test "the empty batch is valid" do
      assert ClaimsValidator.validate([]) == {:ok, []}
    end

    test "extra fields are ignored, not rejected (open question 6)" do
      [identity | _] = @valid_batch
      assert {:ok, []} = ClaimsValidator.validate([Map.put(identity, "valid_form", "typo")])
    end
  end

  describe "batch shape" do
    test "non-list input is a batch-level error with index nil" do
      assert {:error, [%{index: nil, field: nil, error: "claims must be a list"}]} =
               ClaimsValidator.validate(%{"claims" => []})

      assert {:error, [%{index: nil}]} = ClaimsValidator.validate("nope")
    end

    test "a claim that is not an object with a kind rejects" do
      assert {:error, [%{index: 0, field: nil, error: error}]} = ClaimsValidator.validate([42])
      assert error =~ "object with a kind"
    end

    test "an unknown kind rejects with the kind named" do
      assert {:error, [%{index: 0, field: "kind", error: error}]} =
               ClaimsValidator.validate([%{"kind" => "member_of"}])

      assert error =~ ~s("member_of")
    end
  end

  describe "per-index, per-field error attribution" do
    test "only the offending claim's index appears; valid neighbors contribute nothing" do
      bad = %{
        "kind" => "attribute",
        "source" => "m",
        "code" => "not-a-code",
        "field" => "name",
        "value" => "x"
      }

      assert {:error, [%{index: index, field: "code", error: error}]} =
               ClaimsValidator.validate(@valid_batch ++ [bad])

      assert index == length(@valid_batch)
      assert error == ~s(code must be "scheme:value", got "not-a-code")
    end

    test "multiple bad claims each get their own index" do
      batch = [
        %{"kind" => "identity", "source" => "m", "ref" => "OK", "codes" => ["cnk:1"]},
        %{"kind" => "identity", "source" => "m", "ref" => "", "codes" => ["cnk:2"]},
        %{"kind" => "grouping", "source" => "m", "code" => "cnk:3", "product" => "422156"}
      ]

      assert {:error, errors} = ClaimsValidator.validate(batch)
      assert Enum.map(errors, &{&1.index, &1.field}) == [{1, "ref"}, {2, "product"}]
    end

    test "one claim can carry several field errors, all at its index" do
      assert {:error, errors} =
               ClaimsValidator.validate([%{"kind" => "media", "source" => "m", "asset" => "a"}])

      assert Enum.map(errors, & &1.field) == ["target", "uri"]
      assert Enum.all?(errors, &(&1.index == 0))
    end
  end

  describe "structural field rules" do
    test "missing and mistyped required fields reject" do
      assert {:error, [%{index: 0, field: "codes"}]} =
               ClaimsValidator.validate([%{"kind" => "identity", "source" => "m", "ref" => "P"}])

      assert {:error, [%{index: 0, field: "codes", error: error}]} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => []}
               ])

      assert error =~ "non-empty array"

      assert {:error, [%{index: 0, field: "value", error: value_error}]} =
               ClaimsValidator.validate([
                 %{"kind" => "attribute", "source" => "m", "code" => "cnk:1", "field" => "f", "value" => %{}}
               ])

      assert value_error =~ "string, number, or boolean"
    end

    test "codes must be \"scheme:value\" with both halves non-empty, string-typed" do
      base = %{"kind" => "identity", "source" => "m", "ref" => "P"}

      for bad <- ["nocolon", ":value", "scheme:", ""] do
        assert {:error, [%{index: 0, field: "codes", error: error}]} =
                 ClaimsValidator.validate([Map.put(base, "codes", [bad])])

        assert error == ~s(code must be "scheme:value", got #{inspect(bad)})
      end

      assert {:error, [%{index: 0, field: "codes", error: error}]} =
               ClaimsValidator.validate([Map.put(base, "codes", [42])])

      assert error == ~s(code must be a "scheme:value" string, got 42)
    end

    test "the value may itself contain colons — split on the FIRST colon" do
      assert {:ok, []} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["mpn:AB:12"]}
               ])
    end

    test "an all-uuid identity claim must name its lane via entity (else it silently defaults to product)" do
      assert {:error, [%{index: 0, field: "entity", error: error}]} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["uuid:0d6f8a3e"]}
               ])

      assert error =~ "lane-neutral uuid"

      # A lane-bearing code alongside the uuid satisfies the rule — entity is then optional.
      assert {:ok, []} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["uuid:0d6f8a3e", "cnk:1"]}
               ])

      assert {:ok, []} =
               ClaimsValidator.validate([
                 %{
                   "kind" => "identity",
                   "source" => "m",
                   "ref" => "P",
                   "codes" => ["uuid:0d6f8a3e"],
                   "entity" => "description"
                 }
               ])
    end
  end

  describe "date fields" do
    test "malformed valid_from rejects with the raw value named" do
      base = %{"kind" => "grouping", "source" => "m", "code" => "cnk:1", "product" => 1}

      for bad <- ["2024-13-01", "01/03/2024", "yesterday", 20_240_301] do
        assert {:error, [%{index: 0, field: "valid_from", error: error}]} =
                 ClaimsValidator.validate([Map.put(base, "valid_from", bad)])

        assert error == "valid_from must be an ISO date, got #{inspect(bad)}"
      end
    end

    test "valid_from is optional and date-only ISO 8601" do
      base = %{"kind" => "grouping", "source" => "m", "code" => "cnk:1", "product" => 1}
      assert {:ok, []} = ClaimsValidator.validate([base])
      assert {:ok, []} = ClaimsValidator.validate([Map.put(base, "valid_from", "2024-03-01")])
    end
  end

  describe "semantic advisories — accepted, but warned" do
    test "an unknown scheme warns: opaque, non-bridging pass-through" do
      assert {:ok, [%{index: 0, field: "codes", error: warning}]} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["mystery:42"]}
               ])

      assert warning =~ ~s(unknown scheme "mystery")
      assert warning =~ "non-bridging"
    end

    test "a GTIN-family code with a bad mod-10 check digit warns (checksums are advisory)" do
      # "05012345678900" is valid; flipping the check digit to 1 breaks mod-10
      assert {:ok, [%{index: 0, field: "codes", error: warning}]} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["gtin:05012345678901"]}
               ])

      assert warning =~ "mod-10"

      # the valid check digit is clean, across GTIN-family alias spellings
      assert {:ok, []} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["ean:5012345678900"]}
               ])
    end

    test "a GTIN-family value that does not canonicalize to GTIN-14 warns" do
      assert {:ok, [%{index: 0, field: "codes", error: warning}]} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["gtin:12345"]}
               ])

      assert warning =~ "not GTIN-shaped"
    end

    test "a non-enum media role warns: the engine treats it as secondary (open question 5)" do
      media = %{
        "kind" => "media",
        "source" => "m",
        "asset" => "a",
        "target" => "cnk:1",
        "uri" => "https://x/y.jpg",
        "role" => "Primary"
      }

      assert {:ok, [%{index: 0, field: "role", error: warning}]} = ClaimsValidator.validate([media])
      assert warning =~ "secondary"

      assert {:ok, []} = ClaimsValidator.validate([%{media | "role" => "secondary"}])
      assert {:ok, []} = ClaimsValidator.validate([Map.delete(media, "role")])
    end

    test "national-scheme codes never warn on checksum (no checksum declared)" do
      assert {:ok, []} =
               ClaimsValidator.validate([
                 %{"kind" => "identity", "source" => "m", "ref" => "P", "codes" => ["cnk:1000001"]}
               ])
    end
  end
end
