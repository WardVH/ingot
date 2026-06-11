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
      for %Events.ConflictFlagged{subject: {:merge, keys}} <- Api.State.open_flags(state) do
        members = Map.new(keys, fn k -> {k, Map.get(state.ledger.members, k, MapSet.new())} end)

        # Codes DIRECTLY shared by two keys' memberships are rare — most bridges are a single
        # LISTING whose codes span the keys. Show those claims, each code tagged with the key it
        # belongs to, so the steward sees exactly WHO connected WHAT (and can judge the claim).
        shared =
          members
          |> Map.values()
          |> Enum.flat_map(&MapSet.to_list/1)
          |> Enum.frequencies()
          |> Enum.filter(fn {_c, n} -> n > 1 end)
          |> Enum.map(fn {c, _} -> Api.Views.code(c) end)
          |> Enum.sort()

        bridges =
          for c <- claims,
              c.kind == :identity,
              codes = MapSet.new(c.data.codes),
              Enum.count(members, fn {_k, m} -> not MapSet.disjoint?(codes, m) end) >= 2 do
            %{
              source: to_string(c.source),
              ref: c.data.ref,
              date: Date.to_iso8601(c.recorded_at),
              codes:
                for code <- Enum.sort(c.data.codes) do
                  owner =
                    Enum.find_value(members, fn {k, m} -> if MapSet.member?(m, code), do: k end)

                  %{code: Api.Views.code(code), owner: owner}
                end
            }
          end

        bridge_sources = bridges |> Enum.map(& &1.source) |> Enum.uniq()

        %{
          type: "merge",
          keys: keys,
          members: Map.new(members, fn {k, _} -> {k, selectable_codes(state, claims, k)} end),
          bridges: bridges,
          bridge_sources: bridge_sources,
          shared: shared
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

    repairs =
      state.redirects
      |> Map.keys()
      |> Enum.group_by(&Api.State.follow(state, &1))
      |> Enum.filter(fn {survivor, _} -> Map.has_key?(state.ledger.members, survivor) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {survivor, absorbed} ->
        %{
          key: survivor,
          merged_from: Enum.sort(absorbed),
          codes: selectable_codes(state, claims, survivor)
        }
      end)

    %{
      merges: merges,
      attributes: attributes,
      repairs: repairs,
      open: length(merges) + length(attributes)
    }
  end

  @doc """
  `queue/0` plus the `manual` per-key code selectors the HTML page renders (every live key) —
  kept off the JSON queue so the API payload stays proportional to open conflicts, not catalog size.
  """
  def page_data do
    state = Api.Store.state()
    claims = Api.State.current_claims(state)

    manual =
      state.ledger.members
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn key -> %{key: key, codes: selectable_codes(state, claims, key)} end)

    Map.put(queue(), :manual, manual)
  end

  # A key's member codes as SELECTABLE entries — each with the sources currently claiming it,
  # so the steward can spot the stranger ("which claim is wrong") instead of typing codes.
  defp selectable_codes(state, claims, key) do
    sources =
      for c <- claims, c.kind == :identity, code <- c.data.codes, reduce: %{} do
        acc ->
          Map.update(acc, code, [to_string(c.source)], &Enum.uniq([to_string(c.source) | &1]))
      end

    state.ledger.members
    |> Map.get(key, MapSet.new())
    |> Enum.sort()
    |> Enum.map(fn code ->
      %{code: Api.Views.code(code), sources: sources |> Map.get(code, []) |> Enum.sort()}
    end)
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
        member = Map.get(state.ledger.members, key)

        cond do
          member == nil ->
            stale(state, "key #{key} is not live")

          MapSet.subset?(member, MapSet.new(parsed)) ->
            {:error,
             {422,
              %{error: "selecting every code would leave #{key} empty — reject the merge instead"}}}

          true ->
            split_events(state, key, parsed, by)
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
  defp split_events(state, key, parsed, by) do
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
  end

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
      case CanonicalClaims.parse_code(raw) do
        {:ok, code} -> {:cont, {:ok, [code | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
