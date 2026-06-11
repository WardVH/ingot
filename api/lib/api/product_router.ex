defmodule Api.ProductRouter do
  @moduledoc """
  The Product API — medipim's machine-to-machine surface (`PRODUCT_API_TOKEN`).

  Writes: `POST /backfill/envelopes` (contract-C, idempotent, finer-grained fold) and
  `POST /claims` (live engine-native claims). `POST /dry-run` takes the same body as `/claims`
  through the same pipeline uncommitted and answers with the migration report (gr-rlq).
  `POST /cutover` commits a migration batch with convergent re-run semantics and answers with
  the committed report (gr-w4l, `Api.Cutover`).
  """
  use Plug.Router

  plug Api.Auth, :product
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: JSON, length: 200_000_000
  plug :dispatch

  post "/backfill/envelopes" do
    case conn.body_params do
      %{"envelopes" => envelopes} ->
        write(conn, Api.Writes.backfill(envelopes))

      _ ->
        json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"envelopes": [...]})}]})
    end
  end

  post "/claims" do
    case conn.body_params do
      %{"claims" => claims} -> write(conn, Api.Writes.claims(claims))
      _ -> json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"claims": [...]})}]})
    end
  end

  # The same body as /claims, COMMITTED with migration semantics (per-slot compaction,
  # convergent re-runs) — the committed report is the response; a rejected batch is 422.
  post "/cutover" do
    case conn.body_params do
      %{"claims" => claims} -> write(conn, Api.Cutover.commit(claims))
      _ -> json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"claims": [...]})}]})
    end
  end

  # The same body as /claims, run through the same pipeline, committing NOTHING — the report is
  # the response (validation errors included), so the status is 200 either way.
  post "/dry-run" do
    case conn.body_params do
      %{"claims" => claims} -> json(conn, 200, Api.DryRun.report(claims))
      _ -> json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"claims": [...]})}]})
    end
  end

  get "/products/by-code/:scheme/:value" do
    case Api.Reads.by_code(scheme, value) do
      {:ok, body} -> json(conn, 200, body)
      :not_found -> json(conn, 404, %{error: "no product carries #{scheme}:#{value}"})
    end
  end

  get "/products/:legacy_id" do
    conn = fetch_query_params(conn)

    with {id, ""} <- Integer.parse(legacy_id) do
      case conn.query_params["as_of"] do
        nil ->
          case Api.Reads.product(id) do
            {:ok, view} -> json(conn, 200, view)
            :not_found -> json(conn, 404, %{error: "unknown legacy id #{id}"})
          end

        raw ->
          case Date.from_iso8601(raw) do
            {:ok, date} ->
              case Api.Reads.product_as_of(id, date) do
                {:ok, view} ->
                  json(conn, 200, view)

                {:not_found_as_of, key} ->
                  json(conn, 404, %{error: "not resolvable as of #{raw}", key: key, as_of: raw})

                :not_found ->
                  json(conn, 404, %{error: "unknown legacy id #{id}"})
              end

            _ ->
              json(conn, 422, %{error: "as_of must be an ISO date, got #{inspect(raw)}"})
          end
      end
    else
      _ -> json(conn, 404, %{error: "legacy id must be an integer, got #{inspect(legacy_id)}"})
    end
  end

  get "/changes" do
    conn = fetch_query_params(conn)
    since = Integer.parse(conn.query_params["since"] || "0")
    limit = Integer.parse(conn.query_params["limit"] || "500")

    case {since, limit} do
      {{s, ""}, {l, ""}} when s >= 0 and l > 0 ->
        json(conn, 200, Api.Reads.changes(s, min(l, 1_000)))

      _ ->
        json(conn, 422, %{error: "since and limit must be non-negative integers"})
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  defp write(conn, {:ok, summary}), do: json(conn, 200, summary)
  defp write(conn, {:error, {status, body}}), do: json(conn, status, body)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
