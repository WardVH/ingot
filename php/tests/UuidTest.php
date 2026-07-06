<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Uuid;
use PHPUnit\Framework\TestCase;

/**
 * Ported from entity_lanes_test.exs ("minted uuids are v4-shaped and unique"): mint yields a
 * lane-neutral ['uuid', v4] identity code, and v4 values are v4-shaped and unique.
 */
final class UuidTest extends TestCase
{
    public function test_mint_yields_a_uuid_scheme_code(): void
    {
        [$scheme, $value] = Uuid::mint();
        self::assertSame('uuid', $scheme);
        self::assertMatchesRegularExpression(
            '/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/',
            $value,
        );
    }

    public function test_minted_values_are_unique(): void
    {
        self::assertNotSame(Uuid::mint(), Uuid::mint());
        self::assertNotSame(Uuid::v4(), Uuid::v4());
    }
}
