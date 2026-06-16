# php/bench/dump_golden_422156.exs — the PARITY ORACLE (run from the repo root with `mix run`).
#
#   mix run php/bench/dump_golden_422156.exs
#
# Loads the real medipim-422156 fixture, runs the full ingest fold to the final golden record
# (exactly as test/ingest/ingest_walkthrough_test.exs does: load → Rederivation.run(at) →
# GoldenRecords.project), then projects it to a CANONICAL JSON document — plain nested maps/lists
# of strings/numbers/bools, atoms→strings, tuples→arrays/strings, map keys recursively sorted — and
# writes it to php/bench/golden_422156.expected.json. The PHP EndToEnd422156Test folds the same
# fixture through the ported modules, emits the SAME shape, and asserts byte-equality.
#
# Canonical shape (one product, since 422156 is a single entity):
#   { "products": [ { "product": <int|string>, "variants": [ variant, ... ] } ],
#     "xref":     <legacy_to_key, JSON-safe>,
#     "diff":     <migration-diff report> }
# A variant is { key, codes:[ "scheme:value", ...], cnk:{canonical,aliases}|null,
#   product:{value,winner,status,candidates}, attributes:{field => decision},
#   categories:[ "collection:member", ...], media:[ {asset,role,source,uri}, ...],
#   substances:[ ... ], descriptions:[ {key,via,asserted_by,attributes}, ... ] }.

fixture = Path.join(__DIR__, "../../test/ingest/fixtures/medipim_be_422156.json")
env = HistoryEnvelope.load!(fixture)
at = 1

gr = GoldenRecords.from_envelopes([env], at)
xref = LegacyXref.from_envelopes([env], at)
report = MigrationDiff.from_envelopes([env], at)

# ── canonicalizers ────────────────────────────────────────────────────────────
code_string = fn {scheme, value} -> "#{scheme}:#{value}" end

# winner can be nil (no grouping) or an atom/string source.
to_string_or_nil = fn
  nil -> nil
  v when is_binary(v) -> v
  v -> to_string(v)
end

# product.value can be an int (legacy entity), a {:none, "—"} tuple, or {:mpn, "X"} tuple.
product_value = fn
  {a, b} -> "#{a}:#{b}"
  v -> v
end

# A survivorship decision -> JSON map. value may be any scalar; candidates is [{source, value}].
decision = fn d ->
  %{
    "value" => d.value,
    "winner" => to_string_or_nil.(d.winner),
    "status" => to_string(d.status),
    "candidates" => Enum.map(d.candidates, fn {src, val} -> [to_string(src), val] end)
  }
end

product_decision = fn p ->
  %{
    "value" => product_value.(p.value),
    "winner" => to_string_or_nil.(p.winner),
    "status" => to_string(p.status),
    "candidates" => Enum.map(p.candidates, fn {src, val} -> [to_string(src), product_value.(val)] end)
  }
end

cnk = fn
  nil ->
    nil

  %{canonical: c, aliases: aliases} ->
    %{"canonical" => code_string.(c), "aliases" => Enum.map(aliases, code_string)}
end

media = fn m ->
  %{
    "asset" => to_string(m.asset),
    "role" => to_string(m.role),
    "source" => to_string(m.source),
    "uri" => m.uri
  }
end

category = fn {collection, member} -> "#{collection}:#{member}" end

via = fn
  :direct -> "direct"
  {:substance, key} -> "substance:#{key}"
end

attributes = fn attrs ->
  Map.new(attrs, fn {field, d} -> {field, decision.(d)} end)
end

description = fn d ->
  %{
    "key" => to_string(d.key),
    "via" => via.(d.via),
    "asserted_by" => Enum.map(d.asserted_by, &to_string/1),
    "attributes" => attributes.(d.attributes)
  }
end

substance = fn s ->
  %{
    "key" => to_string(s.key),
    "codes" => Enum.map(s.codes, code_string),
    "sources" => Enum.map(s.sources, &to_string/1)
  }
end

variant = fn v ->
  %{
    "key" => v.key,
    "codes" => Enum.map(v.codes, code_string),
    "cnk" => cnk.(v.cnk),
    "product" => product_decision.(v.product),
    "attributes" => attributes.(v.attributes),
    "categories" => Enum.map(v.categories, category),
    "media" => Enum.map(v.media, media),
    "substances" => Enum.map(v.substances, substance),
    "descriptions" => Enum.map(v.descriptions, description)
  }
end

products =
  Enum.map(gr.records, fn %{product: product, variants: variants} ->
    %{"product" => product, "variants" => Enum.map(variants, variant)}
  end)

# ── xref (legacy_to_key) -> JSON-safe ─────────────────────────────────────────
relation = fn
  :stable -> "stable"
  :split -> "split"
  {:merged, others} -> %{"merged" => Enum.map(others, &to_string/1)}
  {:merged, others, :suspect} -> %{"merged" => Enum.map(others, &to_string/1), "suspect" => true}
end

xref_json =
  Map.new(xref.legacy_to_key, fn {entity, %{primary: primary, all: all, relation: rel}} ->
    {to_string(entity), %{"primary" => primary, "all" => all, "relation" => relation.(rel)}}
  end)

# ── recursively sort map keys, then encode ────────────────────────────────────
defmodule Canon do
  def sort(%{} = m),
    do: m |> Enum.map(fn {k, v} -> {k, sort(v)} end) |> Enum.sort_by(&elem(&1, 0)) |> Map.new()

  def sort(l) when is_list(l), do: Enum.map(l, &sort/1)
  def sort(other), do: other
end

doc = %{"products" => products, "xref" => xref_json, "diff" => report}
encoded = doc |> Canon.sort() |> JSON.encode!()

out = Path.join(__DIR__, "golden_422156.expected.json")
File.write!(out, encoded)
IO.puts("wrote #{out} (#{byte_size(encoded)} bytes)")
