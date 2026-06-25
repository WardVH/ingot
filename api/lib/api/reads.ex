defmodule Api.Reads do
  @moduledoc """
  The Product API reads. Current reads are snapshot lookups (single-key projection — never a full
  catalog fold, never a log scan); `as_of` is the one deliberate exception: it folds the log
  bounded by date, because time travel is rare and correctness beats caching there.

  A legacy id keeps answering across merges (followed to the survivor, with `merged_from` saying
  where it came from) — the backwards-compatibility contract.
  """

  @doc "The product a legacy medipim id answers to today. `{:ok, view} | :not_found`."
  def product(legacy_id) when is_integer(legacy_id) do
    state = Api.Store.state()

    case key_for(state, legacy_id) do
      nil ->
        :not_found

      original ->
        key = Api.State.follow(state, original)
        view = project_one(state, key)

        {:ok,
         view
         |> Map.put(:legacy_id, legacy_id)
         |> Map.put(:merged_from, if(key != original, do: original))}
    end
  end

  @doc "The product as it was KNOWN on `date` — folds the log, bounded by date."
  def product_as_of(legacy_id, %Date{} = date) when is_integer(legacy_id) do
    log = Api.Store.log()
    historical = state_as_of(log, date)

    with original when original != nil <- key_for(historical, legacy_id) do
      key = Api.State.follow(historical, original)

      case project_one(historical, key) do
        %{codes: []} -> {:not_found_as_of, key}
        view -> {:ok, view |> Map.put(:legacy_id, legacy_id) |> Map.put(:as_of, date)}
      end
    else
      nil ->
        case key_for(Api.Store.state(), legacy_id) do
          nil -> :not_found
          future_key -> {:not_found_as_of, future_key}
        end
    end
  end

  @doc "Every product carrying this code (a legitimately shared code can match several)."
  def by_code(scheme, value) do
    state = Api.Store.state()
    code = Codes.canonicalize({CodeRegistry.engine_scheme(scheme), value})

    matches =
      for {key, codes} <- state.ledger.members,
          Lanes.lane_of_key(key) == :product,
          MapSet.member?(codes, code) do
        state |> project_one(key) |> Map.put(:legacy_id, legacy_of(state, key))
      end

    case matches do
      [] -> :not_found
      views -> {:ok, %{code: Api.Views.code(code), products: Enum.sort_by(views, & &1.key)}}
    end
  end

  @doc "Decoded events after `offset`, as feed views — medipim's polling substrate."
  def changes(offset, limit) when is_integer(offset) do
    events = Api.Store.events_since(offset, limit)

    %{
      events: Enum.map(events, &Api.Views.feed_event/1),
      next: events |> Enum.map(& &1.order) |> Enum.max(fn -> offset end),
      count: length(events)
    }
  end

  # ── internals ───────────────────────────────────────────────────────────────
  defp key_for(state, legacy_id) do
    Enum.find_value(state.assigned, fn {key, id} -> if id == legacy_id, do: key end)
  end

  defp legacy_of(state, key), do: Map.get(state.assigned, key)

  defp state_as_of(log, date) do
    events = Enum.filter(log, &(Date.compare(&1.recorded_at, date) != :gt))
    Api.State.apply_all(Api.State.new(), events)
  end

  # Project ONE key: Catalog.project over a single-entry members map — snapshot-cheap.
  defp project_one(state, key) do
    members =
      state.ledger.members
      |> Enum.filter(fn {member_key, _codes} ->
        member_key == key or Lanes.lane_of_key(member_key) != :product
      end)
      |> Map.new()

    case Catalog.project(
           members,
           Api.State.current_claims(state),
           Api.Priority.current(),
           state.overrides
         ) do
      [] ->
        %{key: key, codes: [], attributes: [], media: [], status: status_of(state, key)}

      groups ->
        variant = groups |> Enum.flat_map(& &1.variants) |> Enum.find(&(&1.key == key))
        variant |> Api.Views.variant() |> Map.put(:status, status_of(state, key))
    end
  end

  defp status_of(state, key) do
    cond do
      Map.has_key?(state.ledger.members, key) -> "active"
      Map.has_key?(state.redirects, key) -> "merged"
      true -> "unknown"
    end
  end
end
