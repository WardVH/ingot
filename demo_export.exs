# demo_export.exs — export the story-demo scenes to JSON for the viz/ web app (bead gr-0cj).
#
#   Run:  mix run demo_export.exs   ->   viz/src/data/story.json
#
# Drives the REAL engine (Substrate / Cluster / IdentityLedger / Survivorship / Stewardship /
# History from lib/golden_record_core.ex) through three synthetic story scenarios, capturing a
# named snapshot after each beat: the claim log so far, the events that beat emitted, the
# projected golden record(s), and the open steward queue. The viz replays snapshots; it computes
# nothing. The `oldWay` scene is the one hand-authored exception — destructive merging is what
# this engine refuses to do, so it cannot be engine-exported (the viz labels it an illustration).
#
# The story each scene tells (design: docs/plans/2026-06-10-story-demo-design.md):
#   claims   — sources assert code-anchored claims; a golden record materializes as a fold.
#   priority — three sources disagree on weight; tiers rank them; a top-tier tie goes to the steward.
#   mistake  — a steward approves a wrong merge; the contradiction surfaces (evidence was never
#              destroyed); the steward splits; every attribute and media claim re-homes by code.
#
# GENERATED FILE — do not hand-edit story.json; re-run this script.

defmodule DemoExport do
  @out "viz/src/data/story.json"

  def run do
    data = %{
      oldWay: old_way(),
      claims: claims_scene(),
      priority: priority_scene(),
      mistake: mistake_scene()
    }

    File.mkdir_p!(Path.dirname(@out))
    File.write!(@out, JSON.encode!(data))
    IO.puts("wrote #{@out} (#{File.stat!(@out).size} bytes)")
  end

  # ── chapter 1: the old way (hand-authored — the engine refuses to do this) ───────────────────────
  defp old_way do
    a = %{
      source: "Import A",
      code: "gtin:05410013100072",
      name: "Sunscreen SPF 50 — 200 ml",
      weight_g: 250,
      image: "img-a"
    }

    b = %{
      source: "Import B",
      code: "gtin:08712345678906",
      name: "Sunscreen SPF50 200ml (tube)",
      weight_g: 480,
      image: "img-b"
    }

    merged = %{
      source: nil,
      codes: [a.code, b.code],
      name: a.name,
      weight_g: a.weight_g,
      image: a.image
    }

    %{
      label: "the old way (illustration)",
      steps: [
        %{id: "two-records", a: a, b: b},
        %{id: "match", a: a, b: b, matchedOn: "name similarity"},
        %{id: "merge", merged: merged, lost: ["weight 480 g", "image img-b", "which source said what"]},
        %{
          id: "import",
          merged: %{merged | weight_g: 480, source: "Import C"},
          lost: ["weight 250 g — overwritten in place", "any way back"]
        }
      ]
    }
  end

  # ── chapter 2: claims, not records ────────────────────────────────────────────────────────────────
  defp claims_scene do
    priority = Priority.new(%{}, [[:manufacturer], [:supplier]])
    gtin = {:gtin, "05410013100072"}
    cnk = {:cnk, "1234567"}

    beats = [
      {"first-claim", ~D[2026-01-05],
       {:claims,
        [
          identity(:manufacturer, "MFR-SUN50", [gtin], ~D[2026-01-05]),
          attribute(:manufacturer, gtin, :name, "Sunscreen SPF 50 — 200 ml", ~D[2026-01-05])
        ]}},
      {"first-attribute", ~D[2026-01-12],
       {:claims, [attribute(:manufacturer, gtin, :weight_g, 250, ~D[2026-01-12])]}},
      {"second-source", ~D[2026-02-03],
       {:claims, [identity(:supplier, "SUP-88431", [cnk, gtin], ~D[2026-02-03])]}},
      {"media", ~D[2026-02-10],
       {:claims,
        [
          Substrate.claim(
            :supplier,
            :media,
            %{asset: {:dam, "IMG-1"}, target: cnk, role: :primary, uri: "cdn://sunscreen-front"},
            ~D[2026-02-10],
            ~D[2026-02-10]
          )
        ]}}
    ]

    %{label: "claims, not records", tiers: tiers_view(priority), steps: run_beats(beats, priority)}
  end

  # ── chapter 3: who wins? ──────────────────────────────────────────────────────────────────────────
  defp priority_scene do
    # weight has strict tiers; color deliberately puts manufacturer and supplier in ONE tier,
    # so a disagreement is honestly undecidable -> steward.
    priority =
      Priority.new(
        %{color: [[:manufacturer, :supplier], [:marketplace]]},
        [[:manufacturer], [:supplier], [:marketplace]]
      )

    gtin = {:gtin, "05410013100072"}

    beats = [
      {"one-product", ~D[2026-03-01],
       {:claims,
        [
          identity(:manufacturer, "MFR-SUN50", [gtin], ~D[2026-03-01]),
          identity(:supplier, "SUP-88431", [gtin], ~D[2026-03-01]),
          identity(:marketplace, "MKT-9917", [gtin], ~D[2026-03-01])
        ]}},
      {"marketplace-weight", ~D[2026-03-02],
       {:claims, [attribute(:marketplace, gtin, :weight_g, 300, ~D[2026-03-02])]}},
      {"supplier-weight", ~D[2026-03-09],
       {:claims, [attribute(:supplier, gtin, :weight_g, 260, ~D[2026-03-09])]}},
      {"manufacturer-weight", ~D[2026-03-16],
       {:claims, [attribute(:manufacturer, gtin, :weight_g, 250, ~D[2026-03-16])]}},
      {"color-tie", ~D[2026-03-20],
       {:claims,
        [
          attribute(:manufacturer, gtin, :color, "white", ~D[2026-03-20]),
          attribute(:supplier, gtin, :color, "ivory", ~D[2026-03-20])
        ]}},
      {"steward-pick", ~D[2026-03-27],
       {:steward,
        fn _ledger -> Stewardship.resolve_attribute("SK_1", :color, "ivory", :sam, ~D[2026-03-27]) end}}
    ]

    %{label: "who wins?", tiers: tiers_view(priority), steps: run_beats(beats, priority)}
  end

  # ── chapter 6: the mistake is cheap ───────────────────────────────────────────────────────────────
  defp mistake_scene do
    # two manufacturers in the SAME weight tier: while the products are distinct there is no
    # conflict (one weight claim each) — the contradiction only becomes visible once fused.
    priority = Priority.new(%{weight_g: [[:acme, :bolt]]}, [[:acme], [:bolt]])

    ga = {:gtin, "05410013100072"}
    ka = {:cnk, "1234567"}
    gb = {:gtin, "08712345678906"}
    kb = {:cnk, "7654321"}

    beats = [
      {"two-products", ~D[2026-04-01],
       {:claims,
        [
          identity(:acme, "ACME-SUN", [ga, ka], ~D[2026-04-01]),
          attribute(:acme, ga, :name, "Sunscreen SPF 50 — 200 ml", ~D[2026-04-01]),
          attribute(:acme, ga, :weight_g, 250, ~D[2026-04-01]),
          Substrate.claim(
            :acme,
            :media,
            %{asset: {:dam, "IMG-A"}, target: ga, role: :primary, uri: "cdn://sun-a"},
            ~D[2026-04-01],
            ~D[2026-04-01]
          ),
          identity(:bolt, "BOLT-2114", [gb, kb], ~D[2026-04-01]),
          attribute(:bolt, gb, :name, "Sunscreen SPF50 200ml (tube)", ~D[2026-04-01]),
          attribute(:bolt, gb, :weight_g, 480, ~D[2026-04-01]),
          Substrate.claim(
            :bolt,
            :media,
            %{asset: {:dam, "IMG-B"}, target: gb, role: :primary, uri: "cdn://sun-b"},
            ~D[2026-04-01],
            ~D[2026-04-01]
          )
        ]}},
      {"wrong-merge", ~D[2026-04-15],
       {:steward,
        fn ledger -> Stewardship.approve_merge(ledger.members, ["SK_1", "SK_2"], :sam, ~D[2026-04-15]) end}},
      {"contradiction", ~D[2026-04-15], :pause},
      {"split", ~D[2026-05-02],
       {:steward, fn ledger -> Stewardship.split(ledger, "SK_1", [[gb, kb]], :sam, ~D[2026-05-02]) end}},
      {"healed", ~D[2026-05-02], :pause}
    ]

    %{label: "the mistake is cheap", tiers: tiers_view(priority), steps: run_beats(beats, priority)}
  end

  # The trust tiers, straight from the scene's ACTUAL Priority struct — the viz shows the same
  # ranking the engine resolves with, so the reasoning on screen can't drift from the engine.
  defp tiers_view(%Priority{table: table, default: default}) do
    rows = for {dim, tiers} <- Enum.sort_by(table, &elem(&1, 0)), do: %{dimension: dim, tiers: tiers}
    rows ++ [%{dimension: "default", tiers: default}]
  end

  # ── the beat engine: fold claims + steward decisions forward, snapshot after each beat ───────────
  defp run_beats(beats, priority, shared \\ MapSet.new()) do
    state = %{log: [], ledger: IdentityLedger.new(), order: 0}

    {steps, _} =
      Enum.map_reduce(beats, state, fn {id, d, action}, st ->
        {new_claims, steward_events} =
          case action do
            {:claims, cs} -> {cs, []}
            {:steward, decide} -> {[], decide.(st.ledger)}
            :pause -> {[], []}
          end

        {stamped_claims, o1} = stamp(new_claims, st.order)
        log1 = st.log ++ stamped_claims

        identity_events =
          case stamped_claims do
            [] -> []
            _ -> IdentityLedger.decide(st.ledger, {:reconcile, clusters(log1, shared), shared, d})
          end

        {stamped_events, o2} = stamp(identity_events ++ steward_events, o1)
        ledger = Enum.reduce(stamped_events, st.ledger, &IdentityLedger.evolve(&2, &1))
        log = log1 ++ stamped_events

        step = %{
          id: id,
          date: date_str(d),
          log: log |> claims_of() |> Enum.map(&claim_view/1),
          events: Enum.map(stamped_events, &event_view/1),
          golden: golden_view(History.now(log, priority)),
          queue: queue_view(ledger.members, log, priority, d)
        }

        {step, %{log: log, ledger: ledger, order: o2}}
      end)

    steps
  end

  defp identity(source, ref, codes, d),
    do: Substrate.claim(source, :identity, %{ref: ref, codes: codes}, d, d)

  defp attribute(source, code, field, value, d),
    do: Substrate.claim(source, :attribute, %{code: code, field: field, value: value}, d, d)

  defp claims_of(log), do: Enum.filter(log, &match?(%Events.ClaimAsserted{}, &1))
  defp clusters(log, shared), do: Cluster.variants(Substrate.current(claims_of(log)), shared)

  defp stamp(entries, start),
    do:
      {entries |> Enum.with_index(start) |> Enum.map(fn {e, i} -> %{e | order: i} end),
       start + length(entries)}

  # ── views (everything below is serialization, no decisions) ──────────────────────────────────────
  defp claim_view(%Events.ClaimAsserted{} = c) do
    %{order: c.order, source: c.source, kind: c.kind, date: date_str(c.recorded_at)}
    |> Map.merge(data_view(c.kind, c.data))
  end

  defp data_view(:identity, d), do: %{ref: d.ref, codes: Enum.map(d.codes, &code_str/1)}
  defp data_view(:attribute, d), do: %{code: code_str(d.code), field: d.field, value: d.value}

  defp data_view(:media, d),
    do: %{asset: code_str(d.asset), target: code_str(d.target), uri: d.uri}

  defp golden_view(grouped) do
    for %{variants: vs} <- grouped, v <- vs do
      %{
        key: v.key,
        codes: Enum.map(v.codes, &code_str/1),
        attributes: Enum.map(v.attributes, &attribute_view/1),
        media: Enum.map(v.media, &%{asset: code_str(&1.asset), source: &1.source, uri: &1.uri})
      }
    end
    |> Enum.sort_by(& &1.key)
  end

  defp attribute_view({field, decision}) do
    %{
      field: field,
      value: decision.value,
      winner: winner_str(decision.winner),
      status: decision.status,
      candidates: Enum.map(decision.candidates, fn {s, v} -> %{source: s, value: v} end)
    }
  end

  # The OPEN steward queue: every conflict the engine cannot settle, minus subjects a steward
  # already resolved. Attribute ties are detected fresh each step (they are a projection, not log
  # entries); merge proposals live in the log because the ledger's reconcile emits them.
  defp queue_view(members, log, priority, d) do
    live = log |> claims_of() |> Substrate.current()
    resolved = for %Events.ConflictResolved{subject: s} <- log, into: MapSet.new(), do: s

    attr_flags =
      for %Events.ConflictFlagged{subject: {:attr, k, f}, candidates: cands} <-
            Stewardship.detect(members, live, priority, d),
          not MapSet.member?(resolved, {:attr, k, f}) do
        %{
          type: "attr",
          key: k,
          field: f,
          candidates: Enum.map(cands, fn {s, v} -> %{source: s, value: v} end)
        }
      end

    merge_flags =
      for(%Events.ConflictFlagged{subject: {:merge, keys}} <- log, do: Enum.sort(keys))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(resolved, {:merge, &1}))
      |> Enum.map(&%{type: "merge", keys: &1})

    attr_flags ++ merge_flags
  end

  defp event_view(%Events.IdentityMinted{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MINT", key: k, codes: codes_str(c)}

  defp event_view(%Events.IdentityMembersChanged{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MEMBERS", key: k, codes: codes_str(c)}

  defp event_view(%Events.IdentitiesMerged{from: from, into: into, recorded_at: at}),
    do: %{date: date_str(at), type: "MERGE", from: from, into: into}

  defp event_view(%Events.IdentitySplit{key: k, kept_codes: kept, into: into, recorded_at: at}),
    do: %{
      date: date_str(at),
      type: "SPLIT",
      key: k,
      kept: codes_str(kept),
      into: Enum.map(into, fn {nk, c} -> %{key: nk, codes: codes_str(c)} end)
    }

  defp event_view(%Events.ConflictFlagged{subject: {:merge, keys}, recorded_at: at}),
    do: %{date: date_str(at), type: "FLAG", keys: keys}

  defp event_view(%Events.ConflictResolved{subject: subject, decision: decision, by: by, recorded_at: at}),
    do: %{
      date: date_str(at),
      type: "DECISION",
      subject: subject_str(subject),
      decision: decision_str(decision),
      by: by
    }

  defp subject_str({:attr, key, field}), do: "#{key}/#{field}"
  defp subject_str({:merge, keys}), do: Enum.join(keys, "+")
  defp subject_str({:split, key}), do: key
  defp subject_str(other), do: inspect(other)

  defp decision_str({:pick, value}), do: "pick #{value}"
  defp decision_str(other), do: to_string(other)

  defp winner_str(nil), do: nil
  defp winner_str(w), do: to_string(w)

  defp codes_str(%MapSet{} = codes), do: codes |> MapSet.to_list() |> Enum.sort() |> Enum.map(&code_str/1)
  defp codes_str(codes) when is_list(codes), do: Enum.map(codes, &code_str/1)
  defp code_str({scheme, value}), do: "#{scheme}:#{value}"

  defp date_str(%Date{} = d), do: Date.to_iso8601(d)
end

DemoExport.run()
