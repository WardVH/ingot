# Scaffold contract tests (bead gr-0de): health, the two-token separation, and the second-port
# split. Endpoints themselves land with their own beads — here the surfaces 404 once authorized.

defmodule Api.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @product "test-product-token"
  @steward "test-steward-token"

  defp call(router, conn), do: router.call(conn, router.init([]))
  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  describe "GET /health" do
    test "is unauthenticated and reports the database" do
      conn = call(Api.Router, conn(:get, "/health"))
      assert conn.status == 200
      assert %{"status" => "ok", "db" => true} = JSON.decode!(conn.resp_body)
    end
  end

  describe "token separation" do
    test "the Product surface requires the product token" do
      assert call(Api.Router, conn(:get, "/v1/anything")).status == 401

      conn = conn(:get, "/v1/anything") |> bearer(@product)
      assert call(Api.Router, conn).status == 404
    end

    test "a steward token does NOT open the Product surface" do
      conn = conn(:get, "/v1/anything") |> bearer(@steward)
      assert call(Api.Router, conn).status == 401
    end

    test "the Steward surface requires the steward token" do
      assert call(Api.Router, conn(:get, "/steward/v1/queue")).status == 401

      conn = conn(:get, "/steward/v1/queue") |> bearer(@steward)
      assert call(Api.Router, conn).status == 200
    end

    test "a product token does NOT open the Steward surface" do
      conn = conn(:get, "/steward/v1/queue") |> bearer(@product)
      assert call(Api.Router, conn).status == 401
    end

    test "a malformed authorization header is rejected" do
      conn = conn(:get, "/v1/anything") |> put_req_header("authorization", @product)
      assert call(Api.Router, conn).status == 401
    end
  end

  describe "second-port separation" do
    test "the public router does not serve /steward at all, even with a valid token" do
      conn = conn(:get, "/steward/v1/queue") |> bearer(@steward)
      assert call(Api.PublicRouter, conn).status == 404
    end

    test "the steward site serves /steward and health, but not /v1" do
      conn = conn(:get, "/steward/v1/queue") |> bearer(@steward)
      assert call(Api.StewardSite, conn).status == 200

      assert call(Api.StewardSite, conn(:get, "/health")).status == 200

      conn = conn(:get, "/v1/products/1") |> bearer(@product)
      assert call(Api.StewardSite, conn).status == 404
    end
  end

  test "unknown paths 404 with a JSON body" do
    conn = call(Api.Router, conn(:get, "/nope"))
    assert conn.status == 404
    assert %{"error" => "not found"} = JSON.decode!(conn.resp_body)
  end
end
