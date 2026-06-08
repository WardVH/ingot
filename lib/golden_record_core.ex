# lib/golden_record_core.ex — the DDD + event-sourced engine (compiled by Mix; no demo, no run).
#
# Contexts: Ingestion (Substrate) · Identity Resolution (Cluster + IdentityLedger) ·
#           Stewardship · Catalog (read) · History (time-travel/lineage)
#
# Beyond the base model it supports SHARED CODES: a steward can declare a (scheme, code) to be
# legitimately shared across products (e.g. a GTIN on both a bundle and its unit). A shared code
# is carried on every variant that bears it but NEVER bridges them during clustering/matching —
# that is how "two sources use the same id, but they are two products" reaches a clean end state.

defmodule Events do
  defmodule ClaimAsserted do
    @enforce_keys [:source, :kind, :data, :valid_from, :recorded_at]
    defstruct [:source, :kind, :data, :valid_from, :recorded_at, :order]
  end

  defmodule IdentityMinted do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :recorded_at, :order]
  end

  defmodule IdentityMembersChanged do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :recorded_at, :order]
  end

  defmodule IdentitiesMerged do
    @enforce_keys [:from, :into, :recorded_at]
    defstruct [:from, :into, :recorded_at, :order]
  end

  defmodule IdentitySplit do
    @enforce_keys [:key, :kept_codes, :into, :recorded_at]
    defstruct [:key, :kept_codes, :into, :recorded_at, :order]
  end

  # subject: {:attr, key, field} | {:merge, [keys]} | {:collision, key} | {:code, {scheme, code}}
  defmodule ConflictFlagged do
    @enforce_keys [:subject, :candidates, :recorded_at]
    defstruct [:subject, :candidates, :recorded_at, :order]
  end

  # decision: {:pick, value} | :rejected | :approved | :shared
  defmodule ConflictResolved do
    @enforce_keys [:subject, :decision, :by, :recorded_at]
    defstruct [:subject, :decision, :by, :recorded_at, :order]
  end
end

