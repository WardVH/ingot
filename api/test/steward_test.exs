# Steward surface (bead gr-xwb), end to end: the queue (merge proposals + attribute ties), the
# four decisions, staleness (409), the HTML page with basic-auth, and the demo's whole
# mistake-is-cheap arc — wrong merge → contradiction → split → re-home — through HTTP this time.

defmodule Api.StewardTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  setup do
    Postgrex.query!(Api.DB, "TRUNCATE events, snapshots, backfill_seen", [])
    :ok
  end

  defp product!(method, path, body \\ nil) do
    conn(method, path, body && JSON.encode!(body))
    |> then(&if(body, do: put_req_header(&1, "content-type", "application/json"), else: &1))
    |> put_req_header("authorization", "Bearer test-product-token")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp steward!(method, path, body \\ nil) do
    conn(method, path, body && JSON.encode!(body))
    |> then(&if(body, do: put_req_header(&1, "content-type", "application/json"), else: &1))
    |> put_req_header("authorization", "Bearer test-steward-token")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  # two products that a marketplace listing later bridges — the gated proposal
  defp seed_bridged do
    product!(:post, "/v1/claims", %{
      claims: [
        %{
          kind: "identity",
          source: "acme",
          ref: "A",
          codes: ["cnk:1000001", "gtin:05012345678900"]
        },
        %{
          kind: "attribute",
          source: "acme",
          code: "gtin:05012345678900",
          field: "weight_g",
          value: 250
        },
        %{
          kind: "media",
          source: "acme",
          asset: "IMG-A",
          target: "gtin:05012345678900",
          role: "primary",
          uri: "cdn://a"
        },
        %{
          kind: "identity",
          source: "bolt",
          ref: "B",
          codes: ["cnk:1000002", "gtin:08712345678906"]
        },
        %{
          kind: "attribute",
          source: "bolt",
          code: "gtin:08712345678906",
          field: "weight_g",
          value: 480
        }
      ]
    })

    product!(:post, "/v1/claims", %{
      claims: [
        %{
          kind: "identity",
          source: "mkt",
          ref: "K",
          codes: ["gtin:05012345678900", "gtin:08712345678906"]
        }
      ]
    })

    Api.Store.state().ledger.members |> Map.keys() |> Enum.sort()
  end

  describe "GET /steward/v1/queue" do
    test "shows the gated merge proposal with its bridge and members" do
      [k1, k2] = seed_bridged()

      body = decoded(steward!(:get, "/steward/v1/queue"))
      assert body["open"] >= 1
      assert [merge] = body["merges"]
      assert Enum.sort(merge["keys"]) == [k1, k2]
      assert Map.keys(merge["members"]) |> Enum.sort() == [k1, k2]

      # the CONNECTING CLAIM is named: the marketplace listing, each code tagged with its owner
      assert [bridge] = merge["bridges"]
      assert bridge["source"] == "mkt"
      assert bridge["ref"] == "K"
      owners = Map.new(bridge["codes"], &{&1["code"], &1["owner"]})
      assert owners["gtin:05012345678900"] == k1
      assert owners["gtin:08712345678906"] == k2

      # no code is directly shared between the keys here — the bridge is the listing
      assert merge["shared"] == []
    end

    test "shows attribute ties the permissive priority cannot settle" do
      product!(:post, "/v1/claims", %{
        claims: [
          %{kind: "identity", source: "a", ref: "X", codes: ["cnk:1000001"]},
          %{kind: "attribute", source: "a", code: "cnk:1000001", field: "color", value: "white"},
          %{kind: "attribute", source: "b", code: "cnk:1000001", field: "color", value: "ivory"}
        ]
      })

      body = decoded(steward!(:get, "/steward/v1/queue"))
      assert [tie] = body["attributes"]
      assert tie["field"] == "color"
      assert length(tie["candidates"]) == 2
    end
  end

  describe "POST /steward/v1/decisions" do
    test "approve_merge fuses; the absorbed legacy id keeps answering; the queue closes" do
      [k1, k2] = seed_bridged()
      absorbed_id = Api.Store.state().assigned[k2]

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "approve_merge",
          keys: [k1, k2],
          by: "sam"
        })

      assert conn.status == 200

      assert decoded(steward!(:get, "/steward/v1/queue"))["merges"] == []

      body = decoded(product!(:get, "/v1/products/#{absorbed_id}"))
      assert body["key"] == k1
      assert body["merged_from"] == k2
    end

    test "reject_merge records the verdict; both keys survive; the proposal closes for good" do
      [k1, k2] = seed_bridged()

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "reject_merge",
          keys: [k1, k2],
          by: "sam"
        })

      assert conn.status == 200
      assert decoded(steward!(:get, "/steward/v1/queue"))["merges"] == []
      # both keys survive — the bridging listing never minted a third (the guard gated it)
      assert map_size(Api.Store.state().ledger.members) == 2
    end

    test "resolve_attribute records the pick — visible with steward provenance on the product" do
      product!(:post, "/v1/claims", %{
        claims: [
          %{kind: "identity", source: "a", ref: "X", codes: ["cnk:1000001"]},
          %{kind: "attribute", source: "a", code: "cnk:1000001", field: "color", value: "white"},
          %{kind: "attribute", source: "b", code: "cnk:1000001", field: "color", value: "ivory"}
        ]
      })

      state = Api.Store.state()
      [{key, id}] = Enum.to_list(state.assigned)

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "resolve_attribute",
          key: key,
          field: "color",
          value: "ivory",
          by: "sam"
        })

      assert conn.status == 200
      assert decoded(steward!(:get, "/steward/v1/queue"))["attributes"] == []

      body = decoded(product!(:get, "/v1/products/#{id}"))
      color = Enum.find(body["attributes"], &(&1["field"] == "color"))

      assert %{"value" => "ivory", "winner" => "steward:sam", "status" => "resolved_by_steward"} =
               color
    end

    test "the full mistake-is-cheap arc: wrong merge → split → attributes and media re-home" do
      [k1, k2] = seed_bridged()

      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "split",
          key: k1,
          codes: ["gtin:08712345678906", "cnk:1000002"],
          by: "sam"
        })

      assert conn.status == 200

      state = Api.Store.state()
      assert map_size(state.ledger.members) >= 2
      # the carved key has bolt's codes, bolt's weight, and a legacy id of its own
      {carved, _} =
        Enum.find(state.ledger.members, fn {_k, codes} ->
          MapSet.member?(codes, {:gtin, "08712345678906"})
        end)

      carved_id = state.assigned[carved]
      assert carved_id != nil

      body = decoded(product!(:get, "/v1/products/#{carved_id}"))
      weight = Enum.find(body["attributes"], &(&1["field"] == "weight_g"))
      assert weight["value"] == 480
      assert body["media"] == []

      # acme's product kept its weight AND its image — nothing re-imported
      acme_id = state.assigned[Api.State.follow(state, k1)]
      body = decoded(product!(:get, "/v1/products/#{acme_id}"))
      assert Enum.find(body["attributes"], &(&1["field"] == "weight_g"))["value"] == 250
      assert [%{"asset" => "dam:IMG-A"}] = body["media"]
    end

    test "decisions against stale state answer 409 with what's live now" do
      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "approve_merge",
          keys: ["SK_1", "SK_9"],
          by: "sam"
        })

      assert conn.status == 409
      assert %{"live_keys" => _} = decoded(conn)

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "split",
          key: "SK_77",
          codes: ["cnk:1"],
          by: "sam"
        })

      assert conn.status == 409
    end

    test "an unknown decision kind answers 422" do
      assert steward!(:post, "/steward/v1/decisions", %{kind: "delete_everything", by: "sam"}).status ==
               422
    end
  end

  describe "repairs — select the wrong codes" do
    test "an approved merge appears under repairs with selectable codes and their claiming sources" do
      [k1, k2] = seed_bridged()

      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      body = decoded(steward!(:get, "/steward/v1/queue"))
      assert [repair] = body["repairs"]
      assert repair["key"] == k1
      assert repair["merged_from"] == [k2]

      by_code = Map.new(repair["codes"], &{&1["code"], &1["sources"]})
      assert "bolt" in by_code["gtin:08712345678906"]
      assert "acme" in by_code["cnk:1000001"]
    end

    test "selecting EVERY code answers 422 — an empty key is never created" do
      [k1, k2] = seed_bridged()

      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      all_codes =
        Api.Store.state().ledger.members[k1] |> Enum.sort() |> Enum.map(&Api.Views.code/1)

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "split",
          key: k1,
          codes: all_codes,
          by: "sam"
        })

      assert conn.status == 422
      assert decoded(conn)["error"] =~ "empty"
    end

    test "the checkbox form posts codes[] and splits — the repair disappears afterwards" do
      [k1, k2] = seed_bridged()

      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      conn =
        conn(
          :post,
          "/steward/decide",
          "kind=split&key=#{k1}&codes[]=gtin%3A08712345678906&codes[]=cnk%3A1000002&by=sam"
        )
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("authorization", "Basic " <> Base.encode64("sam:test-steward-token"))
        |> then(&Api.Router.call(&1, Api.Router.init([])))

      assert conn.status == 303
      state = Api.Store.state()
      assert map_size(state.ledger.members) == 2
      # the carved key is back on its own, with its own legacy id
      {carved, _} =
        Enum.find(state.ledger.members, fn {_k, codes} ->
          MapSet.member?(codes, {:gtin, "08712345678906"})
        end)

      assert state.assigned[carved] != nil
    end
  end

  describe "the HTML queue page" do
    defp basic(conn),
      do:
        put_req_header(conn, "authorization", "Basic " <> Base.encode64("sam:test-steward-token"))

    test "renders the queue over HTTP Basic (the browser path)" do
      seed_bridged()

      conn = conn(:get, "/steward/") |> basic() |> then(&Api.Router.call(&1, Api.Router.init([])))
      assert conn.status == 200
      assert conn.resp_body =~ "Merge proposals"
      assert conn.resp_body =~ "the new evidence"
      assert conn.resp_body =~ "separate products"
      # forms must post INSIDE the mount — a relative "decide" resolved to /decide (404)
      assert conn.resp_body =~ ~s(action="/steward/decide")
      refute conn.resp_body =~ ~s(action="decide")
      assert conn.resp_body =~ "Manual repairs"
    end

    test "challenges without credentials so the browser prompts" do
      conn = conn(:get, "/steward/") |> then(&Api.Router.call(&1, Api.Router.init([])))
      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="steward")]
    end

    test "a form post decides and redirects back to the mounted page" do
      [k1, k2] = seed_bridged()

      conn =
        conn(:post, "/steward/decide", "kind=approve_merge&keys=#{k1}+#{k2}&by=sam")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> basic()
        |> then(&Api.Router.call(&1, Api.Router.init([])))

      assert conn.status == 303
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/steward?notice=")
      assert map_size(Api.Store.state().ledger.members) == 2
    end
  end
end
