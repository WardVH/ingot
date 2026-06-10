defmodule Api.ProductRouter do
  @moduledoc """
  The Product API — medipim's machine-to-machine surface (`PRODUCT_API_TOKEN`). Endpoints land
  with their beads: writes (backfill + live claims), reads (products by legacy id, by code,
  as-of, change feed).
  """
  use Plug.Router

  plug(Api.Auth, :product)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON)
  plug(:dispatch)

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, JSON.encode!(%{error: "not found"}))
  end
end
