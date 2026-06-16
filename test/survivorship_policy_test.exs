# test/survivorship_policy_test.exs — gr-6y2: Survivorship is policy-driven + toggleable.
#
# Proves the engine seam that keeps medipim-specific scoring OUT of the generic core:
#   * %Priority{}  -> tier ranking, unchanged (back-compat).
#   * :last_wins   -> the "off" toggle: most-recent value wins, deterministic.
#   * injected fn  -> context-aware rank (medipim's off-product penalty lives HERE, not in Priority).
defmodule SurvivorshipPolicyTest do
  use ExUnit.Case, async: true

  defp e(source, value, order), do: %{source: source, value: value, order: order}

  test "back-compat: a %Priority{} still ranks by tier" do
    priority = Priority.new(%{"name" => [["orgA"], ["orgB"]]}, [])
    d = Survivorship.decide("name", [e("orgA", "Foo", 1), e("orgB", "Bar", 2)], priority)
    assert d.winner == "orgA"
    assert d.value == "Foo"
    assert d.status == :resolved
  end

  test ":last_wins (the off toggle) ignores priority — most recent value wins, always resolved" do
    d = Survivorship.decide("name", [e("orgA", "old", 1), e("orgB", "new", 2)], :last_wins)

    assert d.value == "new"
    assert d.winner == "orgB"
    assert d.status == :resolved
    # candidates are ordered most-recent-first, independent of any source ranking
    assert d.candidates == [{"orgB", "new"}, {"orgA", "old"}]
  end

  test "injected rank fn expresses medipim's off-product penalty (context-aware)" do
    scores = %{"name" => %{"A" => 10, "B" => 5}}

    # rank fn closes over the product's scoring org-set; an off-product source is devalued to -1.
    rank = fn scoring_orgs ->
      fn dim, src ->
        base = get_in(scores, [dim, src]) || 0
        score = if MapSet.member?(scoring_orgs, src), do: base, else: -1
        -score
      end
    end

    entries = [e("B", "keep", 1), e("X", "drop", 2)]

    # Product P1: X is NOT on the product -> penalised below default-0/on-product sources -> B wins.
    p1 = rank.(MapSet.new(["A", "B"]))
    assert Survivorship.decide("name", entries, p1).winner == "B"

    # Product P2: X IS on the product -> scores default 0, B (off-product here) is penalised -> X wins.
    # Same claims, different context, different winner — exactly what one static Priority could not do.
    p2 = rank.(MapSet.new(["X"]))
    assert Survivorship.decide("name", entries, p2).winner == "X"
  end
end
