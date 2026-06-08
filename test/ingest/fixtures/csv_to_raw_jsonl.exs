#!/usr/bin/env elixir
#
# One-off CSV → raw.jsonl converter for a medipim `products_deltas` export.
#
# Converts a CSV export of one entity's deltas into the `.raw.jsonl` shape the fixture oracle
# (`gen.exs`) consumes — one JSON object per row, keys: id, tag, entity, events, created_at,
# created_by — matching `medipim_be_422156.raw.jsonl` byte-shape.
#
# Used once to produce `medipim_fr_347025.raw.jsonl` from the French export. Stdlib only (NO CSV
# dependency): each data row is `<id>,<entity>,"<events>","<tag>",<created_at>,<created_by>` where
#   - id, entity        — bare integers at the FRONT (first two comma fields);
#   - tag,created_at,created_by — the LAST three fields (`"<tag>",<int>,<int>`); and
#   - events            — everything between, a CSV-quoted JSON array: surrounding `"` stripped,
#                         doubled `""` un-doubled to `"`, then JSON-decoded.
# The events JSON contains commas, so the front/tail are peeled off positionally (not a naive
# comma split) and the remainder is the events field.
#
#     mix run test/ingest/fixtures/csv_to_raw_jsonl.exs <entity_id> <csv_path> <out_jsonl_path>

defmodule CsvToRawJsonl do
  # tail of a data row: `…,"<tag>",<created_at>,<created_by>` (tag has no embedded quote/comma).
  @tail ~r/,"(?<tag>[^"]*)",(?<created_at>\d+),(?<created_by>\d+)\s*$/

  def run(entity_id, csv_path, out_path) do
    {count, lines} =
      csv_path
      |> File.stream!()
      |> drop_header()
      |> Enum.reduce({0, []}, fn line, {n, acc} ->
        case parse_row(String.trim_trailing(line, "\n"), entity_id) do
          nil -> {n, acc}
          json -> {n + 1, [json | acc]}
        end
      end)

    File.write!(out_path, lines |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n"))
    IO.puts("wrote #{count} rows -> #{Path.relative_to_cwd(out_path)}")
  end

  # The header is the first non-empty line; it begins with the quoted "id" column.
  defp drop_header(stream) do
    Stream.transform(stream, false, fn line, dropped? ->
      cond do
        dropped? -> {[line], true}
        String.trim(line) == "" -> {[], false}
        true -> {[], true}
      end
    end)
  end

  defp parse_row("", _entity_id), do: nil

  defp parse_row(line, entity_id) do
    # FRONT: id, entity are the first two bare-integer comma fields.
    [id_str, entity_str, rest] = String.split(line, ",", parts: 3)

    # TAIL: peel `…,"<tag>",<created_at>,<created_by>` off the end; the head is the events field.
    %{"tag" => tag, "created_at" => created_at, "created_by" => created_by} =
      Regex.named_captures(@tail, rest)

    events_field = String.replace(rest, @tail, "")

    events = events_field |> unquote_csv() |> JSON.decode!()

    entity = parse_int!(entity_str)

    if entity != entity_id do
      raise "row entity #{entity} != expected #{entity_id} (id #{id_str})"
    end

    obj = [
      {"id", parse_int!(id_str)},
      {"tag", tag},
      {"entity", entity},
      {"events", events},
      {"created_at", parse_int!(created_at)},
      {"created_by", parse_int!(created_by)}
    ]

    enc_obj(obj)
  end

  # Strip the surrounding double-quotes of a CSV-quoted field and un-double interior `""` -> `"`.
  defp unquote_csv(field) do
    field
    |> String.trim()
    |> strip_wrapping_quotes()
    |> String.replace(~s(""), ~s("))
  end

  defp strip_wrapping_quotes("\"" <> rest) do
    String.replace_suffix(rest, "\"", "")
  end

  defp strip_wrapping_quotes(other), do: other

  defp parse_int!(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> raise "expected integer, got #{inspect(s)}"
    end
  end

  # Encode one row as a single-line JSON object preserving key order (matches the BE raw.jsonl
  # layout: `{"id": .., "tag": .., "entity": .., "events": [...], "created_at": .., "created_by": ..}`).
  defp enc_obj(pairs) do
    inner = Enum.map_join(pairs, ", ", fn {k, v} -> JSON.encode!(k) <> ": " <> JSON.encode!(v) end)
    "{" <> inner <> "}"
  end
end

case System.argv() do
  [entity, csv, out] ->
    CsvToRawJsonl.run(String.to_integer(entity), csv, out)

  _ ->
    IO.puts(:stderr, "usage: mix run csv_to_raw_jsonl.exs <entity_id> <csv_path> <out_jsonl_path>")
    System.halt(1)
end
