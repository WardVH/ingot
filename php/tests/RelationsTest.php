<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Relations;
use PHPUnit\Framework\TestCase;

/**
 * Ported from the Relations usage in entity_lanes_test.exs (edge claims / contract): a wire name
 * parses to a known relation or null, and an edge's endpoints must satisfy the relation's lane
 * signature (uuid is lane-neutral, member_of's to-side is unchecked).
 */
final class RelationsTest extends TestCase
{
    public function test_parse_known_and_unknown(): void
    {
        self::assertSame('contains', Relations::parse('contains'));
        self::assertSame('member_of', Relations::parse('member_of'));
        self::assertNull(Relations::parse('likes'));
    }

    public function test_signatures_are_the_registered_relations(): void
    {
        self::assertSame(
            ['contains', 'describes', 'depicts', 'member_of', 'suppress'],
            array_keys(Relations::signatures()),
        );
    }

    public function test_valid_signature_checks_endpoint_lanes(): void
    {
        // contains: product -> substance
        self::assertTrue(Relations::validSignature('contains', ['cnk', '1'], ['substance_id', 'PARA']));
        // both endpoints product -> the to-side is not a substance, so it violates the signature
        self::assertFalse(Relations::validSignature('contains', ['cnk', '1'], ['cnk', '2']));

        // describes: description -> product | substance
        self::assertTrue(Relations::validSignature('describes', ['text_id', 'D1'], ['cnk', '1']));
        self::assertTrue(Relations::validSignature('describes', ['text_id', 'D1'], ['substance_id', 'PARA']));
    }

    public function test_member_of_to_side_is_unchecked_but_from_side_is_not(): void
    {
        // member_of: product -> (any collection namespace) — the to-side is unchecked
        self::assertTrue(Relations::validSignature('member_of', ['cnk', '1'], ['atc', 'A10']));
        // but the from-side must still be a product
        self::assertFalse(Relations::validSignature('member_of', ['text_id', 'D1'], ['atc', 'A10']));
    }

    public function test_unknown_relation_never_validates(): void
    {
        self::assertFalse(Relations::validSignature('likes', ['cnk', '1'], ['cas', '2']));
    }

    public function test_uuid_is_lane_neutral_on_either_endpoint(): void
    {
        // a uuid endpoint has no lane, so it satisfies any lane requirement
        self::assertTrue(Relations::validSignature('contains', ['uuid', 'x'], ['substance_id', 'PARA']));
        self::assertTrue(Relations::validSignature('contains', ['cnk', '1'], ['uuid', 'x']));
    }
}
