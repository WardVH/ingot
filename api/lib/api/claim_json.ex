defmodule Api.ClaimJson do
  @moduledoc """
  The live-claims contract (`POST /v1/claims`): engine-native claims as JSON. Structural
  validation is DELEGATED to `ClaimsValidator` — the executable contract in the engine root
  (spec: `docs/CLAIMS_CONTRACT.md`) — so the api layer only builds `Substrate` claims from
  batches the contract already accepted. Codes are `"scheme:value"` strings in the engine's own
  scheme vocabulary (`CodeRegistry.engine_scheme/1`; unknown schemes pass through as strings —
  conservative, never an atom leak). A batch validates WHOLE: any invalid claim rejects
  everything with per-index reasons — nothing partial enters the log. `recorded_at` is
  server-side today; an optional `valid_from` (ISO date) is the bitemporal hook medipim can use
  when it knows a change applied earlier than it was reported.
  """

  def parse(claims, today) do
    case ClaimsValidator.validate(claims) do
      {:ok, _warnings} ->
        {:ok, Enum.map(claims, &build(&1, today))}

      {:error, errors} ->
        {:error,
         Enum.map(errors, fn %{index: index, error: error} -> %{index: index, error: error} end)}
    end
  end

  # ── build one VALIDATED claim (ClaimsValidator already accepted the batch) ──
  defp build(%{"kind" => "identity", "source" => s, "ref" => ref, "codes" => codes} = m, today) do
    data = %{ref: ref, codes: Enum.map(codes, &code!/1)}
    Substrate.claim(s, :identity, data, valid_from(m, today), today)
  end

  defp build(
         %{"kind" => "attribute", "source" => s, "code" => c, "field" => f, "value" => v} = m,
         today
       ) do
    Substrate.claim(
      s,
      :attribute,
      %{code: code!(c), field: f, value: v},
      valid_from(m, today),
      today
    )
  end

  defp build(
         %{"kind" => "media", "source" => s, "asset" => a, "target" => t, "uri" => uri} = m,
         today
       ) do
    role = if m["role"] == "primary", do: :primary, else: :secondary
    data = %{asset: {:dam, a}, target: code!(t), role: role, uri: uri}
    Substrate.claim(s, :media, data, valid_from(m, today), today)
  end

  defp build(%{"kind" => "grouping", "source" => s, "code" => c, "product" => p} = m, today) do
    Substrate.claim(s, :grouping, %{code: code!(c), product: p}, valid_from(m, today), today)
  end

  # ── pieces ──────────────────────────────────────────────────────────────────
  defp code!(raw) do
    {:ok, code} = parse_code(raw)
    code
  end

  @doc ~s(Parse one "scheme:value" code string — also used by the steward split decision.)
  def parse_code(raw) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [scheme, value] when scheme != "" and value != "" ->
        {:ok, {CodeRegistry.engine_scheme(scheme), value}}

      _ ->
        {:error, ~s(code must be "scheme:value", got #{inspect(raw)})}
    end
  end

  def parse_code(raw),
    do: {:error, ~s(code must be a "scheme:value" string, got #{inspect(raw)})}

  defp valid_from(%{"valid_from" => raw}, _today), do: Date.from_iso8601!(raw)
  defp valid_from(_, today), do: today
end
