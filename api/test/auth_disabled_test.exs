# A nil token disables auth for that surface (dev convenience) — async: false, mutates app env.
defmodule Api.AuthDisabledTest do
  use ExUnit.Case, async: false
  import Plug.Test

  setup do
    product = Application.fetch_env!(:golden_record_api, :product_token)
    Application.put_env(:golden_record_api, :product_token, nil)
    on_exit(fn -> Application.put_env(:golden_record_api, :product_token, product) end)
    :ok
  end

  test "a nil token lets requests through without credentials; other surfaces stay guarded" do
    assert Api.Router.call(conn(:get, "/v1/products/999999"), Api.Router.init([])).status == 404
    assert Api.Router.call(conn(:get, "/steward/v1/queue"), Api.Router.init([])).status == 401
  end
end
