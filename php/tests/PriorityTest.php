<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Priority;
use PHPUnit\Framework\TestCase;

/**
 * Ported from the Priority usage in golden_record_test.exs: tier index, default fallback, INF when
 * a source is in no tier.
 */
final class PriorityTest extends TestCase
{
    public function test_rank_by_tier_then_default_then_infinity(): void
    {
        $p = Priority::new(
            ['weight_g' => [['manufacturer'], ['supplier'], ['marketplace']]],
            [['manufacturer'], ['supplier'], ['marketplace']],
        );

        self::assertSame(0, $p->rank('weight_g', 'manufacturer'));
        self::assertSame(2, $p->rank('weight_g', 'marketplace'));
        // a dimension absent from the table falls back to the default tiers
        self::assertSame(1, $p->rank('anything', 'supplier'));
        // a source in no tier ranks last (INF)
        self::assertSame(INF, $p->rank('weight_g', 'nobody'));
    }
}
