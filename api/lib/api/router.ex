defmodule Api.Health do
  @moduledoc false
  import Plug.Conn

  def respond(conn) do
    {status, body} =
      case Postgrex.query(Api.DB, "SELECT 1", [], timeout: 2_000) do
        {:ok, _} -> {200, %{status: "ok", db: true}}
        {:error, _} -> {503, %{status: "degraded", db: false}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  def not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, JSON.encode!(%{error: "not found"}))
  end
end

defmodule Api.Router do
  @moduledoc """
  The default front door (single-listener mode): `/health` (unauthenticated, for Docker/Dokploy
  checks), the Product API under `/v1`, the Steward surface under `/steward`. With `STEWARD_PORT`
  set, `Api.PublicRouter` + `Api.StewardSite` replace this one — same paths, separate listeners.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get("/health", do: Api.Health.respond(conn))
  forward("/v1", to: Api.ProductRouter)
  forward("/steward", to: Api.StewardRouter)
  match(_, do: Api.Health.not_found(conn))
end

defmodule Api.PublicRouter do
  @moduledoc "The main listener when the steward surface is split onto its own port — no `/steward` here."
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get("/health", do: Api.Health.respond(conn))
  forward("/v1", to: Api.ProductRouter)
  match(_, do: Api.Health.not_found(conn))
end

defmodule Api.StewardSite do
  @moduledoc "The steward listener (`STEWARD_PORT`): same `/steward` paths, its own port."
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get("/health", do: Api.Health.respond(conn))
  forward("/steward", to: Api.StewardRouter)
  match(_, do: Api.Health.not_found(conn))
end
