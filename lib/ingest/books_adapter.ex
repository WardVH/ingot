# lib/ingest/books_adapter.ex — the BOOKS adapter: two book-trade dumps → canonical claims
# (gr-vgb: the genericity gate).
#
# The second, non-pharma vertical, shaped like the medipim reference adapter (claim_mapping.ex)
# but for LIVE-WIRE claims: it maps two overlapping sources to the exact JSON `POST /v1/claims`
# / `/v1/dry-run` / `/v1/cutover` accept (docs/CLAIMS_CONTRACT.md) — no engine knowledge beyond
# the contract. The engine resolution/cluster/ledger logic is untouched; everything book-specific
# lives in (a) CodeRegistry's isbn data rows, (b) `Isbn` (10 → 13 canonicalization + checksums,
# per the books scheme declaration in test/ingest/fixtures/books/scheme_registry.json), and
# (c) this mapping.
#
# The two sources:
#
#   * librex   — the legacy ERP (test/ingest/fixtures/books/librex_catalog.json): one hyphenated
#     ISBN-10 per record, integer product ids downstream keeps using. Being the incumbent
#     system of record, librex ALONE contributes `grouping` claims (the lineage edge) — a second
#     source's record ids are not a legacy-id space, and grouping both would declare every
#     overlap a code collision.
#   * bookwire — the modern feed (bookwire_feed.json): hyphenated ISBN-13s, possibly several per
#     sku (ONIX-style), including 979 titles that have no ISBN-10 form. Identity + attributes
#     only.
#
# Every ISBN canonicalizes to ISBN-13 at this seam (`Isbn.code/1`), so a librex ISBN-10 and the
# bookwire ISBN-13 of the same title submit the SAME code — the equivalence-family fold the GTIN
# precedent does inside the engine, done here because the engine has no mod-11 normalizer.
# A checksum-invalid ISBN raises: a mapping bug should stop the export, not ship a corrupt code.

defmodule BooksAdapter do
  @moduledoc """
  Books reference adapter (gr-vgb): librex (ISBN-10 ERP) + bookwire (ISBN-13 feed) dumps →
  live-wire canonical claims (`docs/CLAIMS_CONTRACT.md`). `claims/2` maps one dump of each;
  `librex_claims/1` / `bookwire_claims/1` map a single dump (e.g. a correction feed).
  """

  @doc "Both dumps → one claims batch, ready for `POST /v1/dry-run` / `/v1/cutover`."
  def claims(librex_path, bookwire_path),
    do: librex_claims(librex_path) ++ bookwire_claims(bookwire_path)

  @doc "A librex catalog dump → identity + grouping (the lineage edge) + attribute claims."
  def librex_claims(path) do
    for record <- load(path, "records"), claim <- librex_record(record), do: claim
  end

  @doc "A bookwire feed dump → identity + attribute claims (no lineage — not the legacy system)."
  def bookwire_claims(path) do
    for item <- load(path, "items"), claim <- bookwire_item(item), do: claim
  end

  # ── librex: one ISBN-10 per record, integer ids — the system of record ───────
  defp librex_record(%{"id" => id, "isbn" => isbn} = record) do
    code = isbn_code!(isbn, "librex record #{id}")
    ref = "librex-#{id}"

    [
      %{"kind" => "identity", "source" => "librex", "ref" => ref, "codes" => [code]},
      %{"kind" => "grouping", "source" => "librex", "code" => code, "product" => id}
      | attributes("librex", code, record, ~w(title pages publisher binding))
    ]
  end

  # ── bookwire: ONIX-style, several ISBNs per sku, 979-capable ─────────────────
  defp bookwire_item(%{"sku" => sku, "isbns" => []}) do
    raise ArgumentError, "bookwire sku #{sku}: isbns is empty — every sku needs at least one ISBN"
  end

  defp bookwire_item(%{"sku" => sku, "isbns" => isbns} = item) do
    codes = Enum.map(isbns, &isbn_code!(&1, "bookwire sku #{sku}"))

    [
      %{"kind" => "identity", "source" => "bookwire", "ref" => sku, "codes" => codes}
      # attributes anchor to the sku's LEAD ISBN (first in feed order, ONIX's primary
      # identifier) — so a correction feed that APPENDS an ISBN keeps its attribute slots
      | attributes("bookwire", hd(codes), item, ~w(title pages imprint))
    ]
  end

  # ── shared ────────────────────────────────────────────────────────────────────
  defp attributes(source, code, record, fields) do
    for field <- fields, value = record[field], value != nil do
      %{
        "kind" => "attribute",
        "source" => source,
        "code" => code,
        "field" => field,
        "value" => value
      }
    end
  end

  defp isbn_code!(raw, context) do
    case Isbn.code(raw) do
      {:ok, code} -> code
      {:error, reason} -> raise ArgumentError, "#{context}: #{reason}"
    end
  end

  defp load(path, key) do
    path |> File.read!() |> JSON.decode!() |> Map.fetch!(key)
  end
end
