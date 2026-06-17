<?php

declare(strict_types=1);

namespace GoldenRecord;

/**
 * The relation registry — ported from `Relations` in lib/golden_record_core.ex.
 *
 * Each edge relation declares a lane signature (which lanes its endpoints may live in); adding a
 * relation is a data change here, not an engine change. `member_of`'s target is a collection
 * namespace, not a coded entity, so its to-side is unchecked (null = any).
 */
final class Relations
{
    /** relation => [allowed-from-lanes, allowed-to-lanes | null]. */
    private const SIGNATURES = [
        'contains' => [['product'], ['substance']],
        'describes' => [['description'], ['product', 'substance']],
        'depicts' => [['media'], ['product', 'substance']],
        'member_of' => [['product'], null],
        'suppress' => [['description'], ['product']],
    ];

    /** Relation name for a wire name ("contains" => 'contains'), or null if unknown. */
    public static function parse(string $name): ?string
    {
        return isset(self::SIGNATURES[$name]) ? $name : null;
    }

    /** @return array<string, array{0: list<string>, 1: list<string>|null}> */
    public static function signatures(): array
    {
        return self::SIGNATURES;
    }

    /**
     * Do an edge's endpoints satisfy the relation's lane signature? (uuid is lane-neutral.)
     *
     * @param array{0: string, 1: string} $from
     * @param array{0: string, 1: string}|mixed $to a code pair, or a collection tuple for member_of
     */
    public static function validSignature(string $relation, array $from, mixed $to): bool
    {
        if (!isset(self::SIGNATURES[$relation])) {
            return false;
        }
        [$froms, $tos] = self::SIGNATURES[$relation];

        if (!self::laneOk(Lanes::laneOfScheme($from[0]), $froms)) {
            return false;
        }
        if ($tos === null) {
            return true;
        }

        return is_array($to) && array_is_list($to) && count($to) === 2
            && self::laneOk(Lanes::laneOfScheme($to[0]), $tos);
    }

    /** @param list<string> $allowed */
    private static function laneOk(?string $lane, array $allowed): bool
    {
        return $lane === null || in_array($lane, $allowed, true);
    }
}
