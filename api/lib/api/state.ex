defmodule Api.State do
  @moduledoc """
  The materialized fold over the event log — everything reads need, maintained incrementally:
  the identity ledger, the CURRENT claim per slot (`Substrate.slot/1`), open conflict flags and
  resolved subjects, steward attribute/product overrides (mirroring `History.overrides_from/1`),
  and the legacy-ID assignments. Pure: `apply_event/2` is the only way state changes, so the
  snapshot is disposable by construction — re-folding the log MUST reproduce it (`Store.rebuild!`).
  """

  defstruct ledger: nil,
            current: %{},
            flags: [],
            resolved: MapSet.new(),
            overrides: %{attr: %{}, product: %{}},
            assigned: %{},
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

  def apply_event(%__MODULE__{} = s, %Events.ConflictResolved{subject: subject} = r) do
    s = %{s | resolved: MapSet.put(s.resolved, subject)}

    s =
      case {subject, r.decision} do
        {{:attr, k, f}, {:pick, _}} ->
          %{s | overrides: %{s.overrides | attr: Map.put(s.overrides.attr, {k, f}, r)}}

        {{:collision, k}, {:product, p}} ->
          %{s | overrides: %{s.overrides | product: Map.put(s.overrides.product, k, p)}}

        _ ->
          s
      end

    bump(s, r)
  end

  # mint / members-changed / merge / split — the ledger's own vocabulary
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

  defp bump(%__MODULE__{} = s, %{order: order}) when is_integer(order),
    do: %{s | offset: max(s.offset, order)}

  defp bump(s, _), do: s
end
