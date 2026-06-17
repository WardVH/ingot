<?php

declare(strict_types=1);

namespace GoldenRecord;

/**
 * Variant clustering — ported from `Cluster` in lib/golden_record_core.ex.
 *
 * Groups identity codes into variant clusters via connected components: two identity code-sets
 * bridge iff they share a NON-shared code. `shared` codes are carried as members but never bridge
 * (a shared GTIN on a bundle and its unit must not fuse them). Clusters come out sorted by their
 * minimum code, so the ledger mints keys deterministically.
 */
final class Cluster
{
    /**
     * @param list<array<string,mixed>> $liveClaims
     * @param array<string, array{0: string, 1: string}> $shared a code-set
     * @return list<array<string, array{0: string, 1: string}>> a list of code-sets (the clusters)
     */
    public static function variants(array $liveClaims, array $shared = []): array
    {
        $sets = [];
        foreach ($liveClaims as $c) {
            if ($c['kind'] !== 'identity') {
                continue;
            }
            $sets[] = Sets::of($c['data']['codes']);
        }

        $components = self::connectedComponents($sets, $shared);

        usort($components, static function (array $a, array $b): int {
            return Sets::compareCodes(Sets::min($a), Sets::min($b));
        });

        return $components;
    }

    /**
     * Mirror of the Elixir reduce: for each incoming set, fuse it with every accumulated component
     * it bridges (share a bare — i.e. non-shared — code), leaving the rest disjoint.
     *
     * @param list<array<string, array{0: string, 1: string}>> $sets
     * @param array<string, array{0: string, 1: string}> $shared
     * @return list<array<string, array{0: string, 1: string}>>
     */
    private static function connectedComponents(array $sets, array $shared): array
    {
        $acc = [];
        foreach ($sets as $set) {
            $bareSet = Sets::difference($set, $shared);

            $overlapping = [];
            $disjoint = [];
            foreach ($acc as $comp) {
                if (!Sets::disjoint(Sets::difference($comp, $shared), $bareSet)) {
                    $overlapping[] = $comp;
                } else {
                    $disjoint[] = $comp;
                }
            }

            $merged = $set;
            foreach ($overlapping as $comp) {
                $merged = Sets::union($merged, $comp);
            }

            // Elixir prepends the merged component: [merged | disjoint].
            array_unshift($disjoint, $merged);
            $acc = $disjoint;
        }

        return $acc;
    }
}
