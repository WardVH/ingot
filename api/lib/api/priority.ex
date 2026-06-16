defmodule Api.Priority do
  @moduledoc """
  The empty survivorship priority the steward surfaces share (gr-dfp): `Priority.new(%{}, [])` —
  no source ranking, so attribute ties surface as conflicts for a steward rather than being
  auto-decided. Defined once here; `Api.DryRun` and `Api.Steward` both reference it.
  """

  def empty, do: Priority.new(%{}, [])
end
