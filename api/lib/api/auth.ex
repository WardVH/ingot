defmodule Api.Auth do
  @moduledoc """
  Bearer-token auth, one token per surface: `plug Api.Auth, :product` / `plug Api.Auth, :steward`.
  A leaked Product token cannot reach steward decisions and vice versa. Constant-time comparison.

  The steward surface ALSO accepts HTTP Basic (any username, the steward token as password) and
  challenges with `WWW-Authenticate` — that is what lets a plain browser open `/steward` and the
  queue page's forms post back, with no JS and no token field.
  """
  import Plug.Conn

  def init(surface) when surface in [:product, :steward], do: surface

  def call(conn, surface) do
    expected = Application.fetch_env!(:golden_record_api, :"#{surface}_token")

    if authorized?(get_req_header(conn, "authorization"), expected, surface) do
      conn
    else
      conn
      |> challenge(surface)
      |> put_resp_content_type("application/json")
      |> send_resp(401, JSON.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end

  defp authorized?(["Bearer " <> token], expected, _surface),
    do: Plug.Crypto.secure_compare(token, expected)

  defp authorized?(["Basic " <> encoded], expected, :steward) do
    with {:ok, userinfo} <- Base.decode64(encoded),
         [_user, password] <- String.split(userinfo, ":", parts: 2) do
      Plug.Crypto.secure_compare(password, expected)
    else
      _ -> false
    end
  end

  defp authorized?(_, _, _), do: false

  defp challenge(conn, :steward),
    do: put_resp_header(conn, "www-authenticate", ~s(Basic realm="steward"))

  defp challenge(conn, _), do: conn
end
