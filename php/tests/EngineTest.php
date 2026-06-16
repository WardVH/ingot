<?php

declare(strict_types=1);

namespace GoldenRecord\Tests;

use GoldenRecord\Catalog;
use GoldenRecord\Cluster;
use GoldenRecord\Events;
use GoldenRecord\IdentityLedger;
use GoldenRecord\LedgerState;
use GoldenRecord\Priority;
use GoldenRecord\PublicId;
use GoldenRecord\Substrate;
use GoldenRecord\Survivorship;
use GoldenRecord\Sets;
use PHPUnit\Framework\TestCase;

/**
 * Ported from the EngineTest describe blocks in golden_record_test.exs — the contract of the pure
 * engine: clustering, survivorship, code collisions, the steward merge gate, shared codes, and the
 * customer API's resolve/canonical paths. Dates are plain strings here (the engine never compares
 * them on this path — Catalog::project is Date-free).
 */
final class EngineTest extends TestCase
{
    private Priority $priority;

    protected function setUp(): void
    {
        $this->priority = Priority::new(
            [
                'weight_g' => [['manufacturer'], ['supplier'], ['marketplace']],
                'color' => [['supplier', 'manufacturer', 'marketplace']],
                'product' => [['manufacturer'], ['supplier'], ['marketplace']],
                'cnk' => [['manufacturer'], ['supplier']],
            ],
            [['manufacturer'], ['supplier'], ['marketplace']],
        );
    }

    /**
     * @param list<array<string,mixed>> $events
     * @return array{0: list<array<string,mixed>>, 1: int}
     */
    private function stamp(array $events, int $start): array
    {
        $out = [];
        $i = $start;
        foreach ($events as $e) {
            $e['order'] = $i;
            $out[] = $e;
            ++$i;
        }

        return [$out, $i];
    }

    /**
     * @param list<array<string,mixed>> $events
     */
    private function fold(array $events, LedgerState $state): LedgerState
    {
        foreach ($events as $e) {
            $state = IdentityLedger::evolve($state, $e);
        }

        return $state;
    }

    /**
     * @param list<array<string,mixed>> $claims
     * @return list<array<string, array{0: string, 1: string}>>
     */
    private function clusters(array $claims, array $shared = []): array
    {
        return Cluster::variants(Substrate::current($claims), $shared);
    }

    /**
     * Single resolution pass -> [log, ledger].
     *
     * @param list<array<string,mixed>> $claims
     * @return array{0: list<array<string,mixed>>, 1: LedgerState}
     */
    private function resolve(array $claims, string $at = 'd1'): array
    {
        [$c, $o] = $this->stamp($claims, 1);
        $res = IdentityLedger::decide(IdentityLedger::new(), ['reconcile', $this->clusters($c), $at]);
        [$res] = $this->stamp($res, $o);

        return [array_merge($c, $res), $this->fold($res, IdentityLedger::new())];
    }

    /** @return array<string,mixed> a claim assoc array */
    private function claim(string $source, string $kind, array $data, string $vf = 'd1', string $at = 'd1'): array
    {
        return Substrate::claim($source, $kind, $data, $vf, $at);
    }

    /**
     * @param list<array<string,mixed>> $log
     * @return list<array<string,mixed>> variants across all products
     */
    private function nowVariants(array $log): array
    {
        $records = $this->project($log);
        $variants = [];
        foreach ($records as $r) {
            foreach ($r['variants'] as $v) {
                $variants[] = $v;
            }
        }

        return $variants;
    }

    /**
     * @param list<array<string,mixed>> $log
     * @return list<array<string,mixed>>
     */
    private function project(array $log): array
    {
        $claims = array_values(array_filter($log, static fn (array $e): bool => ($e['type'] ?? null) === Events::TYPE_CLAIM_ASSERTED));
        $members = $this->fold($log, IdentityLedger::new())->members;

        return Catalog::project($members, Substrate::current($claims), $this->priority, ['attr' => [], 'product' => []]);
    }

    private function findVariant(array $variants, array $code): ?array
    {
        foreach ($variants as $v) {
            foreach ($v['codes'] as $c) {
                if ($c === $code) {
                    return $v;
                }
            }
        }

        return null;
    }

    private function attr(array $variant, string $field): array
    {
        foreach ($variant['attributes'] as [$f, $d]) {
            if ($f === $field) {
                return $d;
            }
        }
        self::fail("no attribute $field");
    }

    // ── identity resolution ──────────────────────────────────────────────────────

