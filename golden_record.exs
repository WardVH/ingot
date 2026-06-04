# golden_record.exs — a runnable explainer for a multi-source product master-data model.
#
#   Run:  elixir golden_record.exs
#
# It is PURE data + functions — there is no mutable runtime state, no concurrency,
# no fault isolation to manage, so (per Elixir's "no process without a runtime reason")
# there is not a single GenServer here. The whole engine is `f(claims, rules) -> golden`.
#
# The design it demonstrates (from our brainstorm):
#   1. CLAIMS SUBSTRATE      Sources assert immutable, versioned claims. Nothing is ever
#                            overwritten; a newer claim from the same source *supersedes*.
#   2. PER-DIMENSION PRIORITY Each field/scheme has its own ranked list of source *tiers*.
#                            Two sources in the same tier that disagree => NEEDS REVIEW.
#   3. CLUSTER -> RECONCILE    Resolution is two pure steps: cluster the raw evidence, then
#                            match clusters to STABLE surrogate keys via an identity xref
#                            ledger. We match against EVIDENCE, never against golden.
#   4. IDENTITY EVENTS       mint / keep / merge / split — the xref is revisable, with lineage.
#   5. GOLDEN PROJECTION     The read model: product -> variants -> winning attributes, with
#                            losers retained as provenance and unresolved conflicts flagged.

# ── 1. The substrate ────────────────────────────────────────────────────────────────────

defmodule Claim do
  @moduledoc "One immutable, versioned assertion from a single source."
  @enforce_keys [:source, :kind, :data, :seq]
  defstruct [:source, :kind, :data, :seq]

  # `seq` is a monotonic counter standing in for an observation timestamp.
  # A claim's "slot" is what a newer claim from the same source supersedes.
  defp slot(%Claim{source: s, kind: :identity, data: %{ref: r}}), do: {s, :identity, r}
  defp slot(%Claim{source: s, kind: :grouping, data: %{code: c}}), do: {s, :grouping, c}
  defp slot(%Claim{source: s, kind: :attribute, data: %{code: c, field: f}}), do: {s, :attr, c, f}

  @doc "Collapse the append-only substrate to the currently-live claim per slot (max seq wins)."
  def live(claims) do
    claims
    |> Enum.group_by(&slot/1)
    |> Enum.map(fn {_slot, cs} -> Enum.max_by(cs, & &1.seq) end)
  end
end

defmodule Feed do
  @moduledoc "Tiny builders so the example data reads like a feed."
  def identity(seq, source, ref, codes),
    do: %Claim{source: source, kind: :identity, seq: seq, data: %{ref: ref, codes: codes}}

  def grouping(seq, source, code, product),
    do: %Claim{source: source, kind: :grouping, seq: seq, data: %{code: code, product: product}}

  def attribute(seq, source, code, field, value),
    do: %Claim{source: source, kind: :attribute, seq: seq, data: %{code: code, field: field, value: value}}
end

# ── 2. Per-dimension priority ─────────────────────────────────────────────────────────────

defmodule Priority do
  @moduledoc """
  A table of dimension -> ranked source *tiers*, with a default fallback ordering.
  A dimension is an attribute field (:weight_g) or :product (for grouping). Sources sharing
  a tier are equally trusted, so a disagreement among them cannot be auto-resolved.
  """
  @enforce_keys [:table, :default]
  defstruct [:table, :default]

  def new(table, default), do: %__MODULE__{table: table, default: default}

  @doc "Rank of a source for a dimension: lower = more trusted; :infinity if unranked."
  def rank(%__MODULE__{table: table, default: default}, dimension, source) do
    tiers = Map.get(table, dimension, default)
    Enum.find_index(tiers, fn tier -> source in tier end) || :infinity
  end
end

# ── 3a. Clustering: pure grouping of evidence ───────────────────────────────────────────────

