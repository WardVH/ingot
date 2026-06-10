defmodule Api.ClaimJson do
  @moduledoc """
  The live-claims contract (`POST /v1/claims`): engine-native claims as JSON. Codes are
  `"scheme:value"` strings in the engine's own scheme vocabulary (`CodeRegistry.engine_scheme/1`;
  unknown schemes pass through as strings — conservative, never an atom leak). A batch validates
  WHOLE: any invalid claim rejects everything with per-index reasons — nothing partial enters the
  log. `recorded_at` is server-side today; an optional `valid_from` (ISO date) is the bitemporal
  hook medipim can use when it knows a change applied earlier than it was reported.
  """

  def parse(claims, today) when is_list(claims) do
    claims
    |> Enum.with_index()
    |> Enum.map(fn {map, index} ->
      case one(map, today) do
        {:ok, claim} -> {:ok, claim}
        {:error, reason} -> {:error, %{index: index, error: reason}}
      end
    end)
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> case do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, c} -> c end)}
      {_, errors} -> {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end

  def parse(_, _today), do: {:error, [%{index: nil, error: "claims must be a list"}]}

  # ── one claim ───────────────────────────────────────────────────────────────
  defp one(%{"kind" => "identity", "source" => s, "ref" => ref, "codes" => codes} = m, today)
       when is_binary(s) and is_binary(ref) and is_list(codes) and codes != [] do
    with {:ok, parsed} <- parse_codes(codes),
         {:ok, valid_from} <- valid_from(m, today) do
      {:ok, Substrate.claim(s, :identity, %{ref: ref, codes: parsed}, valid_from, today)}
    end
  end

  defp one(
         %{"kind" => "attribute", "source" => s, "code" => code, "field" => f, "value" => v} = m,
         today
       )
       when is_binary(s) and is_binary(f) and (is_binary(v) or is_number(v) or is_boolean(v)) do
    with {:ok, parsed} <- parse_code(code),
         {:ok, valid_from} <- valid_from(m, today) do
      {:ok,
       Substrate.claim(s, :attribute, %{code: parsed, field: f, value: v}, valid_from, today)}
    end
  end

  defp one(
         %{"kind" => "media", "source" => s, "asset" => a, "target" => t, "uri" => uri} = m,
         today
       )
       when is_binary(s) and is_binary(a) and is_binary(uri) do
    with {:ok, target} <- parse_code(t),
         {:ok, valid_from} <- valid_from(m, today) do
      role = if m["role"] == "primary", do: :primary, else: :secondary
      data = %{asset: {:dam, a}, target: target, role: role, uri: uri}
      {:ok, Substrate.claim(s, :media, data, valid_from, today)}
    end
  end

  defp one(%{"kind" => "grouping", "source" => s, "code" => code, "product" => p} = m, today)
       when is_binary(s) and is_integer(p) do
    with {:ok, parsed} <- parse_code(code),
         {:ok, valid_from} <- valid_from(m, today) do
      {:ok, Substrate.claim(s, :grouping, %{code: parsed, product: p}, valid_from, today)}
    end
  end

  defp one(%{"kind" => kind}, _today) when kind in ["identity", "attribute", "media", "grouping"],
    do: {:error, "missing or mistyped fields for kind #{kind}"}

  defp one(%{"kind" => kind}, _today), do: {:error, "unknown kind #{inspect(kind)}"}
  defp one(_, _today), do: {:error, "claim must be an object with a kind"}

  # ── pieces ──────────────────────────────────────────────────────────────────
  defp parse_codes(codes) do
    codes
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse_code(raw) do
        {:ok, code} -> {:cont, {:ok, [code | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
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

  defp valid_from(%{"valid_from" => raw}, _today) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "valid_from must be an ISO date, got #{inspect(raw)}"}
    end
  end

  defp valid_from(%{"valid_from" => raw}, _today),
    do: {:error, "valid_from must be an ISO date, got #{inspect(raw)}"}

  defp valid_from(_, today), do: {:ok, today}
end