defmodule Codes do
  @moduledoc """
  Code normalization & validation. The GTIN family (EAN-8 / UPC-12 / EAN-13 / GTIN-14) is ONE
  scheme at different widths: canonicalize to a 14-digit, zero-filled GTIN so equal trade items
  compare equal. Conservative — non-GTIN schemes and non-GTIN-length values pass through
  untouched, so it is safe to run over every ingested code.
  """
  @gtin_schemes [:gtin, :ean, :upc]

  # National short codes that medipim zero-pads to a fixed width. canonicalize left-pads an
  # all-digit value to the scheme's width so a query for "44813" matches a stored "0044813".
  # Real medipim data is already full-width, so padding is a no-op there.
  #
  # :cnk is DELIBERATELY EXCLUDED — real medipim cnk is always 7 digits (padding would be a no-op),
  # and ~10 existing tests use short fake cnk values ({:cnk,"0111"}/"0222"/"9"/"100"/"111"/"222"/
  # "555") that padding to 7 would silently break. (The design doc listed cnk:7; this exclusion is
  # a refinement after pre-dispatch verification.) Trim-only schemes (acl13, cip13, ndc, pdk, …)
  # are not listed — the default clause below trims them and that is all they need.
  @pad %{
    cip_acl7: 7,
    pzn: 8,
    pzn_austria: 7,
    sukl: 7,
    cefip: 7,
    national_code: 7,
    cn: 6
  }

  @doc "Canonical (scheme, value) for matching. GTIN family -> {:gtin, 14-digit zero-filled}."
  def canonicalize({scheme, value}) when scheme in @gtin_schemes do
    v = String.trim(value)
    if gtinish?(v), do: {:gtin, String.pad_leading(v, 14, "0")}, else: {scheme, v}
  end

  def canonicalize({scheme, value}) when is_map_key(@pad, scheme) do
    v = String.trim(value)
    width = Map.fetch!(@pad, scheme)

    if all_digits?(v) and String.length(v) < width,
      do: {scheme, String.pad_leading(v, width, "0")},
      else: {scheme, v}
  end

  def canonicalize({scheme, value}), do: {scheme, String.trim(value)}

  @doc "Do two codes denote the same thing once canonicalized? (8 vs zero-padded-12 vs 13 all equal)"
  def same?(a, b), do: canonicalize(a) == canonicalize(b)

  @doc "Mod-10 check-digit validity for a GTIN-family code."
  def valid_gtin?(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 ->
        String.last(v) == Integer.to_string(check_digit(String.slice(v, 0, 13)))

      _ ->
        false
    end
  end

  @doc "GTIN-14 indicator digit: 0 = base unit, 1-8 = packaging levels, 9 = variable measure."
  def indicator(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 -> v |> String.first() |> String.to_integer()
      _ -> nil
    end
  end

  @doc "Restricted-distribution / in-store GTIN (GS1 prefix 02 or 20-29) — NOT globally unique."
  def restricted?(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 ->
        prefix = String.slice(v, 1, 2)
        prefix == "02" or (prefix >= "20" and prefix <= "29")

      _ ->
        false
    end
  end

  defp gtinish?(v), do: v =~ ~r/^\d+$/ and String.length(v) in [8, 12, 13, 14]

  defp all_digits?(v), do: v != "" and v =~ ~r/^\d+$/

  defp check_digit(payload) do
    sum =
      payload
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * if(rem(i, 2) == 0, do: 3, else: 1) end)

    rem(10 - rem(sum, 10), 10)
  end
end

defmodule Substrate do
  alias Events.ClaimAsserted

  # Every ingested code is canonicalized here so equivalent representations (EAN-13 vs GTIN-14,
  # UPC vs its EAN-13 form, a GTIN-8 vs its zero-padded width) collapse to one identity.
  def claim(source, kind, data, valid_from, recorded_at),
    do: %ClaimAsserted{
      source: source,
      kind: kind,
      data: normalize(kind, data),
      valid_from: valid_from,
      recorded_at: recorded_at
    }

  defp normalize(:identity, %{codes: codes} = d), do: %{d | codes: Enum.map(codes, &Codes.canonicalize/1)}
  defp normalize(:grouping, %{code: c} = d), do: %{d | code: Codes.canonicalize(c)}
  defp normalize(:attribute, %{code: c} = d), do: %{d | code: Codes.canonicalize(c)}
  defp normalize(:media, %{target: t} = d), do: %{d | target: Codes.canonicalize(t)}

  defp normalize(:member_of, %{member_code: m, collection: c} = d),
    do: %{d | member_code: Codes.canonicalize(m), collection: Codes.canonicalize(c)}

  defp normalize(_kind, d), do: d

  defp slot(%ClaimAsserted{source: s, kind: :identity, data: %{ref: r}}), do: {s, :identity, r}
  defp slot(%ClaimAsserted{source: s, kind: :grouping, data: %{code: c}}), do: {s, :grouping, c}
  defp slot(%ClaimAsserted{source: s, kind: :attribute, data: %{code: c, field: f}}), do: {s, :attr, c, f}
  defp slot(%ClaimAsserted{source: s, kind: :media, data: %{asset: a, target: t}}), do: {s, :media, a, t}

  defp slot(%ClaimAsserted{source: s, kind: :member_of, data: %{member_code: m, collection: c}}),
    do: {s, :member_of, m, c}

  def current(claims) do
    claims
    |> Enum.group_by(&slot/1)
    |> Enum.map(fn {_slot, cs} -> Enum.max_by(cs, & &1.order) end)
  end
end

defmodule Priority do
  @enforce_keys [:table, :default]
  defstruct [:table, :default]

  def new(table, default), do: %__MODULE__{table: table, default: default}

  def rank(%__MODULE__{table: table, default: default}, dimension, source) do
    tiers = Map.get(table, dimension, default)
    Enum.find_index(tiers, fn tier -> source in tier end) || :infinity
  end
end

defmodule Survivorship do
  def field_decisions(codes, attrs, priority) do
    attrs
    |> Enum.filter(&MapSet.member?(codes, &1.data.code))
    |> Enum.group_by(& &1.data.field)
    |> Enum.map(fn {field, cs} ->
      {field,
       decide(field, Enum.map(cs, &%{source: &1.source, value: &1.data.value, order: &1.order}), priority)}
    end)
  end

  def decide(dimension, entries, priority) do
    latest =
      entries |> Enum.group_by(& &1.source) |> Enum.map(fn {_s, es} -> Enum.max_by(es, & &1.order) end)

    ranked = Enum.sort_by(latest, &Priority.rank(priority, dimension, &1.source))
    winner = hd(ranked)
    top = Priority.rank(priority, dimension, winner.source)

    distinct =
      latest
      |> Enum.filter(&(Priority.rank(priority, dimension, &1.source) == top))
      |> Enum.map(& &1.value)
      |> Enum.uniq()

    %{
      value: winner.value,
      winner: winner.source,
      status: if(length(distinct) > 1, do: :needs_review, else: :resolved),
      candidates: Enum.map(ranked, &{&1.source, &1.value})
    }
  end
end

defmodule Cluster do
  @doc "Group identity codes into variant clusters. `shared` codes are members but never bridge."
  def variants(live_claims, shared \\ MapSet.new()) do
    live_claims
    |> Enum.filter(&(&1.kind == :identity))
    |> Enum.map(fn c -> MapSet.new(c.data.codes) end)
    |> connected_components(shared)
    |> Enum.sort_by(&Enum.min/1)
  end

  defp connected_components(sets, shared) do
    Enum.reduce(sets, [], fn set, acc ->
      bridges? = fn comp -> not MapSet.disjoint?(bare(comp, shared), bare(set, shared)) end
      {overlapping, disjoint} = Enum.split_with(acc, bridges?)
      [Enum.reduce(overlapping, set, &MapSet.union(&2, &1)) | disjoint]
    end)
  end

  defp bare(codes, shared), do: MapSet.difference(codes, shared)
end

defmodule IdentityLedger do
  @enforce_keys [:members, :next]
  defstruct [:members, :next]

  def new, do: %__MODULE__{members: %{}, next: 1}

  def decide(state, {:reconcile, clusters, at}), do: decide(state, {:reconcile, clusters, MapSet.new(), at})

  def decide(%__MODULE__{members: members, next: next}, {:reconcile, clusters, shared, at}) do
    members |> reconcile(next, clusters, shared) |> then(&build_events(members, &1, at))
  end

  def evolve(%__MODULE__{} = s, %Events.IdentityMinted{key: k, codes: c}),
    do: %{s | members: Map.put(s.members, k, c), next: max(s.next, key_num(k) + 1)}

  def evolve(%__MODULE__{} = s, %Events.IdentityMembersChanged{key: k, codes: c}),
    do: %{s | members: Map.put(s.members, k, c)}

  def evolve(%__MODULE__{} = s, %Events.IdentitiesMerged{from: from, into: into}),
    do: %{s | members: Map.drop(s.members, from -- [into])}

  def evolve(%__MODULE__{} = s, %Events.IdentitySplit{key: k, kept_codes: kept, into: into}) do
    members = Enum.reduce(into, Map.put(s.members, k, kept), fn {nk, c}, m -> Map.put(m, nk, c) end)
    next = Enum.reduce(into, s.next, fn {nk, _}, n -> max(n, key_num(nk) + 1) end)
    %{s | members: members, next: next}
  end

  def evolve(%__MODULE__{} = s, %Events.ConflictFlagged{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ConflictResolved{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ClaimAsserted{}), do: s

  defp reconcile(old_members, next, clusters, shared) do
    original = old_members

    {assigns, members, next, minted, proposals} =
      Enum.reduce(clusters, {[], old_members, next, [], []}, fn cluster, {assigns, m, n, minted, proposals} ->
        case overlapping_keys(original, cluster, shared) do
          [] ->
            key = "SK_#{n}"
            {[{cluster, key} | assigns], Map.put(m, key, cluster), n + 1, [key | minted], proposals}

          [key] ->
            {[{cluster, key} | assigns], Map.update(m, key, cluster, &MapSet.union(&1, cluster)), n, minted,
             proposals}

          many ->
            # GATED: never auto-merge established keys — propose for steward review.
            {assigns, m, n, minted, [{Enum.sort(many), cluster} | proposals]}
        end
      end)

    {members, _next, split} =
      assigns
      |> Enum.group_by(fn {_c, key} -> key end)
      |> Enum.reduce({members, next, []}, fn
        {_key, [_single]}, acc ->
          acc

        {key, multiple}, {m, n, split} ->
          prior = Map.get(original, key, MapSet.new())

          {keep_cluster, _} =
            Enum.max_by(multiple, fn {c, _} -> {has_spine?(c), MapSet.size(MapSet.intersection(c, prior))} end)

          {into, m, n} =
            multiple
            |> Enum.map(&elem(&1, 0))
            |> List.delete(keep_cluster)
            |> Enum.reduce({[], m, n}, fn c, {ks, m, n} ->
              {[{"SK_#{n}", c} | ks], Map.put(m, "SK_#{n}", c), n + 1}
            end)

          {Map.put(m, key, keep_cluster), n, [{key, Enum.reverse(into)} | split]}
      end)

    %{
      minted: Enum.reverse(minted),
      split: Enum.reverse(split),
      proposals: Enum.reverse(proposals),
      members: members
    }
  end

  defp build_events(old_members, outcome, at) do
    mints =
      Enum.map(outcome.minted, &%Events.IdentityMinted{key: &1, codes: outcome.members[&1], recorded_at: at})

    splits =
      Enum.map(outcome.split, fn {key, into} ->
        %Events.IdentitySplit{
          key: key,
          kept_codes: outcome.members[key],
          into: Enum.map(into, fn {k, _} -> {k, outcome.members[k]} end),
          recorded_at: at
        }
      end)

    proposals =
      Enum.map(outcome.proposals, fn {keys, cluster} ->
        %Events.ConflictFlagged{subject: {:merge, keys}, candidates: cluster, recorded_at: at}
      end)

    mints ++ splits ++ proposals ++ keeps_changed(old_members, outcome, at)
  end

  defp keeps_changed(old_members, outcome, at) do
    skip =
      MapSet.new(Enum.flat_map(outcome.split, fn {key, into} -> [key | Enum.map(into, &elem(&1, 0))] end))

    for {key, old} <- old_members,
        not MapSet.member?(skip, key),
        Map.has_key?(outcome.members, key),
        outcome.members[key] != old,
        do: %Events.IdentityMembersChanged{key: key, codes: outcome.members[key], recorded_at: at}
  end

  defp overlapping_keys(members, cluster, shared) do
    bare = MapSet.difference(cluster, shared)

    members
    |> Enum.filter(fn {_k, codes} -> not MapSet.disjoint?(MapSet.difference(codes, shared), bare) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp has_spine?(cluster), do: Enum.any?(cluster, fn {scheme, _} -> scheme == :gtin end)
  defp key_num("SK_" <> n), do: String.to_integer(n)
end

defmodule Stewardship do
  @doc "Flag every attribute priority cannot settle (a tie at the top tier)."
  def detect(members, live_claims, priority, at) do
    attrs = Enum.filter(live_claims, &(&1.kind == :attribute))

    for {key, codes} <- members,
        {field, decision} <- Survivorship.field_decisions(codes, attrs, priority),
        decision.status == :needs_review do
      %Events.ConflictFlagged{subject: {:attr, key, field}, candidates: decision.candidates, recorded_at: at}
    end
  end

  @doc "Flag a CODE COLLISION: one variant whose grouping claims point at >1 distinct product."
  def detect_collisions(members, live_claims, at) do
    groups = Enum.filter(live_claims, &(&1.kind == :grouping))

    for {key, codes} <- members,
        prods = products_of(codes, groups),
        length(Enum.uniq(Enum.map(prods, & &1.product))) > 1 do
      %Events.ConflictFlagged{subject: {:collision, key}, candidates: prods, recorded_at: at}
    end
  end

  defp products_of(codes, groups) do
    groups
    |> Enum.filter(&MapSet.member?(codes, &1.data.code))
    |> Enum.map(&%{source: &1.source, product: &1.data.product})
  end

  def resolve_attribute(key, field, value, by, at),
    do: [
      %Events.ConflictResolved{
        subject: {:attr, key, field},
        decision: {:pick, value},
        by: by,
        recorded_at: at
      }
    ]

  def reject_merge(keys, by, at),
    do: [
      %Events.ConflictResolved{
        subject: {:merge, Enum.sort(keys)},
        decision: :rejected,
        by: by,
        recorded_at: at
      }
    ]

  def mark_shared(scheme_code, by, at),
    do: [%Events.ConflictResolved{subject: {:code, scheme_code}, decision: :shared, by: by, recorded_at: at}]

  @doc "Steward verdict on a code collision: this variant truly belongs to ONE product."
  def resolve_collision(key, product, by, at),
    do: [
      %Events.ConflictResolved{
        subject: {:collision, key},
        decision: {:product, product},
        by: by,
        recorded_at: at
      }
    ]

  def approve_merge(members, keys, by, at) do
    [survivor | _] = Enum.sort(keys)
    union = keys |> Enum.map(&Map.get(members, &1, MapSet.new())) |> Enum.reduce(&MapSet.union/2)

    [
      %Events.IdentitiesMerged{from: Enum.sort(keys), into: survivor, recorded_at: at},
      %Events.IdentityMembersChanged{key: survivor, codes: union, recorded_at: at},
      %Events.ConflictResolved{
        subject: {:merge, Enum.sort(keys)},
        decision: :approved,
        by: by,
        recorded_at: at
      }
    ]
  end

  @doc "Codes a steward has declared legitimately shared (read from the log)."
  def shared_codes(log) do
    for %Events.ConflictResolved{subject: {:code, c}, decision: :shared} <- log, into: MapSet.new(), do: c
  end

  @doc "Pair each flagged conflict with its verdict (or nil if still open)."
  def queue(log) do
    resolved = for %Events.ConflictResolved{} = e <- log, into: %{}, do: {e.subject, e}
    for %Events.ConflictFlagged{} = f <- log, do: {f, Map.get(resolved, f.subject)}
  end
end

defmodule Catalog do
  # overrides: %{attr: %{{key, field} => ConflictResolved}, product: %{key => product}}
  def project(members, live_claims, priority, overrides) do
    attrs = Enum.filter(live_claims, &(&1.kind == :attribute))
    groups = Enum.filter(live_claims, &(&1.kind == :grouping))
    media = Enum.filter(live_claims, &(&1.kind == :media))
    edges = Enum.filter(live_claims, &(&1.kind == :member_of))

    members
    |> Enum.map(fn {key, codes} ->
      %{
        key: key,
        codes: Enum.sort(MapSet.to_list(codes)),
        attributes: resolve_attributes(key, codes, attrs, priority, overrides.attr),
        product: resolve_product(key, codes, groups, priority, overrides.product),
        media: resolve_media(codes, media, priority),
        categories: resolve_categories(codes, edges)
      }
    end)
    |> Enum.group_by(& &1.product.value)
    |> Enum.sort_by(fn {product, _} -> product end)
    |> Enum.map(fn {product, vs} -> %{product: product, variants: Enum.sort_by(vs, & &1.key)} end)
  end

  defp resolve_attributes(key, codes, attrs, priority, attr_overrides) do
    codes
    |> Survivorship.field_decisions(attrs, priority)
    |> Enum.map(fn {field, base} -> {field, apply_override(base, Map.get(attr_overrides, {key, field}))} end)
    |> Enum.sort()
  end

  defp apply_override(base, nil), do: base

  defp apply_override(base, %Events.ConflictResolved{decision: {:pick, v}, by: by}),
    do: %{base | value: v, winner: "steward:#{by}", status: :resolved_by_steward}

  defp resolve_product(key, codes, groups, priority, product_overrides) do
    case Map.get(product_overrides, key) do
      nil -> resolve_product_from_claims(codes, groups, priority)
      product -> %{value: product, winner: :steward, status: :resolved_by_steward, candidates: []}
    end
  end

  # Media attaches by code, exactly like an attribute — so it RE-HOMES automatically when a
  # split/merge moves its target code to a different surrogate key. Dedup by asset identity;
  # the highest-priority source wins each asset's metadata.
  defp resolve_media(codes, media, priority) do
    media
    |> Enum.filter(&MapSet.member?(codes, &1.data.target))
    |> Enum.group_by(& &1.data.asset)
    |> Enum.map(fn {asset, claims} ->
      best = Enum.min_by(claims, &Priority.rank(priority, :media, &1.source))
      %{asset: asset, role: best.data.role, source: best.source, uri: best.data.uri}
    end)
    |> Enum.sort_by(fn m -> {m.role != :primary, m.asset} end)
  end

  # Collection membership (e.g. ATC categories) attaches by code too, so it re-homes on a split,
  # and unions across sources by default. Each edge points the member's code at a collection code.
  defp resolve_categories(codes, edges) do
    edges
    |> Enum.filter(&MapSet.member?(codes, &1.data.member_code))
    |> Enum.map(& &1.data.collection)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp resolve_product_from_claims(codes, groups, priority) do
    groups
    |> Enum.filter(&MapSet.member?(codes, &1.data.code))
    |> Enum.map(&%{source: &1.source, value: &1.data.product, order: &1.order})
    |> case do
      [] ->
        %{value: {:none, "—"}, winner: nil, status: :resolved, candidates: []}

      entries ->
        base = Survivorship.decide(:product, entries, priority)
        # Contested: a single variant pointing at >1 product is a code collision — surface it.
        if entries |> Enum.map(& &1.value) |> Enum.uniq() |> length() > 1,
          do: %{base | status: :needs_review},
          else: base
    end
  end
end

defmodule History do
  @far_future ~D[9999-12-31]

  def project_bitemporal(log, as_known, effective_on, priority) do
    upto = Enum.filter(log, &(Date.compare(&1.recorded_at, as_known) != :gt))
    members = Enum.reduce(upto, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1)).members
    overrides = overrides_from(upto)

    claims =
      for(%Events.ClaimAsserted{} = e <- upto, do: e)
      |> Substrate.current()
      |> Enum.filter(&(Date.compare(&1.valid_from, effective_on) != :gt))

    Catalog.project(members, claims, priority, overrides)
  end

  def project_as_of(log, date, priority), do: project_bitemporal(log, date, @far_future, priority)

  def project_valid_as_of(log, valid_date, priority),
    do: project_bitemporal(log, @far_future, valid_date, priority)

  def now(log, priority), do: project_bitemporal(log, @far_future, @far_future, priority)

  def lineage(log, key) do
    Enum.filter(log, fn
      %Events.IdentityMinted{key: k} -> k == key
      %Events.IdentityMembersChanged{key: k} -> k == key
      %Events.IdentitiesMerged{from: from, into: into} -> key in from or into == key
      %Events.IdentitySplit{key: k, into: into} -> k == key or Enum.any?(into, fn {nk, _} -> nk == key end)
      %Events.ConflictFlagged{subject: {:merge, keys}} -> key in keys
      %Events.ConflictFlagged{subject: {:attr, k, _}} -> k == key
      %Events.ConflictFlagged{subject: {:collision, k}} -> k == key
      %Events.ConflictResolved{subject: {:merge, keys}} -> key in keys
      %Events.ConflictResolved{subject: {:attr, k, _}} -> k == key
      %Events.ConflictResolved{subject: {:collision, k}} -> k == key
      _ -> false
    end)
  end

  defp overrides_from(events) do
    resolved = for %Events.ConflictResolved{} = e <- events, do: e

    attr =
      resolved
      |> Enum.filter(&match?(%Events.ConflictResolved{subject: {:attr, _, _}, decision: {:pick, _}}, &1))
      |> Enum.group_by(fn %Events.ConflictResolved{subject: {:attr, k, d}} -> {k, d} end)
      |> Map.new(fn {k, evs} -> {k, Enum.max_by(evs, & &1.order)} end)

    product =
      resolved
      |> Enum.filter(&match?(%Events.ConflictResolved{subject: {:collision, _}, decision: {:product, _}}, &1))
      |> Enum.group_by(fn %Events.ConflictResolved{subject: {:collision, k}} -> k end)
      |> Map.new(fn {k, evs} -> {k, evs |> Enum.max_by(& &1.order) |> Map.fetch!(:decision) |> elem(1)} end)

    %{attr: attr, product: product}
  end
end

defmodule Api do
  @moduledoc """
  The read layer we sell to customers. Two rules make splits/merges survivable:
    * customers address by CODE (resolved to the current owner), not by surrogate key, and
    * every key carries an identity status so a stale key redirects instead of breaking.
  Plus a change feed (the identity events) so customers can reconcile their local copies.
  """

  @doc "Identity status of a key, derived from the log: :active | :merged (-> survivor) | :split (-> parts)."
  def identity_status(log, key) do
    superseded_by =
      Enum.find_value(log, fn
        %Events.IdentitiesMerged{from: from, into: into} -> if key in from and key != into, do: into
        _ -> nil
      end)

    split_into =
      Enum.find_value(log, fn
        %Events.IdentitySplit{key: ^key, into: into} -> [key | Enum.map(into, &elem(&1, 0))]
        _ -> nil
      end)

    cond do
      superseded_by != nil -> %{status: :merged, superseded_by: superseded_by}
      split_into != nil -> %{status: :split, split_into: split_into}
      true -> %{status: :active}
    end
  end

  @doc "Resolve any code (canonical OR alias) to the surrogate key that currently owns it."
  def resolve_key(log, code) do
    canon = Codes.canonicalize(code)
    Enum.find_value(ledger(log).members, fn {k, codes} -> if MapSet.member?(codes, canon), do: k end)
  end

  @doc "Customer lookup by code — the robust access pattern. Returns the current record + identity block."
  def lookup(log, code, priority) do
    case resolve_key(log, code) do
      nil -> {:not_found, Codes.canonicalize(code)}
      key -> {:ok, get(log, key, priority)}
    end
  end

  @doc "Fetch by surrogate key with its identity status (a stale key still answers, with a redirect)."
  def get(log, key, priority) do
    variant = log |> History.now(priority) |> Enum.flat_map(& &1.variants) |> Enum.find(&(&1.key == key))
    %{key: key, identity: identity_status(log, key), variant: variant}
  end

  @doc "Change feed: identity events after `cursor`, so customers can repair local copies after churn."
  def changes_since(log, cursor) do
    Enum.filter(log, fn e -> identity_event?(e) and (e.order || 0) > cursor end)
  end

  defp identity_event?(%Events.IdentityMinted{}), do: true
  defp identity_event?(%Events.IdentityMembersChanged{}), do: true
  defp identity_event?(%Events.IdentitiesMerged{}), do: true
  defp identity_event?(%Events.IdentitySplit{}), do: true
  defp identity_event?(_), do: false

  defp ledger(log), do: Enum.reduce(log, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
end

defmodule PublicId do
  @moduledoc """
  Identity-grade, customer-facing schemes like CNK. The surrogate key is internal; CNK is the
  public key — strictly unique, never shared. Two sources giving different CNKs for the same
  product is fine: they become canonical + alias(es) on one key, with the canonical chosen by
  priority. The customer resolves by ANY of them.
  """

  @doc "Canonical public id of `scheme` for `key` (by source priority), plus its aliases."
  def canonical(scheme, key, log, priority) do
    codes = ledger(log).members |> Map.get(key, MapSet.new()) |> Enum.filter(fn {s, _} -> s == scheme end)

    case codes do
      [] ->
        nil

      _ ->
        idclaims = identity_claims(log)

        entries =
          for code <- codes, src <- sources_of(code, idclaims), do: %{source: src, value: code, order: 0}

        winner = if entries == [], do: hd(codes), else: Survivorship.decide(scheme, entries, priority).value
        %{canonical: winner, aliases: List.delete(codes, winner)}
    end
  end

  @doc "Identity-grade INVARIANT check: a code of `scheme` must never own >1 key. Returns violations."
  def collisions(scheme, log) do
    ledger(log).members
    |> Enum.flat_map(fn {k, codes} -> for {s, _} = c <- codes, s == scheme, do: {c, k} end)
    |> Enum.group_by(fn {c, _} -> c end, fn {_, k} -> k end)
    |> Enum.filter(fn {_c, keys} -> length(Enum.uniq(keys)) > 1 end)
    |> Enum.map(fn {c, keys} -> %{code: c, keys: Enum.sort(Enum.uniq(keys))} end)
  end

  defp sources_of(code, idclaims), do: for(c <- idclaims, code in c.data.codes, do: c.source)

  defp identity_claims(log),
    do: for(%Events.ClaimAsserted{kind: :identity} = e <- log, do: e) |> Substrate.current()

  defp ledger(log), do: Enum.reduce(log, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
end