defmodule Cluster do
  @moduledoc """
  Pure functions over the live claims. `variants/1` groups identity codes into variant
  clusters by transitive shared-code linkage (the candidate matcher — in production this
  step is pluggable: spine-first, then overlap, then fuzzy). No surrogate keys here.
  """
  def variants(live_claims) do
    live_claims
    |> Enum.filter(&(&1.kind == :identity))
    |> Enum.map(fn c -> MapSet.new(c.data.codes) end)
    |> connected_components()
    |> Enum.sort_by(&Enum.min/1)
  end

  # Merge any two code-sets that share a code, transitively.
  defp connected_components(sets) do
    Enum.reduce(sets, [], fn set, acc ->
      {overlapping, disjoint} = Enum.split_with(acc, fn comp -> not MapSet.disjoint?(comp, set) end)
      merged = Enum.reduce(overlapping, set, fn comp, m -> MapSet.union(m, comp) end)
      [merged | disjoint]
    end)
  end
end

# ── 3b. Reconcile clusters to STABLE surrogate keys via the identity xref ledger ─────────────

defmodule Xref do
  @moduledoc """
  The identity cross-reference ledger: surrogate_key -> set of member codes ever resolved
  to it. It is the bridge between volatile clusters and stable keys, and the thing a NEW
  source is matched against (never golden). Matching signal: identifier OVERLAP, with the
  spine code (a GTIN) as the tiebreaker on a split. It is revisable — split/merge with lineage.
  """
  @enforce_keys [:members, :next]
  defstruct [:members, :next]

  def new, do: %__MODULE__{members: %{}, next: 1}

  def reconcile(%__MODULE__{} = xref, clusters) do
    original = xref.members

    # Pass 1: each cluster matches the keys it overlaps in the *prior* ledger.
    {assigns, xref, events} =
      Enum.reduce(clusters, {[], xref, []}, fn cluster, {assigns, xr, evs} ->
        case overlapping_keys(original, cluster) do
          [] ->
            {key, xr} = mint(xr, cluster)
            {[{cluster, key} | assigns], xr, [{:mint, key, cluster} | evs]}

          [key] ->
            {[{cluster, key} | assigns], absorb(xr, key, cluster), [{:keep, key, cluster} | evs]}

          many ->
            survivor = Enum.min(many)
            xr = Enum.reduce(many -- [survivor], xr, &forget(&2, &1))
            {[{cluster, survivor} | assigns], absorb(xr, survivor, cluster),
             [{:merge, many, survivor} | evs]}
        end
      end)

    # Pass 2: a surviving key now claimed by >1 cluster means a prior merge was wrong -> SPLIT.
    {assigns, xref, split_events} = split_pass(assigns, xref, original)

    {Enum.reverse(events) ++ Enum.reverse(split_events), xref, assigns}
  end

  defp split_pass(assigns, xref, original) do
    assigns
    |> Enum.group_by(fn {_cluster, key} -> key end)
    |> Enum.reduce({[], xref, []}, fn
      {_key, [single]}, {acc, xr, evs} ->
        {[single | acc], xr, evs}

      {key, multiple}, {acc, xr, evs} ->
        prior = Map.get(original, key, MapSet.new())

        # Keep the key for the spine-bearing (GTIN) cluster, then largest overlap.
        {keep_cluster, _} =
          Enum.max_by(multiple, fn {cluster, _} ->
            {has_spine?(cluster), MapSet.size(MapSet.intersection(cluster, prior))}
          end)

        {minted, xr} =
          multiple
          |> Enum.map(&elem(&1, 0))
          |> List.delete(keep_cluster)
          |> Enum.map_reduce(xr, fn cluster, acc ->
            {new_key, acc} = mint(acc, cluster)
            {{cluster, new_key}, acc}
          end)

        xr = reset(xr, key, keep_cluster)
        event = {:split, key, Enum.map(minted, fn {_c, k} -> k end)}
        {[{keep_cluster, key} | minted] ++ acc, xr, [event | evs]}
    end)
  end

  defp overlapping_keys(members, cluster) do
    members
    |> Enum.filter(fn {_k, codes} -> not MapSet.disjoint?(codes, cluster) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp has_spine?(cluster), do: Enum.any?(cluster, fn {scheme, _} -> scheme == :gtin end)

  defp mint(%__MODULE__{members: m, next: n} = xr, cluster),
    do: {"SK_#{n}", %{xr | members: Map.put(m, "SK_#{n}", cluster), next: n + 1}}

  defp absorb(%__MODULE__{members: m} = xr, key, cluster),
    do: %{xr | members: Map.update(m, key, cluster, &MapSet.union(&1, cluster))}

  defp forget(%__MODULE__{members: m} = xr, key), do: %{xr | members: Map.delete(m, key)}
  defp reset(%__MODULE__{members: m} = xr, key, cluster), do: %{xr | members: Map.put(m, key, cluster)}
end

# ── 4. Golden projection: the read model ────────────────────────────────────────────────────

defmodule Golden do
  @moduledoc "Projects assignments + live claims + priority into product -> variants -> values."

  def project(assigns, live, priority) do
    attrs = Enum.filter(live, &(&1.kind == :attribute))
    groups = Enum.filter(live, &(&1.kind == :grouping))

    assigns
    |> Enum.map(fn {cluster, key} ->
      %{
        key: key,
        codes: Enum.sort(MapSet.to_list(cluster)),
        attributes: resolve_attributes(cluster, attrs, priority),
        product: resolve_product(cluster, groups, priority)
      }
    end)
    |> Enum.group_by(& &1.product.value)
    |> Enum.sort_by(fn {product, _} -> product end)
    |> Enum.map(fn {product, vs} -> %{product: product, variants: Enum.sort_by(vs, & &1.key)} end)
  end

  defp resolve_attributes(cluster, attrs, priority) do
    attrs
    |> Enum.filter(&MapSet.member?(cluster, &1.data.code))
    |> Enum.group_by(& &1.data.field)
    |> Enum.map(fn {field, cs} ->
      entries = Enum.map(cs, &%{source: &1.source, value: &1.data.value, seq: &1.seq})
      {field, decide(field, entries, priority)}
    end)
    |> Enum.sort()
  end

  defp resolve_product(cluster, groups, priority) do
    groups
    |> Enum.filter(&MapSet.member?(cluster, &1.data.code))
    |> Enum.map(&%{source: &1.source, value: &1.data.product, seq: &1.seq})
    |> case do
      [] -> %{value: {:none, "—"}, winner: nil, status: :resolved, candidates: []}
      entries -> decide(:product, entries, priority)
    end
  end

  # The survivorship rule: keep latest-per-source, rank by priority, winner takes it.
  # If two sources share the top tier with differing values, it cannot be auto-decided.
  defp decide(dimension, entries, priority) do
    latest =
      entries
      |> Enum.group_by(& &1.source)
      |> Enum.map(fn {_s, es} -> Enum.max_by(es, & &1.seq) end)

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

# ── The worked example + narration ──────────────────────────────────────────────────────────

defmodule Demo do
  @priority Priority.new(
              %{
                # manufacturer is authoritative on weight; supplier & marketplace are a tied 2nd tier
                weight_g: [[:manufacturer], [:supplier, :marketplace]],
                # marketplace writes the best titles
                name: [[:marketplace], [:manufacturer], [:supplier]],
                # grouping into products: trust the manufacturer, then supplier, then marketplace
                product: [[:manufacturer], [:supplier], [:marketplace]]
              },
              [[:manufacturer], [:supplier], [:marketplace]]
            )

  # GTIN 0111 + UPC 9111 are first reported as ONE 250ml item by the supplier (a mis-key, as
  # we'll discover). 0222 is the 500ml. Both 250ml & 500ml belong to product SH-LAV.
  @run1 [
    Feed.identity(1, :supplier, "S-100", [{:gtin, "0111"}, {:upc, "9111"}]),
    Feed.identity(2, :manufacturer, "MF-1", [{:gtin, "0111"}]),
    Feed.identity(3, :supplier, "S-101", [{:gtin, "0222"}]),
    Feed.grouping(4, :supplier, {:gtin, "0111"}, {:mpn, "SH-LAV"}),
    Feed.grouping(5, :supplier, {:gtin, "0222"}, {:mpn, "SH-LAV"}),
    Feed.attribute(6, :supplier, {:gtin, "0111"}, :weight_g, 260),
    Feed.attribute(7, :manufacturer, {:gtin, "0111"}, :weight_g, 255),
    Feed.attribute(8, :supplier, {:gtin, "0111"}, :name, "Shampoo 250"),
    Feed.attribute(9, :marketplace, {:gtin, "0111"}, :name, "Brand X Lavender Shampoo 250ml"),
    Feed.attribute(10, :supplier, {:gtin, "0222"}, :weight_g, 520),
    Feed.attribute(11, :marketplace, {:gtin, "0222"}, :weight_g, 525),
    Feed.attribute(12, :supplier, {:gtin, "0222"}, :name, "Shampoo 500")
  ]

  # Run 2: a correction + an update arrive (appended, never overwriting).
  @run2_extra [
    # manufacturer revises 0111's weight (supersedes #7) -> golden recomputes, key stays stable
    Feed.attribute(14, :manufacturer, {:gtin, "0111"}, :weight_g, 250),
    # supplier corrects S-100: 9111 was mis-keyed; it is NOT part of the 250ml (supersedes #1)
    Feed.identity(15, :supplier, "S-100", [{:gtin, "0111"}]),
    # marketplace asserts 9111 is its own item (a 10ml sample) under a different product
    Feed.identity(16, :marketplace, "M-9", [{:upc, "9111"}]),
    Feed.grouping(17, :marketplace, {:upc, "9111"}, {:mpn, "SH-MINI"}),
    Feed.attribute(18, :marketplace, {:upc, "9111"}, :name, "Lavender Sample 10ml")
  ]

  def run do
    title("1. THE SUBSTRATE  —  immutable, versioned claims from three sources")
    Enum.each(@run1, &IO.puts("    " <> fmt_claim(&1)))

    title("2. PRIORITY  —  per-dimension ranked source tiers (same tier = equally trusted)")
    Enum.each(@priority.table, fn {dim, tiers} ->
      IO.puts("    #{pad(dim, 9)}: #{Enum.map_join(tiers, "  >  ", &Enum.join(&1, "="))}")
    end)
    IO.puts("    #{pad("(default)", 9)}: #{Enum.map_join(@priority.default, "  >  ", &Enum.join(&1, "="))}")

    title("3. RUN #1  —  cluster, reconcile (all new => MINT), project to golden")
    live1 = Claim.live(@run1)
    clusters1 = Cluster.variants(live1)
    IO.puts("    clusters: #{fmt_clusters(clusters1)}")
    {events1, xref1, assigns1} = Xref.reconcile(Xref.new(), clusters1)
    print_events(events1)
    print_xref(xref1)
    print_golden(Golden.project(assigns1, live1, @priority))

    title("4. RUN #2  —  a correction + an update arrive (appended to the substrate)")
    Enum.each(@run2_extra, &IO.puts("    " <> fmt_claim(&1)))
    all = @run1 ++ @run2_extra
    live2 = Claim.live(all)
    print_superseded(all, live2)

    clusters2 = Cluster.variants(live2)
    IO.puts("\n    clusters now: #{fmt_clusters(clusters2)}")
    # NOTE: the SAME ledger from run #1 is threaded in — new sources match the XREF, not golden.
    {events2, xref2, assigns2} = Xref.reconcile(xref1, clusters2)
    print_events(events2)
    print_xref(xref2)
    print_golden(Golden.project(assigns2, live2, @priority))

    title("WHAT JUST HAPPENED")
    [
      "SK_1 / SK_2 stayed STABLE across the update — identity is anchored in the xref, not the codes.",
      "The supplier's mis-key self-healed: removing 9111 emitted a SPLIT (SK_1 kept the GTIN; SK_3 minted).",
      "manufacturer's new weight (250) superseded the old (255) — no overwrite, golden just recomputed.",
      "0222's weight is NEEDS REVIEW: supplier=520 and marketplace=525 sit in the same priority tier.",
      "Every loser is retained as provenance (see '↳ claims'); nothing was silently discarded."
    ]
    |> Enum.each(&IO.puts("    • " <> &1))
  end

  # ── presentation helpers ──
  defp title(t), do: IO.puts("\n" <> String.duplicate("─", 92) <> "\n  " <> t <> "\n")
  defp pad(x, n), do: String.pad_trailing(to_string(x), n)
  defp fmt_code({scheme, code}), do: "#{scheme}:#{code}"
  defp fmt_codes(codes), do: Enum.map_join(codes, ", ", &fmt_code/1)
  defp fmt_val({_, _} = c), do: fmt_code(c)
  defp fmt_val(v) when is_binary(v), do: ~s("#{v}")
  defp fmt_val(v), do: to_string(v)

  defp fmt_clusters(clusters),
    do: Enum.map_join(clusters, "  ", fn c -> "{#{fmt_codes(Enum.sort(MapSet.to_list(c)))}}" end)

  defp fmt_claim(%Claim{kind: :identity, source: s, seq: n, data: %{ref: r, codes: codes}}),
    do: "##{pad(n, 2)} #{pad(s, 12)} identity  #{pad(r, 6)} = {#{fmt_codes(codes)}}"

  defp fmt_claim(%Claim{kind: :grouping, source: s, seq: n, data: %{code: c, product: p}}),
    do: "##{pad(n, 2)} #{pad(s, 12)} group     #{pad(fmt_code(c), 11)} -> #{fmt_code(p)}"

  defp fmt_claim(%Claim{kind: :attribute, source: s, seq: n, data: %{code: c, field: f, value: v}}),
    do: "##{pad(n, 2)} #{pad(s, 12)} attr      #{pad(fmt_code(c), 11)} . #{pad(f, 8)} = #{fmt_val(v)}"

  defp print_superseded(all, live) do
    superseded = all -- live

    case superseded do
      [] -> :ok
      _ -> IO.puts("\n    superseded by newer claims: " <> Enum.map_join(superseded, ", ", &"##{&1.seq}"))
    end
  end

  defp print_events(events) do
    IO.puts("\n    identity events:")
    Enum.each(events, &IO.puts("      " <> fmt_event(&1)))
  end

  defp fmt_event({:mint, key, cluster}),
    do: "MINT  #{key}  <- brand-new identity {#{fmt_codes(Enum.sort(MapSet.to_list(cluster)))}}"

  defp fmt_event({:keep, key, cluster}),
    do: "KEEP  #{key}  <- matched existing key by overlap {#{fmt_codes(Enum.sort(MapSet.to_list(cluster)))}}"

  defp fmt_event({:merge, keys, survivor}),
    do: "MERGE #{Enum.join(keys, " + ")} -> #{survivor}"

  defp fmt_event({:split, key, into}),
    do: "SPLIT #{key} -> kept #{key}, minted #{Enum.join(into, ", ")} (spine stays on the GTIN cluster)"

  defp print_xref(%Xref{members: members}) do
    IO.puts("\n    xref ledger:")

    members
    |> Enum.sort()
    |> Enum.each(fn {k, codes} ->
      IO.puts("      #{k} -> {#{fmt_codes(Enum.sort(MapSet.to_list(codes)))}}")
    end)
  end

  defp print_golden(products) do
    IO.puts("\n    GOLDEN:")

    Enum.each(products, fn %{product: product, variants: variants} ->
      IO.puts("      PRODUCT  #{fmt_val(product)}")

      Enum.each(variants, fn v ->
        IO.puts("        variant #{v.key}   [#{fmt_codes(v.codes)}]")

        Enum.each(v.attributes, fn {field, d} ->
          mark = if d.status == :needs_review, do: "  <-- NEEDS REVIEW (priority tie)", else: ""
          IO.puts("          #{pad(field, 9)}= #{pad(fmt_val(d.value), 34)} (#{d.winner})#{mark}")
          IO.puts("            claims: " <> Enum.map_join(d.candidates, "   ", fn {s, val} -> "#{s}=#{fmt_val(val)}" end))
        end)
      end)
    end)
  end
end

Demo.run()
