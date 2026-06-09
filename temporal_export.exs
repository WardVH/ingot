# temporal_export.exs — export the temporal-pass demo to JSON for the viz/ web app (bead gr-m6r, V1).
#
#   Run:  mix run temporal_export.exs   ->   viz/src/data/temporal.json
#
# Runs the REAL `Temporal` engine (lib/ingest/temporal.ex) on the medipim 422156 fixture AND the
# synthetic 3-listing over-merge guard, then serializes a faithful snapshot the Astro/React viz reads.
# The browser can't run Elixir, so this is the ONLY engine -> browser bridge: the viz reimplements no
# fold logic, it just indexes the precomputed `golden_as_of` projections by date.
#
# GENERATED FILE — viz/src/data/temporal.json is written by this script. Do not hand-edit it; re-run
# this instead. Stdlib only (the built-in `JSON` module). Shape: docs/plans/2026-06-09-temporal-viz-design.md.

defmodule TemporalExport do
  @fixture "test/ingest/fixtures/medipim_be_422156.json"
  @out "viz/src/data/temporal.json"

  # A few human-meaningful attributes to surface on the golden card (the rest are folded but noisy).
  @card_fields ~w(name:fr name:nl status apbCategory)

  def run do
    data = %{real: real_scene(), synthetic: synthetic_scene()}
    File.mkdir_p!(Path.dirname(@out))
    File.write!(@out, JSON.encode!(data))
    IO.puts("wrote #{@out} (#{File.stat!(@out).size} bytes)")
  end

  # ── the real fixture: medipim entity 422156 ─────────────────────────────────────
  defp real_scene do
    env = HistoryEnvelope.load!(@fixture)
    %{log: log, timeline: timeline} = Temporal.run([env])

    dates = claim_dates(log)
    mint = Enum.find(timeline, &match?(%Events.IdentityMinted{}, &1))

    %{
      label: "medipim entity 422156",
      dates: Enum.map(dates, &date_str/1),
      mintDate: date_str(mint.recorded_at),
      claims: claims(log),
      timeline: Enum.map(timeline, &event/1),
      asOf: as_of_map(log, dates)
    }
  end

  # ── synthetic over-merge guard: two keys, a late bridge that gets FLAGGED ────────
  defp synthetic_scene do
    d1 = ~D[2024-01-01]
    d2 = ~D[2024-06-01]

    envs = [
      envelope(900, [
        id("C", "gtin", "05000000000017", epoch(d1, 9)),
        id("D", "cnk", "1000000", epoch(d1, 9)),
        id("E", "gtin", "05000000000017", epoch(d2, 9)),
        id("E", "cnk", "1000000", epoch(d2, 9))
      ])
    ]

    %{log: log, timeline: timeline} = Temporal.run(envs)

    %{
      label: "over-merge guard (synthetic)",
      steps: [date_str(d1), date_str(d2)],
      timeline: Enum.map(timeline, &event/1),
      asOf: as_of_map(log, [d1, d2])
    }
  end

  # ── projection -> JSON ──────────────────────────────────────────────────────────
  defp as_of_map(log, dates) do
    Map.new(dates, fn d ->
      variants =
        log
        |> Temporal.golden_as_of(d)
        |> Enum.flat_map(fn %{product: product, variants: vs} ->
          Enum.map(vs, &variant(&1, product))
        end)

      {date_str(d), %{variants: variants}}
    end)
  end

  defp variant(v, product) do
    %{
      key: v.key,
      product: product_value(product),
      cnk: v.codes |> Enum.find(&match?({:cnk, _}, &1)) |> code_str(),
      codes: Enum.map(v.codes, &code_str/1),
      attributes: card_attributes(v.attributes)
    }
  end

  # Catalog.project groups by product.value; for the synthetic scene there are no grouping claims so
  # the value is `{:none, "—"}` — surface that as null, integer product labels pass through.
  defp product_value(p) when is_integer(p), do: p
  defp product_value(_), do: nil

  defp card_attributes(attributes) do
    attrs = Map.new(attributes)

    for field <- @card_fields, decision = attrs[field], decision != nil do
      %{field: field, value: decision.value, status: to_string(decision.status)}
    end
  end

  defp claims(log) do
    for %Events.ClaimAsserted{} = c <- log do
      %{
        date: date_str(c.recorded_at),
        kind: to_string(c.kind),
        source: to_string(c.source),
        codes: claim_codes(c)
      }
    end
  end

  defp claim_codes(%Events.ClaimAsserted{kind: :identity, data: %{codes: codes}}),
    do: Enum.map(codes, &code_str/1)

  defp claim_codes(_), do: []

  defp event(%Events.IdentityMinted{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MINT", key: k, codes: codes_str(c)}

  defp event(%Events.IdentityMembersChanged{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MEMBERS", key: k, codes: codes_str(c)}

  defp event(%Events.IdentitiesMerged{from: from, into: into, recorded_at: at}),
    do: %{date: date_str(at), type: "MERGE", from: from, into: into}

  defp event(%Events.IdentitySplit{key: k, into: into, recorded_at: at}),
    do: %{date: date_str(at), type: "SPLIT", key: k, into: Enum.map(into, &elem(&1, 0))}

  defp event(%Events.ConflictFlagged{subject: {:merge, keys}, recorded_at: at}),
    do: %{date: date_str(at), type: "FLAG", subject: keys}

  defp event(%Events.ConflictFlagged{subject: subject, recorded_at: at}),
    do: %{date: date_str(at), type: "FLAG", subject: inspect(subject)}

  # ── value helpers ───────────────────────────────────────────────────────────────
  defp codes_str(%MapSet{} = codes), do: codes |> MapSet.to_list() |> Enum.sort() |> codes_str()
  defp codes_str(codes) when is_list(codes), do: Enum.map(codes, &code_str/1)
  defp code_str(nil), do: nil
  defp code_str({scheme, value}), do: "#{scheme}:#{value}"

  defp date_str(%Date{} = d), do: Date.to_iso8601(d)

  defp claim_dates(log),
    do: for(%Events.ClaimAsserted{} = c <- log, do: c.recorded_at) |> Enum.uniq() |> Enum.sort(Date)

  # ── synthetic-envelope helpers (same terse shape as the ingest tests) ───────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => "set",
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  defp epoch(%Date{} = date, hour),
    do: date |> DateTime.new!(Time.new!(hour, 0, 0)) |> DateTime.to_unix()
end

TemporalExport.run()
