# lib/ingest/envelope_loader.ex — load + validate HistoryEnvelope JSON into internal structs.
#
# This is the first stage of the legacy-medipim ingest (bead gr-n8i). It parses the
# decoded-but-unresolved HistoryEnvelope (contract C — see docs/HISTORY_ENVELOPE.md) into
# %HistoryEnvelope{} / %HistoryEnvelope.Event{} structs and validates the envelope is
# well-formed: a supported schema_version, and every event a known op + kind with its required
# payload keys.
#
# It does NO resolution: no folding into code-sets, no canonicalization, no survivorship, no
# clustering. Events stay flat and time-ordered exactly as the envelope presents them; each gets
# a stable `order` index so later stages can sort deterministically when recorded_at ties.
# Folding/claims begin in the next stage (gr-beo).

defmodule HistoryEnvelope do
  @moduledoc """
  One decoded legacy entity's history. The ingest accepts a *list* of these and clusters across
  them; this module just turns JSON into validated structs.
  """

  @supported_schema_versions ~w(1)
  @ops %{"set" => :set, "add" => :add, "remove" => :remove, "delete" => :delete}
  @kinds %{
    "identity" => :identity,
    "attribute" => :attribute,
    "edge" => :edge,
    "media" => :media
  }

  defmodule Event do
    @moduledoc """
    One granular, unresolved event. `op` ∈ #{inspect([:set, :add, :remove, :delete])},
    `kind` ∈ #{inspect([:identity, :attribute, :edge, :media])}. Kind-specific payload lives in
    `data`:

      * identity  → `%{scheme: String.t(), code: String.t() | nil}`  (no `code` on a delete)
      * attribute → `%{field: String.t(), locale: String.t() | nil, value: term}`
      * edge      → `%{collection: String.t(), value: term}`
      * media     → `%{collection: String.t(), asset: term}`
    """
    defstruct [:recorded_at, :valid_from, :by, :tag, :source, :op, :kind, :data, :order]
  end

  defstruct [
    :schema_version,
    :source_system,
    :legacy_entity,
    :last_touched_at,
    :dropped_meta_count,
    :events
  ]

  @doc "Load and validate one envelope file. `{:ok, %HistoryEnvelope{}} | {:error, reason}`."
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, raw} ->
        case decode_json(raw) do
          {:ok, map} -> from_map(map)
          {:error, reason} -> {:error, reason}
        end

      {:error, posix} ->
        {:error, {:file, path, posix}}
    end
  end

  @doc "Load and validate many envelope files. Fails on the first bad file."
  def load_all(paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case load(path) do
        {:ok, env} -> {:cont, {:ok, [env | acc]}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, envs} -> {:ok, Enum.reverse(envs)}
      err -> err
    end
  end

  @doc "Like `load/1` but raises on error."
  def load!(path) do
    case load(path) do
      {:ok, env} -> env
      {:error, reason} -> raise ArgumentError, "invalid envelope #{path}: #{inspect(reason)}"
    end
  end

  @doc "Parse a JSON string into a validated envelope."
  def from_json(json) when is_binary(json) do
    with {:ok, map} <- decode_json(json), do: from_map(map)
  end

  @doc "Validate a decoded (string-keyed) map and build the envelope."
  def from_map(%{} = m) do
    with {:ok, version} <- validate_schema_version(m["schema_version"]),
         {:ok, events} <- build_events(m["events"]) do
      {:ok,
       %__MODULE__{
         schema_version: version,
         source_system: m["source_system"],
         legacy_entity: m["legacy_entity"],
         last_touched_at: m["last_touched_at"],
         dropped_meta_count: m["dropped_meta_count"],
         events: events
       }}
    end
  end

  def from_map(_), do: {:error, :not_an_object}

  @doc "Count events by kind — a quick sanity helper."
  def kind_counts(%__MODULE__{events: events}) do
    Enum.reduce(events, %{}, fn %Event{kind: k}, acc -> Map.update(acc, k, 1, &(&1 + 1)) end)
  end

  # ── validation ──────────────────────────────────────────────────────────────

  defp validate_schema_version(v) when v in @supported_schema_versions, do: {:ok, v}
  defp validate_schema_version(v), do: {:error, {:unsupported_schema_version, v}}

  defp build_events(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, i}, {:ok, acc} ->
      case build_event(raw, i) do
        {:ok, ev} -> {:cont, {:ok, [ev | acc]}}
        {:error, reason} -> {:halt, {:error, {:event, i, reason}}}
      end
    end)
    |> case do
      {:ok, evs} -> {:ok, Enum.reverse(evs)}
      err -> err
    end
  end

  defp build_events(nil), do: {:error, :missing_events}
  defp build_events(_), do: {:error, :events_not_a_list}

  defp build_event(%{} = m, order) do
    with {:ok, op} <- atom_for(@ops, m["op"], :unknown_op),
         {:ok, kind} <- atom_for(@kinds, m["kind"], :unknown_kind),
         {:ok, data} <- payload(kind, op, m) do
      {:ok,
       %Event{
         recorded_at: m["recorded_at"],
         valid_from: m["valid_from"] || m["recorded_at"],
         by: m["by"],
         tag: m["tag"],
         source: m["source"],
         op: op,
         kind: kind,
         data: data,
         order: order
       }}
    end
  end

  defp build_event(_, _), do: {:error, :event_not_an_object}

  defp atom_for(table, key, err) do
    case Map.fetch(table, key) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {err, key}}
    end
  end

  # identity/edge/media carry a required key; a missing one is a malformed envelope.
  defp payload(:identity, _op, m) do
    require_keys(m, ["scheme"], fn -> %{scheme: m["scheme"], code: m["code"]} end)
  end

  defp payload(:attribute, _op, m) do
    require_keys(m, ["field"], fn ->
      %{field: m["field"], locale: m["locale"], value: m["value"]}
    end)
  end

  defp payload(:edge, _op, m) do
    require_keys(m, ["collection"], fn -> %{collection: m["collection"], value: m["value"]} end)
  end

  defp payload(:media, _op, m) do
    require_keys(m, ["collection", "asset"], fn ->
      %{collection: m["collection"], asset: m["asset"]}
    end)
  end

  defp require_keys(m, keys, build) do
    case Enum.reject(keys, &Map.has_key?(m, &1)) do
      [] -> {:ok, build.()}
      missing -> {:error, {:missing_keys, missing}}
    end
  end

  defp decode_json(raw) do
    case JSON.decode(raw) do
      {:ok, term} -> {:ok, term}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end
end
