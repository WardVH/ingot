defmodule Api.StewardRouter do
  @moduledoc """
  The Steward surface — humans curating conflicts (`STEWARD_API_TOKEN`). Queue + decisions + the
  minimal HTML page land with their bead. Optionally bound to its own listener via `STEWARD_PORT`.
  """
  use Plug.Router

  plug(Api.Auth, :steward)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json, :urlencoded], json_decoder: JSON)
  plug(:dispatch)

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, JSON.encode!(%{error: "not found"}))
  end
end
