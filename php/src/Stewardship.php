<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Stewardship detection — ported from `Stewardship` in lib/golden_record_core.ex.
 *
 * Pure projections over the identity state that surface items for the steward queue.
 * `detectWithdrawals` flags keys that lost a source (the source retracted its listing)
 * but still survive under other sources — the steward needs visibility.
 */
final class Stewardship
{
    /**
     * Flag SOURCE WITHDRAWALS: a source retracted its listing (codes: []) but the key
     * survives under other sources.
     *
     * @param list<array<string,mixed>> $oldLive current identity claims BEFORE the retraction
     * @param list<array<string,mixed>> $newLive current identity claims AFTER the retraction
     * @param array<string, array<string, array{0: string, 1: string}>> $members post-reconcile ledger members
     * @return list<array<string,mixed>> ConflictFlagged events with subject ['source_withdrew', key]
     */
    public static function detectWithdrawals(array $oldLive, array $newLive, array $members, mixed $at): array
    {
        $oldSources = self::sourcesPerKey($oldLive, $members);
        $newSources = self::sourcesPerKey($newLive, $members);

        $flags = [];
        foreach ($members as $key => $_codes) {
            $old = $oldSources[$key] ?? [];
            $new = $newSources[$key] ?? [];

            $lost = array_diff($old, $new);
            if ($lost === []) {
                continue;
            }

            $candidates = [];
            foreach ($lost as $source) {
                $candidates[] = ['source' => $source];
            }

            $flags[] = Events::conflictFlagged(['source_withdrew', $key], $candidates, $at);
        }

        return $flags;
    }

    /**
     * For each key, compute which sources contribute non-empty identity claims with codes
     * that belong to that key's code-set.
     *
     * @param list<array<string,mixed>> $liveClaims
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     * @return array<string, list<string>> key => list of source names
     */
    private static function sourcesPerKey(array $liveClaims, array $members): array
    {
        $result = [];
        foreach ($liveClaims as $claim) {
            if (($claim['kind'] ?? null) !== 'identity') {
                continue;
            }
            if (empty($claim['data']['codes'])) {
                continue;
            }
            foreach ($members as $key => $codes) {
                foreach ($claim['data']['codes'] as $code) {
                    if (Sets::member($codes, $code)) {
                        $result[$key][] = $claim['source'];
                        break;
                    }
                }
            }
        }

        foreach ($result as $key => $sources) {
            $result[$key] = array_values(array_unique($sources));
        }

        return $result;
    }
}
