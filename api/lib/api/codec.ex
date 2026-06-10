defmodule Api.Codec do
  @moduledoc """
  Event (de)serialization for the store. Engine events are plain structs full of tuples, MapSets
  and Dates — `:erlang.term_to_binary/1` round-trips them EXACTLY, which JSON cannot without a
  lossy hand-written codec per event type. The trade-off (payloads opaque to SQL) is covered by
  the `type`/`recorded_at` columns for inspection and by `Api.Store.rebuild!/0`: the log can
  always be re-read and re-folded by the app that owns it. The design doc said JSONB; this is the
  deliberate refinement — exactness of the system of record beats queryability of its bytes.
  """

  def encode!(event), do: :erlang.term_to_binary(event)

  # Our own database is trusted input; structs decode only if their modules exist in this app.
  def decode!(binary), do: :erlang.binary_to_term(binary)

  @doc "Short type tag for the events table — e.g. \"ClaimAsserted\", \"IdentitiesMerged\"."
  def type(%mod{}), do: mod |> Module.split() |> List.last()
end
