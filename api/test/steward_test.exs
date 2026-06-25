# Steward surface (bead gr-xwb), end to end: the queue (merge proposals + attribute ties), the
# four decisions, staleness (409), the HTML page with basic-auth, and the demo's whole
# mistake-is-cheap arc — wrong merge → contradiction → split → re-home — through HTTP this time.
#
# gr-bb7 changed merge approval to FOUR-EYES: a single approve_merge now ENDORSES (nothing
# fuses) and a second, different steward's approve applies the merge — so every test that
# previously fused with one decision now decides twice (`approve!/3`). Decisions also carry an
# optional reason, recorded in the log and visible in the queue and the change feed.

defmodule Api.StewardTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  setup do
    Postgrex.query!(Api.DB, "TRUNCATE events, snapshots, backfill_seen, live_batches", [])
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

  # four-eyes merge: endorse as `proposer`, fuse as `approver`
  defp approve!(keys, proposer, approver) do
    assert steward!(:post, "/steward/v1/decisions", %{
             kind: "approve_merge",
             keys: keys,
             by: proposer
           }).status == 200

    steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: keys, by: approver})
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
    # gr-bb7: this test previously fused on a SINGLE approve — four-eyes is the new contract:
    # the first approve endorses, the same steward again is refused BY THE ENGINE, a second
    # steward fuses. The post-merge assertions (legacy id, queue closing) are unchanged.
    test "approve_merge is four-eyes: endorse, refuse the same steward, a second one fuses" do
      [k1, k2] = seed_bridged()
      absorbed_id = Api.Store.state().assigned[k2]

      # first approve: an endorsement with a reason — nothing fuses yet
      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "approve_merge",
          keys: [k1, k2],
          by: "sam",
          reason: "same product, two listings"
        })

      assert conn.status == 200
      assert decoded(conn)["applied"] == "propose_merge"
      assert map_size(Api.Store.state().ledger.members) == 2

      # the queue shows who endorsed and why — the proposal is replayable state, not UI memory
      assert [merge] = decoded(steward!(:get, "/steward/v1/queue"))["merges"]
      assert merge["proposal"]["by"] == "sam"
      assert merge["proposal"]["reason"] == "same product, two listings"

      # the same steward cannot supply the second pair of eyes — refused by the engine
      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "approve_merge",
          keys: [k1, k2],
          by: "sam"
        })

      assert conn.status == 422
      assert decoded(conn)["error"] =~ "four-eyes"
      assert map_size(Api.Store.state().ledger.members) == 2

      # a different steward approves: the merge applies, the absorbed legacy id keeps answering
      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "approve_merge",
          keys: [k1, k2],
          by: "alex",
          reason: "verified against the GTIN registry"
        })

      assert conn.status == 200
      assert decoded(conn)["applied"] == "approve_merge"

      assert decoded(steward!(:get, "/steward/v1/queue"))["merges"] == []

      body = decoded(product!(:get, "/v1/products/#{absorbed_id}"))
      assert body["key"] == k1
      assert body["merged_from"] == k2

      # both halves of the four eyes — endorsement and approval, each with its reason —
      # are in the change feed
      feed = decoded(product!(:get, "/v1/changes?since=0&limit=1000"))["events"]

      assert Enum.any?(
               feed,
               &(&1["type"] == "merge_endorsed" and &1["by"] == "sam" and
                   &1["reason"] == "same product, two listings")
             )

      assert Enum.any?(
               feed,
               &(&1["type"] == "decision" and &1["by"] == "alex" and
                   &1["reason"] == "verified against the GTIN registry")
             )
    end

    # rejection stays SINGLE-steward: it preserves the safe status quo (nothing fuses), so it
    # needs no second pair of eyes — and it also clears any pending endorsement.
    test "reject_merge records the verdict; both keys survive; the proposal closes for good" do
      [k1, k2] = seed_bridged()

      # an endorsement exists — rejection must sweep it away too
      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "reject_merge",
          keys: [k1, k2],
          by: "kim",
          reason: "bundle vs unit — two products"
        })

      assert conn.status == 200
      assert decoded(steward!(:get, "/steward/v1/queue"))["merges"] == []
      # both keys survive — the bridging listing never minted a third (the guard gated it)
      assert map_size(Api.Store.state().ledger.members) == 2
      # the pending endorsement died with the rejection
      assert Api.Store.state().proposals == %{}

      # the reason is in the log, readable from the feed
      feed = decoded(product!(:get, "/v1/changes?since=0&limit=1000"))["events"]

      assert Enum.any?(
               feed,
               &(&1["type"] == "decision" and &1["decision"] == "rejected" and
                   &1["reason"] == "bundle vs unit — two products")
             )
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
          by: "sam",
          reason: "manufacturer spec sheet says ivory"
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

      # gr-bb7: the wrong merge now takes two stewards — both fooled by the bridging listing
      assert approve!([k1, k2], "sam", "alex").status == 200

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

      # four-eyes: the first approve endorses, the second (different steward) fuses
      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      steward!(:post, "/steward/v1/decisions", %{
        kind: "approve_merge",
        keys: [k1, k2],
        by: "alex"
      })

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

    test "selecting no owned codes answers 422 — an empty carved key is never created" do
      [k1, k2] = seed_bridged()

      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      steward!(:post, "/steward/v1/decisions", %{
        kind: "approve_merge",
        keys: [k1, k2],
        by: "alex"
      })

      before = Api.Store.state()

      conn =
        steward!(:post, "/steward/v1/decisions", %{
          kind: "split",
          key: k1,
          codes: ["cnk:9999999"],
          by: "sam"
        })

      assert conn.status == 422
      assert decoded(conn)["error"] =~ "owned"
      assert Api.Store.state().ledger.members == before.ledger.members
    end

    test "the checkbox form posts codes[] and splits — the repair disappears afterwards" do
      [k1, k2] = seed_bridged()

      # four-eyes: the first approve endorses, the second (different steward) fuses
      steward!(:post, "/steward/v1/decisions", %{kind: "approve_merge", keys: [k1, k2], by: "sam"})

      steward!(:post, "/steward/v1/decisions", %{
        kind: "approve_merge",
        keys: [k1, k2],
        by: "alex"
      })

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

    # gr-bb7: a form approve now ENDORSES (four-eyes) — the same two-steward dance as the JSON
    # API, through plain form posts. Note the keys value is form-encoded ("+" is a literal).
    defp form_approve!(k1, k2, by, reason \\ nil) do
      body =
        "kind=approve_merge&keys=#{URI.encode_www_form("#{k1}+#{k2}")}&by=#{by}" <>
          if(reason, do: "&reason=#{URI.encode_www_form(reason)}", else: "")

      conn(:post, "/steward/decide", body)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> basic()
      |> then(&Api.Router.call(&1, Api.Router.init([])))
    end

    test "form posts walk the four-eyes dance and redirect back to the mounted page" do
      [k1, k2] = seed_bridged()

      # first steward's form post endorses — redirect carries the notice, nothing fuses
      conn = form_approve!(k1, k2, "sam", "same product")
      assert conn.status == 303
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, "/steward?notice=")
      assert location =~ "propose_merge"
      assert map_size(Api.Store.state().ledger.members) == 2

      # the page now shows the pending endorsement
      page = conn(:get, "/steward/") |> basic() |> then(&Api.Router.call(&1, Api.Router.init([])))
      assert page.resp_body =~ "endorsed by <b>sam</b>"
      assert page.resp_body =~ "approve merge (2nd steward)"

      # the same steward's second form post is refused (the notice says why), still two keys
      conn = form_approve!(k1, k2, "sam")
      assert conn.status == 303
      assert [location] = get_resp_header(conn, "location")
      assert URI.decode_www_form(location) =~ "four-eyes"
      assert map_size(Api.Store.state().ledger.members) == 2

      # a second steward's form post fuses
      conn = form_approve!(k1, k2, "alex")
      assert conn.status == 303
      assert map_size(Api.Store.state().ledger.members) == 1
    end

    # gr-cky: every dynamic value on the page is HTML-escaped. The notice query param is fully
    # attacker-controllable (reflected), proposal by/reason are steward free text (stored), and
    # attribute values arrive verbatim from ingested third-party claims.
    test "escapes the notice query param — no reflected XSS" do
      conn =
        conn(:get, "/steward/?notice=" <> URI.encode_www_form("<script>alert(1)</script>"))
        |> basic()
        |> then(&Api.Router.call(&1, Api.Router.init([])))

      assert conn.status == 200
      refute conn.resp_body =~ "<script>alert(1)</script>"
      assert conn.resp_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "escapes steward-supplied proposal by/reason — no stored XSS" do
      [k1, k2] = seed_bridged()

      # a single endorse leaves a pending proposal the page renders (by + reason)
      assert steward!(:post, "/steward/v1/decisions", %{
               kind: "approve_merge",
               keys: [k1, k2],
               by: "<b>mallory</b>",
               reason: "<script>alert('xss')</script>"
             }).status == 200

      page = conn(:get, "/steward/") |> basic() |> then(&Api.Router.call(&1, Api.Router.init([])))

      refute page.resp_body =~ "<script>alert('xss')</script>"
      refute page.resp_body =~ "<b>mallory</b>"
      assert page.resp_body =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
      assert page.resp_body =~ "&lt;b&gt;mallory&lt;/b&gt;"
    end

    test "escapes ingested attribute values rendered on the page" do
      product!(:post, "/v1/claims", %{
        claims: [
          %{kind: "identity", source: "a", ref: "X", codes: ["cnk:1000001"]},
          %{
            kind: "attribute",
            source: "a",
            code: "cnk:1000001",
            field: "color",
            value: "<script>pwn()</script>"
          },
          %{kind: "attribute", source: "b", code: "cnk:1000001", field: "color", value: "ivory"}
        ]
      })

      page = conn(:get, "/steward/") |> basic() |> then(&Api.Router.call(&1, Api.Router.init([])))

      refute page.resp_body =~ "<script>pwn()</script>"
      assert page.resp_body =~ "&lt;script&gt;pwn()&lt;/script&gt;"
    end
  end
end
