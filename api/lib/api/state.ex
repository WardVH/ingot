defmodule Api.State do
  @moduledoc """
  The materialized fold over the event log — everything reads need, maintained incrementally:
  the identity ledger, the CURRENT claim per slot (`Substrate.slot/1`), open conflict flags and
  resolved subjects, steward attribute/product overrides (mirroring `History.overrides_from/1`),
  pending merge endorsements (the first of the four eyes, keyed by sorted keys), and the
  legacy-ID assignments. Pure: `apply_event/2` is the only way state changes, so the
  snapshot is disposable by construction — re-folding the log MUST reproduce it (`Store.rebuild!`).
  """

  defstruct ledger: nil,
            current: %{},
            flags: [],
            resolved: MapSet.new(),
            overrides: %{attr: %{}, product: %{}},
            assigned: %{},
            shared: MapSet.new(),
            redirects: %{},
            proposals: %{},
            offset: 0

  def new, do: %__MODULE__{ledger: IdentityLedger.new()}

  def apply_event(%__MODULE__{} = s, %Events.ClaimAsserted{} = c),
    do: bump(%{s | current: Map.put(s.current, Substrate.slot(c), c)}, c)

  def apply_event(%__MODULE__{} = s, %Events.LegacyIdAssigned{key: k, legacy_id: id} = e),
    do: bump(%{s | assigned: Map.put(s.assigned, k, id)}, e)

  def apply_event(%__MODULE__{} = s, %Events.ConflictFlagged{subject: subject} = f) do
    if Enum.any?(s.flags, &(&1.subject == subject)),
      do: bump(s, f),
      else: bump(%{s | flags: s.flags ++ [f]}, f)
  end

  # the first of the four eyes: remember WHO endorsed the merge (and why) until it resolves
  def apply_event(%__MODULE__{} = s, %Events.MergeProposed{keys: keys} = p),
    do: bump(%{s | proposals: Map.put(s.proposals, Enum.sort(keys), p)}, p)

  def apply_event(%__MODULE__{} = s, %Events.ConflictResolved{subject: subject} = r) do
    s = %{s | resolved: MapSet.put(s.resolved, subject)}

    # a settled merge (approved or rejected) clears its pending endorsement
    s =
      case subject do
        {:merge, keys} -> %{s | proposals: Map.delete(s.proposals, Enum.sort(keys))}
        _ -> s
      end

    s =
      case {subject, r.decision} do
        {{:attr, k, f}, {:pick, _}} ->
          %{s | overrides: %{s.overrides | attr: Map.put(s.overrides.attr, {k, f}, r)}}

        {{:collision, k}, {:product, p}} ->
          %{s | overrides: %{s.overrides | product: Map.put(s.overrides.product, k, p)}}

        {{:code, code}, :shared} ->
          %{s | shared: MapSet.put(s.shared, code)}

        _ ->
          s
      end

    bump(s, r)
  end

  # a merge leaves a redirect for every absorbed key, so a legacy id assigned to one keeps
  # resolving — to the survivor — without ever scanning the log
  def apply_event(%__MODULE__{} = s, %Events.IdentitiesMerged{from: from, into: into} = e) do
    redirects = Enum.reduce(from -- [into], s.redirects, &Map.put(&2, &1, into))
    bump(%{s | ledger: IdentityLedger.evolve(s.ledger, e), redirects: redirects}, e)
  end

  # mint / members-changed / split — the ledger's own vocabulary
  def apply_event(%__MODULE__{} = s, identity_event),
    do: bump(%{s | ledger: IdentityLedger.evolve(s.ledger, identity_event)}, identity_event)

  def apply_all(%__MODULE__{} = s, events), do: Enum.reduce(events, s, &apply_event(&2, &1))

  @doc "The current claims, ordered — what `Catalog.project` and `Cluster.variants` fold over."
  def current_claims(%__MODULE__{current: current}),
    do: current |> Map.values() |> Enum.sort_by(& &1.order)

  @doc "Project the golden catalog from this state (no log scan)."
  def golden(%__MODULE__{} = s, priority),
    do: Catalog.project(s.ledger.members, current_claims(s), priority, s.overrides)

  @doc "Open conflicts: flagged subjects without a steward decision, in flag order."
  def open_flags(%__MODULE__{} = s),
    do: Enum.reject(s.flags, &MapSet.member?(s.resolved, &1.subject))

  @doc "Follow merge redirects to the key that answers TODAY."
  def follow(%__MODULE__{redirects: redirects} = s, key) do
    case Map.get(redirects, key) do
      nil -> key
      next -> follow(s, next)
    end
  end

  defp bump(%__MODULE__{} = s, %{order: order}) when is_integer(order),
    do: %{s | offset: max(s.offset, order)}

  defp bump(s, _), do: s
end
