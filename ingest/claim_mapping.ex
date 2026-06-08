# ingest/claim_mapping.ex — fold listings + build engine claims from HistoryEnvelopes (bead gr-beo).
#
# Load it from a script with (order matters — it calls into the engine + loader):
#   Code.require_file("golden_record_core.ex", __DIR__)        # Codes, Substrate, Events
#   Code.require_file("ingest/envelope_loader.ex", __DIR__)    # HistoryEnvelope
#   Code.require_file("ingest/claim_mapping.ex", __DIR__)
#
# Stage 2 of the legacy-medipim ingest. Takes the decoded-but-unresolved envelopes (gr-n8i) and
# produces the engine's claim log + the `shared` code set, ready for clustering/reconcile (gr-chq:
# `Cluster.variants(Substrate.current(claims), shared)` then `IdentityLedger.decide`).
#
# What it does, per the design (docs/plans/2026-06-05-legacy-history-ingest-design.md):
#
#   1. FOLD per listing = (legacy_entity, source). Replay that source's granular identity events
#      (set/add/remove/delete, in recorded_at order) into a final code-set — a SNAPSHOT (v1).
#      `set` replaces a single-valued scheme (a null value clears it); `add`/`remove` edit a
#      collection; `delete` (op-4) drops the whole scheme entry. Folding runs on medipim's own
#      scheme names so eanGtin13(set) and ean(add) don't interfere, THEN maps to engine schemes.
#
#   2. CANONICALIZE + PARTITION. Every code goes through `Codes.canonicalize` (GTIN family →
#      GTIN-14). Codes that must never bridge two products — restricted/in-store GTINs
#      (`Codes.restricted?`) and non-bridging schemes (MPN/supplier ref) — are collected into the
#      `shared` set the clusterer carries but never fuses on.
#
#   3. BUILD claims (via `Substrate.claim/5`, which re-canonicalizes idempotently):
#      * identity  — one per listing: %{ref: "entity:source", codes: <folded set>}.
#      * grouping  — synthesized, one per (listing, code): %{code, product: legacy_entity}.
#                    Makes the legacy entity a first-class product label for collision reasoning.
#      * attribute — one per attribute event, anchored to the listing's primary code
#                    (CNK ▸ canonical GTIN ▸ first). Survivorship is the engine's job, not ours.
#      * member_of — one per edge add/set, anchored likewise, pointing at the collection code.
#
# NOT here: media claims (out of scope for gr-beo), survivorship/clustering (the engine owns it),
# and edge removals (a snapshot-v1 simplification — member_of unions and does not retract).

