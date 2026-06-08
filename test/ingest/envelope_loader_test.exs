# test/ingest/envelope_loader_test.exs — ExUnit suite for the envelope loader (bead gr-n8i).
#
#   Run:  mix test
#
# Coverage spans the real 422156 fixture (happy path + every decode edge case) and the
# validation failure modes. The loader is compiled from lib/; ExUnit starts in test_helper.

defmodule EnvelopeLoaderTest do
  use ExUnit.Case, async: true

  alias HistoryEnvelope, as: HE

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  describe "the real 422156 fixture" do
    setup do
      {:ok, env} = HE.load(@fixture)
      %{env: env}
    end

    test "envelope-level fields", %{env: env} do
      assert env.schema_version == "1"
      assert env.source_system == "medipim-be"
      assert env.legacy_entity == 422_156
      assert env.last_touched_at == 1_778_976_623
      assert env.dropped_meta_count == 819
      assert length(env.events) == 930
    end

    test "kind counts match the known shape", %{env: env} do
      assert HE.kind_counts(env) == %{identity: 23, attribute: 127, edge: 12, media: 768}
    end

    test "ops and kinds are atoms; order is a 0..n-1 index", %{env: env} do
      assert Enum.all?(env.events, &(&1.op in [:set, :add, :remove, :delete]))
      assert Enum.all?(env.events, &(&1.kind in [:identity, :attribute, :edge, :media]))
      assert Enum.map(env.events, & &1.order) == Enum.to_list(0..929)
    end

    test "first identity event = org 1034 sets CNK 3612173", %{env: env} do
      first = Enum.find(env.events, &(&1.kind == :identity))
      assert first.op == :set
      assert first.source == "1034"
      assert first.recorded_at == 1_535_726_805
      assert first.data == %{scheme: "cnk", code: "3612173"}
    end

    test "op-4 delete carries the source (from the value) and no code", %{env: env} do
      del = Enum.find(env.events, &(&1.kind == :identity and &1.op == :delete))
      assert del.source == "1034"
      assert del.data == %{scheme: "eanGtin13", code: nil}
    end

    test "set-null clear keeps code: nil", %{env: env} do
      clear =
        Enum.find(env.events, &(&1.kind == :identity and &1.op == :set and &1.data.code == nil))

      assert clear.data.scheme == "eanGtin14"
      assert clear.source in ["1034", "44"]
    end

    test "org 44 converges on CNK 3612173 (the temporal-merge case)", %{env: env} do
      conv =
        Enum.find(env.events, &(&1.kind == :identity and &1.data.scheme == "cnk" and &1.source == "44"))

      assert conv.op == :set
      assert conv.data.code == "3612173"
      # converged later than the 2018 originals
      assert conv.recorded_at > 1_600_000_000
    end

    test "eanGtin prefix already stripped in the fixture", %{env: env} do
      gtin13 =
        Enum.find(env.events, &(&1.kind == :identity and &1.data.scheme == "eanGtin13" and &1.data.code))

      assert gtin13.data.code == "3282770146004"
      refute String.contains?(gtin13.data.code, "_")
    end

    test "attribute event carries field, locale, value", %{env: env} do
      named =
        Enum.find(env.events, &(&1.kind == :attribute and &1.data.field == "name" and &1.data.locale == "fr"))

      assert is_binary(named.data.value)
    end

    test "media add carries an asset", %{env: env} do
      m = Enum.find(env.events, &(&1.kind == :media and &1.op == :add))
      assert m.data.collection in ["media", "descriptions"]
      assert Map.has_key?(m.data, :asset)
    end
  end

  describe "validation failures" do
    test "unsupported schema_version" do
      assert {:error, {:unsupported_schema_version, "9"}} =
               HE.from_map(%{"schema_version" => "9", "events" => []})
    end

    test "missing events key" do
      assert {:error, :missing_events} = HE.from_map(%{"schema_version" => "1"})
    end

    test "events not a list" do
      assert {:error, :events_not_a_list} =
               HE.from_map(%{"schema_version" => "1", "events" => "nope"})
    end

    test "unknown op (reports event index)" do
      assert {:error, {:event, 0, {:unknown_op, "frob"}}} =
               HE.from_map(env_with(%{"op" => "frob", "kind" => "identity", "scheme" => "cnk"}))
    end

    test "unknown kind" do
      assert {:error, {:event, 0, {:unknown_kind, "nonsense"}}} =
               HE.from_map(env_with(%{"op" => "set", "kind" => "nonsense"}))
    end

    test "identity event missing scheme" do
      assert {:error, {:event, 0, {:missing_keys, ["scheme"]}}} =
               HE.from_map(env_with(%{"op" => "set", "kind" => "identity", "code" => "1"}))
    end

    test "edge event missing collection" do
      assert {:error, {:event, 0, {:missing_keys, ["collection"]}}} =
               HE.from_map(env_with(%{"op" => "add", "kind" => "edge", "value" => 1}))
    end

    test "media event missing asset" do
      assert {:error, {:event, 0, {:missing_keys, ["asset"]}}} =
               HE.from_map(env_with(%{"op" => "add", "kind" => "media", "collection" => "media"}))
    end

    test "non-object envelope" do
      assert {:error, :not_an_object} = HE.from_map("nope")
    end

    test "invalid JSON string" do
      assert {:error, {:invalid_json, _}} = HE.from_json("{not json")
    end
  end

  describe "defaults" do
    test "valid_from defaults to recorded_at when absent" do
      {:ok, env} =
        HE.from_map(
          env_with(%{
            "op" => "set",
            "kind" => "identity",
            "scheme" => "cnk",
            "code" => "1",
            "recorded_at" => 123
          })
        )

      assert hd(env.events).valid_from == 123
    end

    test "valid_from is honored when present (back-dating)" do
      {:ok, env} =
        HE.from_map(
          env_with(%{
            "op" => "set",
            "kind" => "identity",
            "scheme" => "cnk",
            "code" => "1",
            "recorded_at" => 123,
            "valid_from" => 100
          })
        )

      assert hd(env.events).valid_from == 100
    end
  end

  describe "file loading" do
    test "load! returns the struct" do
      assert %HistoryEnvelope{legacy_entity: 422_156} = HE.load!(@fixture)
    end

    test "load of a missing file returns a file error" do
      assert {:error, {:file, _, :enoent}} = HE.load(Path.join(__DIR__, "nope.json"))
    end

    test "load_all returns envelopes in order" do
      assert {:ok, [%HistoryEnvelope{legacy_entity: 422_156}]} = HE.load_all([@fixture])
    end

    test "load_all halts on the first bad path" do
      bad = Path.join(__DIR__, "nope.json")
      assert {:error, {^bad, {:file, _, :enoent}}} = HE.load_all([bad, @fixture])
    end
  end

  defp env_with(event), do: %{"schema_version" => "1", "events" => [event]}
end
