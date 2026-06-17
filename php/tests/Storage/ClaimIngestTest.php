<?php

declare(strict_types=1);

namespace Ingot\Tests\Storage;

use Ingot\Api;
use Ingot\Codes;
use Ingot\Storage\ClaimIngest;
use Ingot\Storage\InMemoryClaimStore;
use Ingot\Storage\Schema;
use PHPUnit\Framework\TestCase;

/**
 * The persistent writer over the in-memory {@see ClaimStore}: backfill mints + resolves the same
 * keys the from-zero fold does, the appended log is a valid engine log, and both paths are
 * idempotent (backfill per envelope, live per slot).
 */
final class ClaimIngestTest extends TestCase
{
    private const FIXTURE = __DIR__.'/../../../test/ingest/fixtures/medipim_be_422156.json';

    private static function cnkKey(): string
    {
        return Codes::key(Codes::canonicalize(['cnk', '3612173']));
    }

    /** The raw envelope MAP (as the decoder / fixture emits it); ClaimIngest loads it internally. */
    private static function rawEnvelope(): array
    {
        return json_decode(file_get_contents(self::FIXTURE), true, 512, JSON_THROW_ON_ERROR);
    }

    public function test_backfill_mints_sk1_and_resolves_the_cnk(): void
    {
        $store = new InMemoryClaimStore();
        $env = self::rawEnvelope();

        $summary = ClaimIngest::backfill($store, [$env]);

        self::assertSame(1, $summary['accepted']);
        self::assertGreaterThan(0, $summary['appended']);

        self::assertSame('SK_1', $store->resolveKey(self::cnkKey()));
        $loaded = $store->loadKeys(['SK_1']);
        self::assertArrayHasKey('SK_1', $loaded);
        self::assertArrayHasKey(self::cnkKey(), $loaded['SK_1']['codes']);
    }

    public function test_appended_log_is_a_valid_engine_log(): void
    {
        $store = new InMemoryClaimStore();
        ClaimIngest::backfill($store, [self::rawEnvelope()]);

        // Folding the appended log from zero via the read-side Api resolves the product to SK_1.
        self::assertSame('SK_1', Api::resolveKey($store->log(), ['cnk', '3612173']));
    }

    public function test_backfill_is_idempotent_per_envelope(): void
    {
        $store = new InMemoryClaimStore();
        $env = self::rawEnvelope();

        ClaimIngest::backfill($store, [$env]);
        $afterFirst = $store->maxSeq();

        $second = ClaimIngest::backfill($store, [$env]);
        self::assertSame(0, $second['accepted']);
        self::assertSame(1, $second['skipped']);
        self::assertSame(0, $second['appended']);
        self::assertSame($afterFirst, $store->maxSeq(), 'a replayed envelope must append nothing');
    }

    public function test_live_is_idempotent_per_slot(): void
    {
        $store = new InMemoryClaimStore();
        $env = self::rawEnvelope();

        $first = ClaimIngest::live($store, [$env]);
        self::assertGreaterThan(0, $first['appended']);
        $afterFirst = $store->maxSeq();

        $second = ClaimIngest::live($store, [$env]);
        self::assertSame(0, $second['appended'], 'an unchanged live write must be a no-op');
        self::assertSame($afterFirst, $store->maxSeq());

        self::assertSame('SK_1', $store->resolveKey(self::cnkKey()));
    }

    public function test_schema_statements_apply_the_prefix(): void
    {
        $statements = Schema::statements('gr_');
        self::assertCount(6, $statements);

        $all = implode("\n", $statements);
        self::assertStringContainsString('`gr_events`', $all);
        self::assertStringContainsString('`gr_snapshots`', $all);
        self::assertStringContainsString('`gr_members`', $all);
        self::assertStringContainsString('`gr_redirects`', $all);
        self::assertStringContainsString('`gr_lane_seq`', $all);
        self::assertStringContainsString('`gr_backfill_seen`', $all);
    }
}
