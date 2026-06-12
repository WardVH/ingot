# lib/contract/claims_validator.ex — the executable canonical-claims contract (bead gr-f6t).
#
# Hand-rolled, stdlib-only validation of a decoded claims batch (the value of the "claims" key
# in a POST /v1/claims submission) against docs/CLAIMS_CONTRACT.md. The contract/*.schema.json
# files are the spec artifacts; this module is the contract a customer's mapping script actually
# hits — so every finding is actionable: %{index, field, error}, zero-based index into the batch.
#
# Two severities, mirroring what the engine does at the boundary:
#
#   * errors   — the engine REJECTS these (whole batch, nothing partial enters the log):
#                wrong shapes, unknown kinds, missing/mistyped fields, malformed codes and dates.
#   * warnings — the engine ACCEPTS these but the mapping is probably wrong: unknown schemes
#                (pass through opaque + non-bridging), GTIN-family values that are not
#                GTIN-shaped or fail the mod-10 check digit (checksums are advisory — open
#                question 2 in the spec), media roles that silently become "secondary".

defmodule ClaimsValidator do
  @moduledoc """
  Contract-level validator for canonical claims JSON (`docs/CLAIMS_CONTRACT.md`).

  `validate/1` takes the decoded claims batch — a list of claim maps — and returns
  `{:ok, warnings}` or `{:error, errors}`, both lists of `%{index, field, error}` where `index`
  is the zero-based position of the offending claim (`nil` for batch-level failures), `field`
  the offending field (`nil` when the claim as a whole is malformed), and `error` a
  human-readable reason. Messages are NOT machine-stable — match on `index`/`field`.

  Structural rules reject (the engine refuses the batch); semantic advisories warn (the engine
  accepts, but the mapping likely has a bug): unknown schemes, GTIN canonicalization/checksum
  failures, non-enum media roles.
  """

  @kinds ~w(identity attribute media grouping)
  @gtin_family [:gtin, :ean, :upc]

  @doc """
  Validate a decoded claims batch (a list of claim maps).

  Returns `{:ok, warnings}` when every claim is structurally valid, or `{:error, errors}` when
  any claim rejects — one finding per offending field, shaped `%{index, field, error}`.
  """
  def validate(claims) when is_list(claims) do
    findings =
      claims
      |> Enum.with_index()
      |> Enum.flat_map(fn {claim, index} -> claim_findings(claim, index) end)

    case Enum.split_with(findings, &match?({:error, _}, &1)) do
      {[], warnings} -> {:ok, Enum.map(warnings, fn {:warning, w} -> w end)}
      {errors, _} -> {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end

  def validate(_),
    do: {:error, [%{index: nil, field: nil, error: "claims must be a list"}]}

  # ── one claim ───────────────────────────────────────────────────────────────
  defp claim_findings(%{"kind" => kind} = claim, index) when kind in @kinds do
    fields(kind, claim, index) ++ valid_from(claim, index)
  end

  defp claim_findings(%{"kind" => kind}, index),
    do: [error(index, "kind", "unknown kind #{inspect(kind)}")]

  defp claim_findings(_, index),
    do: [error(index, nil, "claim must be an object with a kind")]

  # ── per-kind required fields (spec: "Claim shape" + contract/claims.schema.json) ─
  defp fields("identity", claim, index) do
    non_empty_string(claim, "source", index) ++
      non_empty_string(claim, "ref", index) ++
      codes(claim, index)
  end

  defp fields("attribute", claim, index) do
    non_empty_string(claim, "source", index) ++
      code(claim, "code", index) ++
      non_empty_string(claim, "field", index) ++
      scalar(claim, "value", index)
  end

  defp fields("media", claim, index) do
    non_empty_string(claim, "source", index) ++
      non_empty_string(claim, "asset", index) ++
      code(claim, "target", index) ++
      non_empty_string(claim, "uri", index) ++
      role(claim, index)
  end

  defp fields("grouping", claim, index) do
    non_empty_string(claim, "source", index) ++
      code(claim, "code", index) ++
      integer(claim, "product", index)
  end

  # ── field rules ─────────────────────────────────────────────────────────────
  defp non_empty_string(claim, field, index) do
    case claim do
      %{^field => value} when is_binary(value) and value != "" ->
        []

      %{^field => value} ->
        [error(index, field, "#{field} must be a non-empty string, got #{inspect(value)}")]

      _ ->
        [error(index, field, "#{field} is required")]
    end
  end

  defp scalar(claim, field, index) do
    case claim do
      %{^field => v} when is_binary(v) or is_number(v) or is_boolean(v) ->
        []

      %{^field => v} ->
        [error(index, field, "#{field} must be a string, number, or boolean, got #{inspect(v)}")]

      _ ->
        [error(index, field, "#{field} is required")]
    end
  end

  defp integer(claim, field, index) do
    case claim do
      %{^field => v} when is_integer(v) -> []
      %{^field => v} -> [error(index, field, "#{field} must be an integer, got #{inspect(v)}")]
      _ -> [error(index, field, "#{field} is required")]
    end
  end

  defp codes(claim, index) do
    case claim do
      %{"codes" => [_ | _] = list} ->
        Enum.flat_map(list, &code_findings(&1, "codes", index))

      %{"codes" => value} ->
        [
          error(
            index,
            "codes",
            ~s(codes must be a non-empty array of "scheme:value" strings, got #{inspect(value)})
          )
        ]

      _ ->
        [error(index, "codes", "codes is required")]
    end
  end

  defp code(claim, field, index) do
    case claim do
      %{^field => raw} -> code_findings(raw, field, index)
      _ -> [error(index, field, "#{field} is required")]
    end
  end

  # A code is one "scheme:value" string, split on the FIRST colon, both halves non-empty.
  defp code_findings(raw, field, index) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [scheme, value] when scheme != "" and value != "" ->
        scheme_advisories(scheme, value, raw, field, index)

      _ ->
        [error(index, field, ~s(code must be "scheme:value", got #{inspect(raw)}))]
    end
  end

  defp code_findings(raw, field, index),
    do: [error(index, field, ~s(code must be a "scheme:value" string, got #{inspect(raw)}))]

  # ── semantic advisories — the engine accepts all of these (warnings, never errors) ─
  defp scheme_advisories(scheme, value, raw, field, index) do
    case CodeRegistry.engine_scheme(scheme) do
      engine when is_atom(engine) and engine in @gtin_family ->
        gtin_advisories(engine, value, raw, field, index)

      engine when is_atom(engine) ->
        []

      _unknown ->
        [
          warning(
            index,
            field,
            "unknown scheme #{inspect(scheme)} in #{inspect(raw)} — accepted, but passes through as an opaque, non-bridging code"
          )
        ]
    end
  end

  defp gtin_advisories(engine, value, raw, field, index) do
    case Codes.canonicalize({engine, value}) do
      {:gtin, gtin14} = canonical when byte_size(gtin14) == 14 ->
        if Codes.valid_gtin?(canonical) do
          []
        else
          [
            warning(
              index,
              field,
              "#{inspect(raw)} fails the GTIN mod-10 check digit — accepted, but the code is likely mistyped"
            )
          ]
        end

      _not_gtin_shaped ->
        [
          warning(
            index,
            field,
            "#{inspect(raw)} is not GTIN-shaped (8/12/13/14 digits) — accepted untouched, but will never bridge as a GTIN"
          )
        ]
    end
  end

  # role is forgiving in the engine: anything other than "primary" silently means secondary
  # (open question 5) — so a non-enum role is a warning, not an error.
  defp role(claim, index) do
    case claim do
      %{"role" => role} when role in ["primary", "secondary"] ->
        []

      %{"role" => role} ->
        [
          warning(
            index,
            "role",
            ~s(role #{inspect(role)} is not "primary" or "secondary" — the engine treats it as secondary)
          )
        ]

      _ ->
        []
    end
  end

  # valid_from is optional on every kind; when present it must be an ISO 8601 DATE (no time).
  defp valid_from(claim, index) do
    case claim do
      %{"valid_from" => raw} when is_binary(raw) ->
        case Date.from_iso8601(raw) do
          {:ok, _date} -> []
          {:error, _} -> [error(index, "valid_from", "valid_from must be an ISO date, got #{inspect(raw)}")]
        end

      %{"valid_from" => raw} ->
        [error(index, "valid_from", "valid_from must be an ISO date, got #{inspect(raw)}")]

      _ ->
        []
    end
  end

  defp error(index, field, message), do: {:error, %{index: index, field: field, error: message}}
  defp warning(index, field, message), do: {:warning, %{index: index, field: field, error: message}}
end
