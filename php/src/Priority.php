<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Source-priority ranking — ported from the `Priority` struct in lib/golden_record_core.ex.
 *
 * `table` maps a dimension (a field name) to a list of tiers; each tier is a list of sources that
 * rank equally. `default` is the tier list used for any dimension absent from the table. `rank`
 * returns the 0-based index of the tier a source falls in, or INF (`:infinity`) when the source
 * appears in no tier — so lower rank = higher priority, and an unranked source sorts last.
 */
final class Priority
{
    /**
     * @param array<string, list<list<string>>> $table dimension => list of tiers (each a list of sources)
     * @param list<list<string>> $default fallback tier list for unlisted dimensions
     */
    public function __construct(
        public readonly array $table,
        public readonly array $default,
    ) {
    }

    /**
     * @param array<string, list<list<string>>> $table
     * @param list<list<string>> $default
     */
    public static function new(array $table, array $default): self
    {
        return new self($table, $default);
    }

    /** The tier index of `source` for `dimension`, or INF when it is in no tier. */
    public function rank(string $dimension, ?string $source): int|float
    {
        $tiers = $this->table[$dimension] ?? $this->default;

        foreach ($tiers as $i => $tier) {
            if (in_array($source, $tier, true)) {
                return $i;
            }
        }

        return INF;
    }
}
