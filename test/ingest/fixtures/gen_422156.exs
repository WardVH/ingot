#!/usr/bin/env elixir
#
# Fixture generator (one-off ORACLE, not the runtime ingest).
#
# Reads the real medipim `products_deltas` history for legacy entity 422156
# (`medipim_be_422156.raw.jsonl`, a faithful dump) and emits the decoded-but-
# unresolved `HistoryEnvelope` (`medipim_be_422156.json`) per contract C.
#
# This script applies medipim's decode rules (documented in docs/HISTORY_ENVELOPE.md,
# reverse-engineered from medipimv2's ProductDeltaApplier / Event / GtinCodeHelper /
# ProductMetaFieldBuilder). It is NOT the production decoder: the real system-of-record
# ingest consumes envelopes emitted by medipim's own PHP endpoint (bead gr-867), which
# reuses medipim's battle-tested code. This generator exists only to bootstrap a committed
# fixture from a one-time dump — and its output is precisely the contract that endpoint must
# reproduce. Regenerate:  elixir test/ingest/fixtures/gen_422156.exs
#
# Decode rules applied here (validated against the real 422156 data):
#   - opcode 1=set 2=add 3=remove 4=delete; the string opcode "update_sources" is dropped
#     (a survivorship recompute, not a data change — this engine owns resolution).
#   - key grammar field[:locale][:organizationId]: a trailing all-digit segment is the source
#     (organization id); a 2-letter alpha segment is the locale.
#   - opcode 4 (delete) carries the source in the VALUE, not the key
#     (e.g. ["4","eanGtin13",1034] = drop org 1034's eanGtin13 entry).
#   - eanGtin8/12/13/14 values are stored with a "{field}_" prefix which is stripped.
#   - meta fields (updatedAt/updatedBy/createdAt/createdBy/legacyId) are dropped; a delta that
#     reduces to nothing but meta is a touch-only delta (dropped_meta_count++).
#   - last_touched_at = max updatedAt over ALL deltas, including dropped ones.
#   - NO survivorship, NO folding, NO clustering: every source's events are kept, flat and
#     time-ordered. legacy_entity rides along as metadata only.

