defmodule Api.Steward do
  @moduledoc """
  The steward surface's logic: the open queue (merge proposals from the log + attribute ties
  detected fresh, minus everything already decided) and the four decisions, mapped 1:1 onto the
  engine's `Stewardship` functions — recorded with the steward's name, applied through the
  store's writer transaction. A decision against state that has moved on answers `409` with
  what's there now, instead of acting on stale ground.
  """

  @priority Priority.new(%{}, [])

  # ── the queue ───────────────────────────────────────────────────────────────
  def queue do
    state = Api.Store.state()
    claims = Api.State.current_claims(state)

    merges =
      for %Events.ConflictFlagged{subject: {:merge, keys}, candidates: cluster} <-
            Api.State.open_flags(state) do
        %{
          type: "merge",
          keys: keys,
          bridge: cluster |> Enum.sort() |> Enum.map(&Api.Views.code/1),
          members: Map.new(keys, fn k -> {k, member_codes(state, k)} end)
        }
      end

    attributes =
      for %Events.ConflictFlagged{subject: {:attr, key, field}, candidates: candidates} <-
            Stewardship.detect(state.ledger.members, claims, @priority, Date.utc_today()),
          not MapSet.member?(state.resolved, {:attr, key, field}) do
        %{
          type: "attribute",
          key: key,
          field: to_string(field),
          candidates: Enum.map(candidates, fn {s, v} -> %{source: to_string(s), value: v} end)
        }
      end

    %{merges: merges, attributes: attributes, open: length(merges) + length(attributes)}
  end

  # ── decisions ───────────────────────────────────────────────────────────────
  def decide(%{"kind" => "approve_merge", "keys" => keys, "by" => by} = _params)
      when is_list(keys) and length(keys) >= 2 and is_binary(by) and by != "" do
    Api.Store.append(fn state, _conn ->
      case keys -- Map.keys(state.ledger.members) do
        [] ->
          {:ok, Stewardship.approve_merge(state.ledger.members, keys, by, Date.utc_today()),
           applied("approve_merge")}

        gone ->
          stale(state, "keys no longer live: #{Enum.join(gone, ", ")}")
      end
    end)
    |> respond()
  end

  def decide(%{"kind" => "reject_merge", "keys" => keys, "by" => by})
      when is_list(keys) and length(keys) >= 2 and is_binary(by) and by != "" do
    Api.Store.append(fn state, _conn ->
      if Enum.any?(Api.State.open_flags(state), &(&1.subject == {:merge, Enum.sort(keys)})) do
        {:ok, Stewardship.reject_merge(keys, by, Date.utc_today()), applied("reject_merge")}
      else
        stale(state, "no open merge proposal for #{Enum.join(keys, "+")}")
      end
    end)
    |> respond()
  end

  def decide(%{
        "kind" => "resolve_attribute",
        "key" => key,
        "field" => field,
        "value" => value,
        "by" => by
      })
      when is_binary(key) and is_binary(field) and is_binary(by) and by != "" do
    Api.Store.append(fn state, _conn ->
      if Map.has_key?(state.ledger.members, key) do
        {:ok, Stewardship.resolve_attribute(key, field, value, by, Date.utc_today()),
         applied("resolve_attribute")}
      else
        stale(state, "key #{key} is not live")
      end
    end)
    |> respond()
  end

  def decide(%{"kind" => "split", "key" => key, "codes" => codes, "by" => by})
      when is_binary(key) and is_list(codes) and codes != [] and is_binary(by) and by != "" do
    with {:ok, parsed} <- parse_codes(codes) do
      Api.Store.append(fn state, _conn ->
        if Map.has_key?(state.ledger.members, key) do
          events = Stewardship.split(state.ledger, key, [parsed], by, Date.utc_today())
          ledger = Enum.reduce(events, state.ledger, &IdentityLedger.evolve(&2, &1))

          # the carved-out key needs a legacy id of its own — continuity, immediately
          assignments =
            LegacyIds.decide(
              ledger.members,
              Api.State.current_claims(state),
              state.assigned,
              Date.utc_today()
            )

          {:ok, events ++ assignments, applied("split")}
        else
          stale(state, "key #{key} is not live")
        end
      end)
      |> respond()
    else
      {:error, reason} -> {422, %{error: reason}}
    end
  end

  def decide(_params),
    do:
      {422,
       %{
         error:
           "decision must be one of: approve_merge/reject_merge (keys, by), " <>
             "resolve_attribute (key, field, value, by), split (key, codes, by)"
       }}

  # ── plumbing ────────────────────────────────────────────────────────────────
  defp applied(kind), do: %{applied: kind}

  defp stale(state, message),
    do:
      {:error,
       {409, %{error: message, live_keys: state.ledger.members |> Map.keys() |> Enum.sort()}}}

  defp respond({:ok, body}), do: {200, body}
  defp respond({:error, {status, body}}), do: {status, body}

  defp parse_codes(codes) do
    codes
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case Api.ClaimJson.parse_code(raw) do
        {:ok, code} -> {:cont, {:ok, [code | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp member_codes(state, key) do
    state.ledger.members
    |> Map.get(key, MapSet.new())
    |> Enum.sort()
    |> Enum.map(&Api.Views.code/1)
  end
end
