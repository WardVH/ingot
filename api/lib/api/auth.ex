defmodule Api.Auth do
  @moduledoc """
  Bearer-token auth, one token per surface: `plug Api.Auth, :product` / `plug Api.Auth, :steward`.
  A leaked Product token cannot reach steward decisions and vice versa. Constant-time comparison.
  """
  import Plug.Conn

  def init(surface) when surface in [:product, :steward], do: surface

  def call(conn, surface) do
    expected = Application.fetch_env!(:golden_record_api, :"#{surface}_token")

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end
end