    public function test_two_sources_sharing_a_code_merge_into_one_variant(): void
    {
        [$log] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0111'], ['upc', '9111']]]),
            $this->claim('manufacturer', 'identity', ['ref' => 'B', 'codes' => [['gtin', '0111']]]),
        ]);

        $variants = $this->nowVariants($log);
        self::assertCount(1, $variants);
        self::assertContains(['gtin', '0111'], $variants[0]['codes']);
        self::assertContains(['upc', '9111'], $variants[0]['codes']);
    }

    public function test_equivalent_ean_gtin_resolve_to_one_variant(): void
    {
        [$log] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['ean', '5012345678900']]]),
            $this->claim('manufacturer', 'identity', ['ref' => 'B', 'codes' => [['gtin', '05012345678900']]]),
        ]);

        $variants = $this->nowVariants($log);
        self::assertCount(1, $variants);
        self::assertSame([['gtin', '05012345678900']], $variants[0]['codes']);
    }

    // ── survivorship ──────────────────────────────────────────────────────────────

    public function test_highest_priority_source_wins(): void
    {
        [$log] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0111']]]),
            $this->claim('supplier', 'attribute', ['code' => ['gtin', '0111'], 'field' => 'weight_g', 'value' => 260]),
            $this->claim('manufacturer', 'attribute', ['code' => ['gtin', '0111'], 'field' => 'weight_g', 'value' => 255]),
        ]);

        $d = $this->attr($this->findVariant($this->nowVariants($log), ['gtin', '0111']), 'weight_g');
        self::assertSame(255, $d['value']);
        self::assertSame('manufacturer', $d['winner']);
        self::assertSame('resolved', $d['status']);
    }

    public function test_three_way_tie_is_needs_review(): void
    {
        [$log] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0555']]]),
            $this->claim('supplier', 'attribute', ['code' => ['gtin', '0555'], 'field' => 'color', 'value' => 'red']),
            $this->claim('manufacturer', 'attribute', ['code' => ['gtin', '0555'], 'field' => 'color', 'value' => 'blue']),
            $this->claim('marketplace', 'attribute', ['code' => ['gtin', '0555'], 'field' => 'color', 'value' => 'green']),
        ]);

        $d = $this->attr($this->findVariant($this->nowVariants($log), ['gtin', '0555']), 'color');
        self::assertSame('needs_review', $d['status']);
        self::assertCount(3, $d['candidates']);
    }

    // ── code collisions ───────────────────────────────────────────────────────────

    public function test_grouping_pointing_at_two_products_is_contested(): void
    {
        $claims = [
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0777']]]),
            $this->claim('supplier', 'grouping', ['code' => ['gtin', '0777'], 'product' => ['mpn', 'ALPHA']]),
            $this->claim('manufacturer', 'grouping', ['code' => ['gtin', '0777'], 'product' => ['mpn', 'BETA']]),
        ];

        [$log] = $this->resolve($claims);
        $variant = $this->findVariant($this->nowVariants($log), ['gtin', '0777']);
        self::assertSame('needs_review', $variant['product']['status']);
    }

    // ── the steward merge gate ──────────────────────────────────────────────────

    public function test_bridge_across_established_keys_is_proposed_not_merged(): void
    {
        [$c1, $o] = $this->stamp([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0111']]]),
            $this->claim('supplier', 'identity', ['ref' => 'B', 'codes' => [['gtin', '0222']]]),
        ], 1);

        $res1 = IdentityLedger::decide(IdentityLedger::new(), ['reconcile', $this->clusters($c1), 'd1']);
        [$res1, $o] = $this->stamp($res1, $o);
        $ledger1 = $this->fold($res1, IdentityLedger::new());

        [$c2] = $this->stamp([
            $this->claim('scraper', 'identity', ['ref' => 'X', 'codes' => [['gtin', '0111'], ['gtin', '0222']]], 'd2', 'd2'),
        ], $o);

        $res2 = IdentityLedger::decide($ledger1, ['reconcile', $this->clusters(array_merge($c1, $c2)), 'd2']);
        $ledger2 = $this->fold($res2, $ledger1);

        $hasMergeFlag = false;
        foreach ($res2 as $e) {
            if ($e['type'] === Events::TYPE_CONFLICT_FLAGGED && ($e['subject'][0] ?? null) === 'merge') {
                $hasMergeFlag = true;
            }
        }
        self::assertTrue($hasMergeFlag);
        self::assertCount(2, $ledger2->members, 'merge must NOT be applied automatically');
    }

    // ── shared codes ──────────────────────────────────────────────────────────────

    public function test_marking_code_shared_splits_a_wrong_merge(): void
    {
        $claims = [
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '7777'], ['gtin', '1000']]]),
            $this->claim('manufacturer', 'identity', ['ref' => 'B', 'codes' => [['gtin', '7777'], ['gtin', '2000']]]),
        ];

        [$c, $o] = $this->stamp($claims, 1);
        $res1 = IdentityLedger::decide(IdentityLedger::new(), ['reconcile', $this->clusters($c), 'd1']);
        [$res1] = $this->stamp($res1, $o);
        $ledger1 = $this->fold($res1, IdentityLedger::new());
        self::assertCount(1, $ledger1->members, 'without the share, 7777 wrongly bridges them');

        $shared = Sets::of([['gtin', '7777']]);
        $res2 = IdentityLedger::decide($ledger1, ['reconcile', Cluster::variants(Substrate::current($c), $shared), $shared, 'd2']);
        $ledger2 = $this->fold($res2, $ledger1);

        self::assertCount(2, $ledger2->members);
        foreach ($ledger2->members as $codes) {
            self::assertTrue(Sets::member($codes, ['gtin', '7777']));
        }
    }

    // ── customer API ────────────────────────────────────────────────────────────

    public function test_cnk_canonical_by_priority_with_alias(): void
    {
        [$log] = $this->resolve([
            $this->claim('manufacturer', 'identity', ['ref' => 'A', 'codes' => [['cnk', '0111'], ['gtin', '5001']]]),
            $this->claim('supplier', 'identity', ['ref' => 'B', 'codes' => [['cnk', '0222'], ['gtin', '5001']]]),
        ]);

        // resolve the key owning gtin:5001
        $ledger = $this->fold($log, IdentityLedger::new());
        $key = null;
        foreach ($ledger->members as $k => $codes) {
            if (Sets::member($codes, ['gtin', '5001'])) {
                $key = $k;
            }
        }
        self::assertNotNull($key);

        $result = PublicId::canonical('cnk', $key, $log, $this->priority);
        self::assertSame(['cnk', '0111'], $result['canonical'], 'manufacturer outranks supplier for cnk');
        self::assertSame([['cnk', '0222']], $result['aliases']);
    }

    public function test_no_cnk_collision_in_normal_case(): void
    {
        [$log] = $this->resolve([
            $this->claim('manufacturer', 'identity', ['ref' => 'A', 'codes' => [['cnk', '0111']]]),
        ]);
        self::assertSame([], PublicId::collisions('cnk', $log));
    }
}
