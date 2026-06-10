defmodule Api.StewardRouter do
  @moduledoc """
  The Steward surface (`STEWARD_API_TOKEN` as Bearer, or HTTP Basic for the browser):
  `GET /v1/queue`, `POST /v1/decisions` (JSON), and the minimal HTML queue page at `/` with
  plain form posts to `/decide` — no JS build, same engine decisions underneath.
  """
  use Plug.Router
  require EEx

  plug Api.Auth, :steward
  plug :match
  plug Plug.Parsers, parsers: [:json, :urlencoded], json_decoder: JSON
  plug :dispatch

  get "/v1/queue" do
    json(conn, 200, Api.Steward.queue())
  end

  post "/v1/decisions" do
    {status, body} = Api.Steward.decide(conn.body_params)
    json(conn, status, body)
  end

  # ── the minimal queue page ──────────────────────────────────────────────────
  get "/" do
    conn = fetch_query_params(conn)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page(Api.Steward.queue(), conn.query_params["notice"]))
  end

  post "/decide" do
    {status, body} = conn.body_params |> form_to_decision() |> Api.Steward.decide()

    notice =
      case status do
        200 -> "applied #{body[:applied]}"
        _ -> "rejected (#{status}): #{inspect(body)}"
      end

    conn
    |> put_resp_header("location", "#{steward_path(conn)}?notice=#{URI.encode_www_form(notice)}")
    |> send_resp(303, "")
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  # forms send flat string params; decisions speak the JSON shapes
  defp form_to_decision(%{"kind" => "split"} = p),
    do: %{
      "kind" => "split",
      "key" => p["key"],
      "codes" => String.split(p["codes"] || "", ~r/[\s,]+/, trim: true),
      "by" => p["by"]
    }

  defp form_to_decision(%{"keys" => keys} = p) when is_binary(keys),
    do: Map.put(p, "keys", String.split(keys, "+", trim: true))

  defp form_to_decision(p), do: p

  # mounted under /steward by the front router — Location must include the mount
  defp steward_path(%Plug.Conn{script_name: []}), do: "/"
  defp steward_path(%Plug.Conn{script_name: parts}), do: "/" <> Enum.join(parts, "/")

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  # ── EEx template (compiled) ─────────────────────────────────────────────────
  EEx.function_from_string(
    :defp,
    :page,
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>Steward queue — golden records</title>
      <style>
        :root { color-scheme: dark; }
        body { background:#0e1116; color:#e6edf3; font:14px/1.55 system-ui, sans-serif; max-width:880px; margin:32px auto; padding:0 16px; }
        h1 { font-size:20px; } h2 { font-size:15px; margin-top:28px; color:#e8b94a; }
        .item { border:1px solid #232a33; border-radius:10px; padding:14px 16px; margin:12px 0; background:#161b22; }
        .item.flag { border-color:#7a3b41; }
        code { background:#1b2230; border-radius:5px; padding:1px 6px; font-size:12.5px; }
        .muted { color:#8b949e; } .notice { color:#57c878; }
        form { display:inline-block; margin:8px 8px 0 0; }
        input[type=text] { background:#1b2230; color:#e6edf3; border:1px solid #232a33; border-radius:6px; padding:5px 8px; }
        button { background:#1b2230; color:#e6edf3; border:1px solid #3b4351; border-radius:999px; padding:6px 14px; cursor:pointer; }
        button.danger { border-color:#f0616d; color:#f0616d; }
        button.go { border-color:#6ea8fe; color:#6ea8fe; }
      </style>
    </head>
    <body>
      <h1>Steward queue <span class="muted">(<%= queue.open %> open)</span></h1>
      <%= if notice do %><p class="notice"><%= notice %></p><% end %>
      <%= if queue.open == 0 do %><p class="muted">Nothing needs a human right now — the engine resolved everything it was allowed to.</p><% end %>

      <%= if queue.merges != [] do %><h2>Merge proposals — gated, never automatic</h2><% end %>
      <%= for m <- queue.merges do %>
        <div class="item flag">
          <div><b><%= Enum.join(m.keys, " + ") %></b> <span class="muted">bridged by</span>
            <%= for c <- m.bridge do %><code><%= c %></code><% end %>
          </div>
          <%= for {key, codes} <- m.members do %>
            <div class="muted"><%= key %>: <%= for c <- codes do %><code><%= c %></code><% end %></div>
          <% end %>
          <form method="post" action="decide">
            <input type="hidden" name="kind" value="approve_merge"/>
            <input type="hidden" name="keys" value="<%= Enum.join(m.keys, "+") %>"/>
            <input type="text" name="by" placeholder="your name" required/>
            <button class="go">approve merge</button>
          </form>
          <form method="post" action="decide">
            <input type="hidden" name="kind" value="reject_merge"/>
            <input type="hidden" name="keys" value="<%= Enum.join(m.keys, "+") %>"/>
            <input type="text" name="by" placeholder="your name" required/>
            <button class="danger">reject — two products</button>
          </form>
        </div>
      <% end %>

      <%= if queue.attributes != [] do %><h2>Attribute ties — the engine won't guess</h2><% end %>
      <%= for a <- queue.attributes do %>
        <div class="item">
          <div><b><%= a.field %></b> on <b><%= a.key %></b>:
            <%= for c <- a.candidates do %><code><%= c.source %> says <%= c.value %></code><% end %>
          </div>
          <form method="post" action="decide">
            <input type="hidden" name="kind" value="resolve_attribute"/>
            <input type="hidden" name="key" value="<%= a.key %>"/>
            <input type="hidden" name="field" value="<%= a.field %>"/>
            <input type="text" name="value" placeholder="the correct value" required/>
            <input type="text" name="by" placeholder="your name" required/>
            <button class="go">pick</button>
          </form>
        </div>
      <% end %>

      <h2>Split a key</h2>
      <div class="item">
        <div class="muted">Carve codes out of a key into a fresh product (one recorded operation; attributes and media re-home by code).</div>
        <form method="post" action="decide">
          <input type="hidden" name="kind" value="split"/>
          <input type="text" name="key" placeholder="SK_1" required/>
          <input type="text" name="codes" placeholder="gtin:0871... cnk:7654321" size="34" required/>
          <input type="text" name="by" placeholder="your name" required/>
          <button class="danger">split</button>
        </form>
      </div>
    </body>
    </html>
    """,
    [:queue, :notice]
  )
end
