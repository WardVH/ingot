defmodule Mix.Tasks.Steward.Decide do
  @shortdoc "Submit a steward decision (approve_merge | reject_merge | resolve_attribute | split)"

  @moduledoc """
  A thin convenience wrapper over `Api.Steward.decide/1` — exactly the JSON surface, from the
  terminal. Four-eyes applies unchanged: the first `approve_merge` endorses, a second steward
  (a different `--by`) fuses.

      mix steward.decide approve_merge --keys SK_1+SK_2 --by sam --reason "same product"
      mix steward.decide reject_merge --keys SK_1+SK_2 --by sam --reason "bundle vs unit"
      mix steward.decide resolve_attribute --key SK_1 --field color --value ivory --by sam
      mix steward.decide split --key SK_1 --codes "gtin:0871... cnk:7654321" --by sam
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case parse(argv) do
      {:ok, decision} ->
        Mix.Tasks.Steward.Queue.start_app!()
        {status, body} = Api.Steward.decide(decision)
        Mix.shell().info("#{status} #{JSON.encode!(body)}")
        if status != 200, do: Mix.raise("decision was not applied (#{status})")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc "argv -> the decision map `Api.Steward.decide/1` speaks (pure, so it is testable)."
  def parse(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          keys: :string,
          key: :string,
          field: :string,
          value: :string,
          codes: :string,
          by: :string,
          reason: :string
        ]
      )

    with [kind] <- args,
         [] <- invalid do
      {:ok,
       %{"kind" => kind, "by" => opts[:by]}
       |> put_if("reason", opts[:reason])
       |> put_if("keys", opts[:keys] && String.split(opts[:keys], "+", trim: true))
       |> put_if("key", opts[:key])
       |> put_if("field", opts[:field])
       |> put_if("value", opts[:value])
       |> put_if("codes", opts[:codes] && String.split(opts[:codes], ~r/[\s,]+/, trim: true))}
    else
      _ ->
        {:error,
         "usage: mix steward.decide <kind> --by <steward> [--reason <text>] " <>
           "[--keys SK_1+SK_2 | --key SK_1 --field f --value v | --key SK_1 --codes \"...\"]"}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
