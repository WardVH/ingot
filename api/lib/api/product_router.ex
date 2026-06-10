defmodule Api.ProductRouter do
  @moduledoc """
  The Product API — medipim's machine-to-machine surface (`PRODUCT_API_TOKEN`).

  Writes: `POST /backfill/envelopes` (contract-C, idempotent, finer-grained fold) and
  `POST /claims` (live engine-native claims). Reads land with their bead.
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
