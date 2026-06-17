<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Codes;
use Ingot\Sets;
use PHPUnit\Framework\TestCase;

/**
 * Pins the MapSet-as-keyed-array helper used everywhere a code-set appears.
 */
final class SetsTest extends TestCase
{
    public function test_of_dedups_and_keys_by_scheme_value(): void
    {
        $set = Sets::of([['cnk', '111'], ['gtin', '0111'], ['cnk', '111']]);
        self::assertCount(2, $set);
        self::assertArrayHasKey(Codes::key(['cnk', '111']), $set);
    }

    public function test_member(): void
    {
        $set = Sets::of([['cnk', '111']]);
        self::assertTrue(Sets::member($set, ['cnk', '111']));
        self::assertFalse(Sets::member($set, ['cnk', '222']));
    }

    public function test_union_intersection_difference_disjoint(): void
    {
        $a = Sets::of([['cnk', '1'], ['gtin', '2']]);
        $b = Sets::of([['gtin', '2'], ['cnk', '3']]);

        self::assertCount(3, Sets::union($a, $b));
        self::assertSame([['gtin', '2']], Sets::values(Sets::intersection($a, $b)));
        self::assertSame([['cnk', '1']], Sets::values(Sets::difference($a, $b)));
        self::assertFalse(Sets::disjoint($a, $b));
        self::assertTrue(Sets::disjoint(Sets::of([['cnk', '9']]), $a));
    }

    public function test_values_sorted_and_min(): void
    {
        $set = Sets::of([['gtin', '0111'], ['cnk', '3612173'], ['gtin', '0110']]);
        self::assertSame([['cnk', '3612173'], ['gtin', '0110'], ['gtin', '0111']], Sets::valuesSorted($set));
        self::assertSame(['cnk', '3612173'], Sets::min($set));
    }
}