defmodule Gen422156 do
  @here Path.dirname(__ENV__.file)
  @raw Path.join(@here, "medipim_be_422156.raw.jsonl")
  @out Path.join(@here, "medipim_be_422156.json")

  @legacy_entity 422_156
  @source_system "medipim-be"
  @schema_version "1"

  @op %{"1" => "set", "2" => "add", "3" => "remove", "4" => "delete"}
  @identity ~w(cnk ean gtin eanGtin8 eanGtin12 eanGtin13 eanGtin14)
  @gtin_prefixed ~w(eanGtin8 eanGtin12 eanGtin13 eanGtin14)
  @media ~w(media descriptions)
  @edge ~w(publicCategories brands labos internationalBrands medipimCategories organizations)
  @meta_drop ~w(updatedAt updatedBy createdAt createdBy legacyId)

  def run do
    {rev_events, dropped, last_touched} =
      @raw
      |> File.stream!()
      |> Enum.reduce({[], 0, 0}, &process_line/2)

    events = Enum.reverse(rev_events)

    envelope = [
      {"schema_version", @schema_version},
      {"source_system", @source_system},
      {"legacy_entity", @legacy_entity},
      {"last_touched_at", last_touched},
      {"dropped_meta_count", dropped},
      {"events", events}
    ]

    File.write!(@out, enc({:obj, envelope}, 0) <> "\n")
    summarize(events, dropped, last_touched)
  end

  defp process_line(line, acc) do
    case String.trim(line) do
      "" -> acc
      json -> process_delta(JSON.decode!(json), acc)
    end
  end

  defp process_delta(delta, {events_acc, dropped, last_touched}) do
    recorded_at = delta["created_at"]
    by = delta["created_by"]
    tag = delta["tag"]

    {kept_rev, last_touched} =
      Enum.reduce(delta["events"], {[], last_touched}, fn triple, {kept, lt} ->
        opcode = Enum.at(triple, 0)
        key = Enum.at(triple, 1)
        value = Enum.at(triple, 2)
        field = key && key |> String.split(":") |> hd()

        cond do
          opcode == "update_sources" ->
            {kept, lt}

          field == "updatedAt" ->
            {kept, if(is_integer(value), do: max(lt, value), else: lt)}

          field in @meta_drop ->
            {kept, lt}

          true ->
            ev = decode(field, key, to_string(opcode), value, recorded_at, by, tag)
            {[ev | kept], lt}
        end
      end)

    last_touched = max(last_touched, recorded_at)

    case kept_rev do
      [] -> {events_acc, dropped + 1, last_touched}
      _ -> {Enum.reduce(Enum.reverse(kept_rev), events_acc, &[&1 | &2]), dropped, last_touched}
    end
  end

  # Build one decoded event as an ordered object: recorded_at, by, tag, then the payload.
  defp decode(field, key, opcode, value, recorded_at, by, tag) do
    op = Map.get(@op, opcode, opcode)
    {locale, source} = parse_key(key)
    # opcode 4 (delete): the source lives in the value, and there is no payload value.
    {source, value} = if op == "delete", do: {source_str(value) || source, nil}, else: {source, value}

    head =
      [{"recorded_at", recorded_at}] ++
        if(by != nil, do: [{"by", by}], else: []) ++
        if(tag != nil, do: [{"tag", tag}], else: [])

    {:obj, head ++ payload(field, op, locale, source, value)}
  end

  defp payload(field, op, locale, source, value) do
    kind = kind_of(field)

    base =
      [{"op", op}, {"kind", kind}] ++
        if(source != nil, do: [{"source", source}], else: [])

    base ++ kind_payload(kind, field, op, locale, value)
  end

  defp kind_payload("identity", field, op, _locale, value) do
    [{"scheme", field}] ++
      cond do
        op == "delete" -> []
        value == nil -> [{"code", nil}]
        true -> [{"code", strip_gtin_prefix(field, to_string(value))}]
      end
  end

  defp kind_payload("attribute", field, op, locale, value) do
    [{"field", field}] ++
      if(locale != nil, do: [{"locale", locale}], else: []) ++
      if(op != "delete", do: [{"value", value}], else: [])
  end

  defp kind_payload("edge", field, op, _locale, value) do
    [{"collection", field}] ++ if(op != "delete", do: [{"value", value}], else: [])
  end

  defp kind_payload("media", field, op, _locale, value) do
    [{"collection", field}] ++ if(op != "delete", do: [{"asset", value}], else: [])
  end

  defp kind_of(field) do
    cond do
      field in @identity -> "identity"
      field in @media -> "media"
      field in @edge -> "edge"
      true -> "attribute"
    end
  end

  defp strip_gtin_prefix(field, code) do
    prefix = field <> "_"

    if field in @gtin_prefixed and String.starts_with?(code, prefix),
      do: String.replace_prefix(code, prefix, ""),
      else: code
  end

  # segments after the field: an all-digit one is the source, an alpha one is the locale.
  defp parse_key(key) do
    key
    |> String.split(":")
    |> tl()
    |> Enum.reduce({nil, nil}, fn seg, {locale, source} ->
      cond do
        seg =~ ~r/^\d+$/ -> {locale, seg}
        seg =~ ~r/^[A-Za-z]+$/ -> {seg, source}
        true -> {locale, source}
      end
    end)
  end

  defp source_str(nil), do: nil
  defp source_str(v), do: to_string(v)

  # ---- tiny ordered pretty-printer: structure here, leaf encoding via built-in JSON ----
  defp enc({:obj, pairs}, level) do
    inner =
      Enum.map_join(pairs, ",\n", fn {k, v} ->
        ind(level + 1) <> JSON.encode!(k) <> ": " <> enc(v, level + 1)
      end)

    "{\n" <> inner <> "\n" <> ind(level) <> "}"
  end

  defp enc([], _level), do: "[]"

  defp enc(list, level) when is_list(list) do
    inner = Enum.map_join(list, ",\n", fn item -> ind(level + 1) <> enc(item, level + 1) end)
    "[\n" <> inner <> "\n" <> ind(level) <> "]"
  end

  defp enc(scalar, _level), do: JSON.encode!(scalar)

  defp ind(n), do: String.duplicate("  ", n)

  defp summarize(events, dropped, last_touched) do
    by_kind =
      Enum.reduce(events, %{}, fn {:obj, pairs}, acc ->
        {_, kind} = Enum.find(pairs, fn {k, _} -> k == "kind" end)
        Map.update(acc, kind, 1, &(&1 + 1))
      end)

    IO.puts("events kept     : #{length(events)}")
    IO.puts("  by kind       : #{inspect(by_kind)}")
    IO.puts("dropped (touch) : #{dropped} deltas")
    IO.puts("last_touched_at : #{last_touched}")
    IO.puts("wrote           : #{Path.relative_to_cwd(@out)}")
  end
end

Gen422156.run()