defmodule ClaimMapping do
  # medipim identity scheme → engine scheme atom. The GTIN family all canonicalize to :gtin;
  # cnk is its own (shorter, non-GTIN) national scheme and must stay distinct.
  @identity_scheme %{
    "cnk" => :cnk,
    "ean" => :ean,
    "gtin" => :gtin,
    "eanGtin8" => :gtin,
    "eanGtin12" => :gtin,
    "eanGtin13" => :gtin,
    "eanGtin14" => :gtin
  }

  # schemes that identify a *supplier's* reference, not a globally-unique product — never bridge.
  @non_bridging_schemes MapSet.new([:mpn, :supplier_ref])

  @doc """
  Map a list of `%HistoryEnvelope{}` to `%{claims: [%Events.ClaimAsserted{}], shared: MapSet}`.
  Claims carry a chronological `order` (later recorded_at ⇒ higher order ⇒ wins survivorship).
  """
  def build(envelopes) when is_list(envelopes) do
    folded = fold_raw(envelopes)
    listing_codes = listing_codes(folded)
    entity_codes = union_by_entity(listing_codes)

    listing_primary = Map.new(listing_codes, fn {k, set} -> {k, primary(MapSet.to_list(set))} end)
    entity_primary = Map.new(entity_codes, fn {e, set} -> {e, primary(MapSet.to_list(set))} end)

    anchor = fn entity, source ->
      (source && Map.get(listing_primary, {entity, source})) || Map.get(entity_primary, entity)
    end

    identity =
      for {{e, s} = k, set} <- listing_codes do
        Substrate.claim(s, :identity, %{ref: "#{e}:#{s}", codes: MapSet.to_list(set)}, folded[k].last_at, folded[k].last_at)
      end

    grouping =
      for {{e, s} = k, set} <- listing_codes, code <- set do
        Substrate.claim(s, :grouping, %{code: code, product: e}, folded[k].last_at, folded[k].last_at)
      end

    attribute =
      for env <- envelopes,
          ev <- env.events,
          ev.kind == :attribute,
          a = anchor.(env.legacy_entity, ev.source),
          a != nil do
        Substrate.claim(
          ev.source,
          :attribute,
          %{code: a, field: field_dim(ev), value: ev.data.value},
          ev.valid_from,
          ev.recorded_at
        )
      end

    member_of =
      for env <- envelopes,
          ev <- env.events,
          ev.kind == :edge,
          ev.op in [:set, :add],
          ev.data.value != nil,
          a = anchor.(env.legacy_entity, ev.source),
          a != nil do
        Substrate.claim(
          ev.source,
          :member_of,
          %{member_code: a, collection: {ev.data.collection, to_string(ev.data.value)}},
          ev.valid_from,
          ev.recorded_at
        )
      end

    %{
      claims: stamp(identity ++ grouping ++ attribute ++ member_of),
      shared: shared_codes(listing_codes)
    }
  end

  @doc "Just the folded, canonicalized code-set per listing — `%{{entity, source} => MapSet}`."
  def listings(envelopes) when is_list(envelopes), do: envelopes |> fold_raw() |> listing_codes()

  # Per-listing canonicalized code-sets, with delisted (now-empty) listings dropped.
  defp listing_codes(folded) do
    folded
    |> Map.new(fn {k, v} -> {k, engine_codes(v.raw)} end)
    |> Enum.reject(fn {_k, set} -> MapSet.size(set) == 0 end)
    |> Map.new()
  end

  # ── fold ──────────────────────────────────────────────────────────────────

  # Replay identity events into per-listing raw code-sets, keyed by medipim scheme name.
  # Envelope events are already time-ordered, so list order is recorded_at order.
  defp fold_raw(envelopes) do
    for env <- envelopes, ev <- env.events, ev.kind == :identity, reduce: %{} do
      acc ->
        key = {env.legacy_entity, ev.source}
        cur = Map.get(acc, key, %{raw: %{}, last_at: 0})
        Map.put(acc, key, %{raw: apply_identity(cur.raw, ev), last_at: max(cur.last_at, ev.recorded_at)})
    end
  end

  defp apply_identity(raw, ev) do
    scheme = ev.data.scheme
    code = ev.data.code

    case ev.op do
      :set when is_nil(code) -> Map.delete(raw, scheme)
      :set -> Map.put(raw, scheme, MapSet.new([code]))
      :add -> Map.update(raw, scheme, MapSet.new([code]), &MapSet.put(&1, code))
      :remove -> raw |> Map.update(scheme, MapSet.new(), &MapSet.delete(&1, code)) |> drop_empty(scheme)
      :delete -> Map.delete(raw, scheme)
    end
  end

  defp drop_empty(raw, scheme) do
    case Map.get(raw, scheme) do
      %MapSet{} = s -> if MapSet.size(s) == 0, do: Map.delete(raw, scheme), else: raw
      _ -> raw
    end
  end

  # raw (medipim scheme → values) → MapSet of canonicalized engine codes.
  defp engine_codes(raw) do
    for {scheme, values} <- raw, v <- values, into: MapSet.new() do
      Codes.canonicalize({scheme_atom(scheme), v})
    end
  end

  defp scheme_atom(scheme), do: Map.get(@identity_scheme, scheme) || String.to_atom(scheme)

  # ── helpers ───────────────────────────────────────────────────────────────

  defp union_by_entity(listing_codes) do
    Enum.reduce(listing_codes, %{}, fn {{e, _s}, set}, acc ->
      Map.update(acc, e, set, &MapSet.union(&1, set))
    end)
  end

  # primary code for anchoring: CNK ▸ non-restricted canonical GTIN ▸ any GTIN ▸ lowest code.
  defp primary([]), do: nil

  defp primary(codes) do
    Enum.find(codes, &match?({:cnk, _}, &1)) ||
      Enum.find(codes, &(match?({:gtin, _}, &1) and not Codes.restricted?(&1))) ||
      Enum.find(codes, &match?({:gtin, _}, &1)) ||
      (codes |> Enum.sort() |> List.first())
  end

  defp field_dim(ev) do
    case ev.data.locale do
      nil -> ev.data.field
      locale -> "#{ev.data.field}:#{locale}"
    end
  end

  defp shared_codes(listing_codes) do
    for {_k, set} <- listing_codes, code <- set, shared?(code), into: MapSet.new(), do: code
  end

  defp shared?({scheme, _} = code),
    do: Codes.restricted?(code) or MapSet.member?(@non_bridging_schemes, scheme)

  # chronological order: later recorded_at ⇒ higher order. Stable on the original emission index.
  defp stamp(claims) do
    claims
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {c.recorded_at, i} end)
    |> Enum.with_index()
    |> Enum.map(fn {{c, _i}, order} -> %{c | order: order} end)
  end
end
