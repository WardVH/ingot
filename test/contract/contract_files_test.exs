# test/contract/contract_files_test.exs — the MIT contract files stay well-formed (bead gr-i2i).
#
# contract/*.schema.json is the integration surface customers code against (spec:
# docs/CLAIMS_CONTRACT.md). This suite pins the basics: both schemas parse with the stdlib JSON
# module, declare draft 2020-12, and require the top-level keys the spec promises.

defmodule ContractFilesTest do
  use ExUnit.Case, async: true

  @contract_dir Path.expand("../../contract", __DIR__)
  @draft "https://json-schema.org/draft/2020-12/schema"

  defp load!(file), do: @contract_dir |> Path.join(file) |> File.read!() |> JSON.decode!()

  test "claims.schema.json parses, declares draft 2020-12, and requires `claims`" do
    schema = load!("claims.schema.json")

    assert schema["$schema"] == @draft
    assert schema["type"] == "object"
    assert schema["required"] == ["claims"]
    # the four wire kinds the spec formalizes are all defined
    for kind <- ~w(identityClaim attributeClaim mediaClaim groupingClaim) do
      assert is_map(schema["$defs"][kind]), "missing $defs.#{kind}"
    end
  end

  test "claims.schema.json allows identity codes to be empty for retractions" do
    schema = load!("claims.schema.json")
    codes = schema["$defs"]["identityClaim"]["properties"]["codes"]

    refute Map.has_key?(codes, "minItems")
  end

  test "scheme_registry.schema.json parses, declares draft 2020-12, and requires its top-level keys" do
    schema = load!("scheme_registry.schema.json")

    assert schema["$schema"] == @draft
    assert schema["type"] == "object"
    assert schema["required"] == ["schema_version", "schemes"]
    # a scheme declaration requires name + class, the spec's two mandatory fields
    assert schema["$defs"]["scheme"]["required"] == ["name", "class"]
  end
end
