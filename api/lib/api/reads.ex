defmodule Api.Reads do
  @moduledoc """
  The Product API reads. Current reads are snapshot lookups (single-key projection — never a full
  catalog fold, never a log scan); `as_of` is the one deliberate exception: it folds the log
  bounded by date, because time travel is rare and correctness beats caching there.

  A legacy id keeps answering across merges (followed to the survivor, with `merged_from` saying
  where it came from) — the backwards-compatibility contract.
  """

  @priority Priority.new(%{}, [])

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
    state = Api.Store.state()

    with original when original != nil <- key_for(state, legacy_id) do
      key = Api.State.follow(state, original)
      golden = History.project_as_of(Api.Store.log(), date, @priority)

      golden
      |> Enum.flat_map(& &1.variants)
      |> Enum.find(&(&1.key == key))
      |> case do
        # not resolvable yet on that date — honest 404 with the date attached
        nil ->
          {:not_found_as_of, key}

        variant ->
          {:ok,
           Api.Views.variant(variant) |> Map.put(:legacy_id, legacy_id) |> Map.put(:as_of, date)}
      end
    else
      nil -> :not_found
    end
  end

  @doc "Every product carrying this code (a legitimately shared code can match several)."
  def by_code(scheme, value) do
    state = Api.Store.state()
    code = Codes.canonicalize({CodeRegistry.engine_scheme(scheme), value})

    matches =
      for {key, codes} <- state.ledger.members, MapSet.member?(codes, code) do
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

  # Project ONE key: Catalog.project over a single-entry members map — snapshot-cheap.
  defp project_one(state, key) do
    members = Map.take(state.ledger.members, [key])

    case Catalog.project(members, Api.State.current_claims(state), @priority, state.overrides) do
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
