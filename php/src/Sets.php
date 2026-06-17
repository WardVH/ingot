<?php

declare(strict_types=1);

namespace Ingot;

/**
 * A set of codes — the PHP analogue of an Elixir `MapSet` of `{scheme, value}` tuples.
 *
 * Represented as an assoc array keyed by `Codes::key($code)` ("scheme\x1fvalue") whose values are
 * the `[scheme, value]` pairs themselves. Keying by the unit-separator join gives O(1) membership
 * and lets PHP's `array_*_key` family stand in for `MapSet.union/intersection/difference`, while
 * the stored values preserve the original pair so iteration yields codes, not keys.
 *
 * Every function is pure: inputs are never mutated.
 */
final class Sets
{
    /**
     * Build a set from a list of `[scheme, value]` codes (later duplicates collapse, as in a set).
     *
     * @param list<array{0: string, 1: string}> $codes
     * @return array<string, array{0: string, 1: string}>
     */
    public static function of(array $codes): array
    {
        $set = [];
        foreach ($codes as $code) {
            $set[Codes::key($code)] = $code;
        }

        return $set;
    }

    /**
     * @param array<string, array{0: string, 1: string}> $set
     * @param array{0: string, 1: string} $code
     */
    public static function member(array $set, array $code): bool
    {
        return isset($set[Codes::key($code)]);
    }

    /**
     * Union (`MapSet.union`) — right wins on key collision (values are equal anyway).
     *
     * @param array<string, array{0: string, 1: string}> $a
     * @param array<string, array{0: string, 1: string}> $b
     * @return array<string, array{0: string, 1: string}>
     */
    public static function union(array $a, array $b): array
    {
        return $a + $b;
    }

    /**
     * Intersection (`MapSet.intersection`) — codes present in both.
     *
     * @param array<string, array{0: string, 1: string}> $a
     * @param array<string, array{0: string, 1: string}> $b
     * @return array<string, array{0: string, 1: string}>
     */
    public static function intersection(array $a, array $b): array
    {
        return array_intersect_key($a, $b);
    }

    /**
     * Difference (`MapSet.difference`) — codes in $a but not $b.
     *
     * @param array<string, array{0: string, 1: string}> $a
     * @param array<string, array{0: string, 1: string}> $b
     * @return array<string, array{0: string, 1: string}>
     */
    public static function difference(array $a, array $b): array
    {
        return array_diff_key($a, $b);
    }

    /**
     * Disjoint (`MapSet.disjoint?`) — no shared codes.
     *
     * @param array<string, array{0: string, 1: string}> $a
     * @param array<string, array{0: string, 1: string}> $b
     */
    public static function disjoint(array $a, array $b): bool
    {
        return array_intersect_key($a, $b) === [];
    }

    /**
     * The codes as a plain list (insertion order). Use `valuesSorted` for a deterministic order.
     *
     * @param array<string, array{0: string, 1: string}> $set
     * @return list<array{0: string, 1: string}>
     */
    public static function values(array $set): array
    {
        return array_values($set);
    }

    /**
     * The codes sorted by [scheme, value] — the analogue of `Enum.sort(MapSet.to_list(set))`,
     * which sorts tuples lexicographically. Used wherever the engine emits a sorted code list.
     *
     * @param array<string, array{0: string, 1: string}> $set
     * @return list<array{0: string, 1: string}>
     */
    public static function valuesSorted(array $set): array
    {
        $codes = array_values($set);
        usort($codes, self::compareCodes(...));

        return $codes;
    }

    /**
     * Lexicographic (byte-wise) comparison of two [scheme, value] codes — Elixir's term order on
     * tuples of strings. PHP's `<=>` would compare numeric-looking values NUMERICALLY, so a
     * gtin "03282770114577" vs "03282770146004" or a cnk "44" vs "1035" could mis-order; strcmp is
     * the byte-wise order Elixir uses.
     *
     * @param array{0: string, 1: string} $a
     * @param array{0: string, 1: string} $b
     */
    public static function compareCodes(array $a, array $b): int
    {
        $c = strcmp($a[0], $b[0]);

        return $c !== 0 ? $c : strcmp($a[1], $b[1]);
    }

    /**
     * The smallest code by [scheme, value] order — `Enum.min/1` over a MapSet of tuples.
     *
     * @param array<string, array{0: string, 1: string}> $set
     * @return array{0: string, 1: string}
     */
    public static function min(array $set): array
    {
        $codes = self::valuesSorted($set);

        return $codes[0];
    }

    /**
     * @param array<string, array{0: string, 1: string}> $set
     */
    public static function size(array $set): int
    {
        return count($set);
    }
}
