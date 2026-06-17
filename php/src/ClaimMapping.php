<?php

declare(strict_types=1);

namespace GoldenRecord;

/**
 * The medipim reference adapter — ported from `ClaimMapping` (lib/ingest/claim_mapping.ex).
 *
 * Folds contract-C HistoryEnvelopes into canonical claims (`canonicalClaims`) and composes them
 * into engine claims plus the `shared` code set (`build`). Per listing = (legacy_entity, source):
 * replay identity events into a final code-set, canonicalize/partition, then synthesize identity /
 * grouping / attribute / member_of claims, plus first-class lane records (media + descriptions) tied
 * back by depicts/describes edges. Claims are stamped with a chronological `order`.
 */
final class ClaimMapping
{
    /** National short codes, in anchor preference order. */
    private const NATIONAL_PRIMARY = ['cnk', 'cip_acl7', 'cefip', 'pzn', 'sukl', 'pzn_austria', 'national_code', 'cn'];

    private const NON_BRIDGING_SCHEMES = ['mpn', 'supplier_ref'];

    /** medipim edge collections that reference first-class entities. collection => [scheme, lane, relation]. */
    private const LANE_COLLECTIONS = [
        'descriptions' => ['text_id', 'description', 'describes'],
        'media' => ['asset_id', 'media', 'depicts'],
    ];

    /**
     * Map envelopes to ['claims' => [ClaimAsserted...], 'shared' => code-set].
     *
     * @param list<array<string,mixed>> $envelopes
     * @return array{claims: list<array<string,mixed>>, shared: array<string, array{0: string, 1: string}>}
     */
    public static function build(array $envelopes): array
    {
        $folded = self::foldRaw($envelopes);

        $canonical = self::canonical($envelopes, $folded);
        $claims = self::stamp(CanonicalClaims::toEngineBang($canonical));
        $shared = self::sharedCodes(self::listingCodes($folded));

        return ['claims' => $claims, 'shared' => $shared];
    }

    /**
     * Stage (a): the canonical claims (wire-shaped maps) in emission order.
     *
     * @param list<array<string,mixed>> $envelopes
     * @return list<array<string,mixed>>
     */
    public static function canonicalClaims(array $envelopes): array
    {
        return self::canonical($envelopes, self::foldRaw($envelopes));
    }

    /**
     * Just the folded, canonicalized code-set per listing — keyed "entity\x1fsource".
     *
     * @param list<array<string,mixed>> $envelopes
     * @return array<string, array<string, array{0: string, 1: string}>>
     */
    public static function listings(array $envelopes): array
    {
        return self::listingCodes(self::foldRaw($envelopes));
    }

    /**
     * @param list<array<string,mixed>> $envelopes
     * @param array<string, array{raw: array<string, array<string,true>>, last_at: int}> $folded
     * @return list<array<string,mixed>>
     */
    private static function canonical(array $envelopes, array $folded): array
    {
        $listingCodes = self::listingCodes($folded); // key => code-set
        $entityCodes = self::unionByEntity($listingCodes); // entity => code-set

        // primary code per listing / per entity.
        $listingPrimary = [];
        foreach ($listingCodes as $k => $set) {
            $listingPrimary[$k] = self::primary(Sets::valuesSorted($set));
        }
        $entityPrimary = [];
        foreach ($entityCodes as $e => $set) {
            $entityPrimary[(string) $e] = self::primary(Sets::valuesSorted($set));
        }

        // Deterministic emission order: sort listings by their key.
        $orderedKeys = array_keys($listingCodes);
        sort($orderedKeys, SORT_STRING);

        $identity = [];
        $grouping = [];
        foreach ($orderedKeys as $key) {
            [$entity, $source] = self::splitKey($key);
            $set = $listingCodes[$key];
            $sortedCodes = Sets::valuesSorted($set);

            $identity[] = [
                'kind' => 'identity',
                'source' => $source,
                'ref' => $entity.':'.$source,
                'codes' => array_map(CanonicalClaims::codeString(...), $sortedCodes),
                'valid_from' => $folded[$key]['last_at'],
                'recorded_at' => $folded[$key]['last_at'],
            ];

            foreach ($sortedCodes as $code) {
                $grouping[] = [
                    'kind' => 'grouping',
                    'source' => $source,
                    'code' => CanonicalClaims::codeString($code),
                    'product' => self::entityValue($entity),
                    'valid_from' => $folded[$key]['last_at'],
                    'recorded_at' => $folded[$key]['last_at'],
                ];
            }
        }

        // anchor(entity, source): a sourced event anchors only to its OWN listing's primary; an
        // unsourced event falls back to the entity-level primary.
        $anchor = static function (mixed $entity, ?string $source) use ($listingPrimary, $entityPrimary): ?array {
            if ($source === null) {
                return $entityPrimary[(string) $entity] ?? null;
            }

            return $listingPrimary[self::makeKey($entity, $source)] ?? null;
        };

        $attribute = [];
        foreach ($envelopes as $env) {
            foreach ($env['events'] as $ev) {
                if ($ev['kind'] !== 'attribute') {
                    continue;
                }
                $a = $anchor($env['legacy_entity'], $ev['source']);
                if ($a === null) {
                    continue;
                }
                $attribute[] = [
                    'kind' => 'attribute',
                    'source' => $ev['source'],
                    'code' => CanonicalClaims::codeString($a),
                    'field' => self::fieldDim($ev),
                    'value' => $ev['data']['value'],
                    'valid_from' => $ev['valid_from'],
                    'recorded_at' => $ev['recorded_at'],
                ];
            }
        }

        $memberOf = [];
        foreach ($envelopes as $env) {
            foreach ($env['events'] as $ev) {
                if ($ev['kind'] !== 'edge') {
                    continue;
                }
                if (!in_array($ev['op'], ['set', 'add'], true)) {
                    continue;
                }
                if (($ev['data']['value'] ?? null) === null) {
                    continue;
                }
                if (isset(self::LANE_COLLECTIONS[$ev['data']['collection']])) {
                    continue;
                }
                $a = $anchor($env['legacy_entity'], $ev['source']);
                if ($a === null) {
                    continue;
                }
                $memberOf[] = [
                    'kind' => 'member_of',
                    'source' => $ev['source'],
                    'code' => CanonicalClaims::codeString($a),
                    'collection' => $ev['data']['collection'],
                    'member' => self::toStringValue($ev['data']['value']),
                    'valid_from' => $ev['valid_from'],
                    'recorded_at' => $ev['recorded_at'],
                ];
            }
        }

        $laneEntities = self::laneEntities($envelopes, $anchor);

        return array_merge($identity, $grouping, $attribute, $memberOf, $laneEntities);
    }

    /**
     * First-class lane records (media + descriptions): fold per (entity, source, collection), emit
     * an identity claim in the entity's lane + a typed edge back to the listing's anchor.
     *
     * @param list<array<string,mixed>> $envelopes
     * @param callable(mixed, ?string): ?array{0: string, 1: string} $anchor
     * @return list<array<string,mixed>>
     */
    private static function laneEntities(array $envelopes, callable $anchor): array
    {
        $refs = self::laneRefs($envelopes); // key "entity\x1fsource\x1fcollection" => {ids, last, entity, source, collection}

        $keys = array_keys($refs);
        sort($keys, SORT_STRING);

        $out = [];
        foreach ($keys as $key) {
            $ref = $refs[$key];
            [$scheme, $lane, $relation] = self::LANE_COLLECTIONS[$ref['collection']];

            $a = $anchor($ref['entity'], null);
            if ($a === null) {
                continue;
            }

            $ids = array_keys($ref['ids']);
            sort($ids, SORT_STRING);
            foreach ($ids as $id) {
                [$vf, $at] = $ref['last'][$id];
                $out[] = [
                    'kind' => 'identity',
                    'source' => $ref['source'],
                    'ref' => $ref['collection'].':'.$id,
                    'codes' => [$scheme.':'.$id],
                    'entity' => $lane,
                    'valid_from' => $vf ?? $at,
                    'recorded_at' => $at,
                ];
                $out[] = [
                    'kind' => 'edge',
                    'source' => $ref['source'],
                    'from' => $scheme.':'.$id,
                    'relation' => $relation,
                    'to' => CanonicalClaims::codeString($a),
                    'valid_from' => $vf ?? $at,
                    'recorded_at' => $at,
                ];
            }
        }

        return $out;
    }

    /**
     * Fold media events per (entity, source||source_system, collection): add/remove churn on the
     * asset id, so only surviving references remain.
     *
     * @param list<array<string,mixed>> $envelopes
     * @return array<string, array{ids: array<string,true>, last: array<string, array{0: mixed, 1: mixed}>, entity: mixed, source: string, collection: string}>
     */
    private static function laneRefs(array $envelopes): array
    {
        $acc = [];
        foreach ($envelopes as $env) {
            foreach ($env['events'] as $ev) {
                if ($ev['kind'] !== 'media') {
                    continue;
                }
                if (!isset(self::LANE_COLLECTIONS[$ev['data']['collection']])) {
                    continue;
                }
                $source = $ev['source'] ?? $env['source_system'];
                $key = self::makeKey($env['legacy_entity'], $source)."\x1f".$ev['data']['collection'];
                $id = self::toStringValue($ev['data']['asset']);

                if (!isset($acc[$key])) {
                    $acc[$key] = [
                        'ids' => [],
                        'last' => [],
                        'entity' => $env['legacy_entity'],
                        'source' => $source,
                        'collection' => $ev['data']['collection'],
                    ];
                }
                if ($ev['op'] === 'remove') {
                    unset($acc[$key]['ids'][$id]);
                } else {
                    $acc[$key]['ids'][$id] = true;
                }
                $acc[$key]['last'][$id] = [$ev['valid_from'], $ev['recorded_at']];
            }
        }

        return $acc;
    }

    // ── fold ────────────────────────────────────────────────────────────────────

    /**
     * Replay identity events into per-listing raw code-sets, keyed by medipim scheme name.
     *
     * @param list<array<string,mixed>> $envelopes
     * @return array<string, array{raw: array<string, array<string,true>>, last_at: int}>
     */
    private static function foldRaw(array $envelopes): array
    {
        $acc = [];
        foreach ($envelopes as $env) {
            foreach ($env['events'] as $ev) {
                if ($ev['kind'] !== 'identity') {
                    continue;
                }
                $key = self::makeKey($env['legacy_entity'], $ev['source']);
                if (!isset($acc[$key])) {
                    $acc[$key] = ['raw' => [], 'last_at' => 0];
                }
                $acc[$key]['raw'] = self::applyIdentity($acc[$key]['raw'], $ev);
                $acc[$key]['last_at'] = max($acc[$key]['last_at'], $ev['recorded_at']);
            }
        }

        return $acc;
    }

    /**
     * Apply one identity delta (set/add/remove/delete) to a raw code-set (scheme => set-of-values).
     *
     * @param array<string, array<string,true>> $raw
     * @param array<string,mixed> $ev
     * @return array<string, array<string,true>>
     */
    private static function applyIdentity(array $raw, array $ev): array
    {
        $scheme = $ev['data']['scheme'];
        $code = $ev['data']['code'] ?? null;

        switch ($ev['op']) {
            case 'set':
                if ($code === null) {
                    unset($raw[$scheme]);
                } else {
                    $raw[$scheme] = [(string) $code => true];
                }

                return $raw;
            case 'add':
                $raw[$scheme][(string) $code] = true;

                return $raw;
            case 'remove':
                if (isset($raw[$scheme])) {
                    unset($raw[$scheme][(string) $code]);
                    if ($raw[$scheme] === []) {
                        unset($raw[$scheme]);
                    }
                }

                return $raw;
            case 'delete':
                unset($raw[$scheme]);

                return $raw;
            default:
                return $raw;
        }
    }

    /**
     * raw (medipim scheme → values) → code-set of canonicalized engine codes.
     *
     * @param array<string, array<string,true>> $raw
     * @return array<string, array{0: string, 1: string}>
     */
    private static function engineCodes(array $raw): array
    {
        $set = [];
        foreach ($raw as $scheme => $values) {
            foreach (array_keys($values) as $v) {
                $code = Codes::canonicalize([CodeRegistry::scheme($scheme), (string) $v]);
                $set[Codes::key($code)] = $code;
            }
        }

        return $set;
    }

    /**
     * Per-listing canonicalized code-sets, with delisted (now-empty) listings dropped.
     *
     * @param array<string, array{raw: array<string, array<string,true>>, last_at: int}> $folded
     * @return array<string, array<string, array{0: string, 1: string}>>
     */
    private static function listingCodes(array $folded): array
    {
        $out = [];
        foreach ($folded as $key => $v) {
            $set = self::engineCodes($v['raw']);
            if ($set !== []) {
                $out[$key] = $set;
            }
        }

        return $out;
    }

    // ── helpers ──────────────────────────────────────────────────────────────────

    /**
     * @param array<string, array<string, array{0: string, 1: string}>> $listingCodes
     * @return array<string, array<string, array{0: string, 1: string}>> entity => code-set
     */
    private static function unionByEntity(array $listingCodes): array
    {
        $acc = [];
        foreach ($listingCodes as $key => $set) {
            [$entity] = self::splitKey($key);
            $acc[$entity] = isset($acc[$entity]) ? Sets::union($acc[$entity], $set) : $set;
        }

        return $acc;
    }

    /**
     * Primary anchor code: national short code ▸ non-restricted GTIN ▸ any GTIN ▸ acl13 ▸ cip13 ▸
     * lowest code.
     *
     * @param list<array{0: string, 1: string}> $codes already sorted by [scheme, value]
     * @return array{0: string, 1: string}|null
     */
    public static function primary(array $codes): ?array
    {
        if ($codes === []) {
            return null;
        }

        $national = self::nationalShort($codes);
        if ($national !== null) {
            return $national;
        }

        foreach ($codes as $c) {
            if ($c[0] === 'gtin' && !Codes::restricted($c)) {
                return $c;
            }
        }
        foreach ($codes as $c) {
            if ($c[0] === 'gtin') {
                return $c;
            }
        }
        foreach ($codes as $c) {
            if ($c[0] === 'acl13') {
                return $c;
            }
        }
        foreach ($codes as $c) {
            if ($c[0] === 'cip13') {
                return $c;
            }
        }

        $sorted = $codes;
        usort($sorted, Sets::compareCodes(...));

        return $sorted[0];
    }

    /**
     * @param list<array{0: string, 1: string}> $codes
     * @return array{0: string, 1: string}|null
     */
    private static function nationalShort(array $codes): ?array
    {
        foreach (self::NATIONAL_PRIMARY as $scheme) {
            foreach ($codes as $c) {
                if ($c[0] === $scheme) {
                    return $c;
                }
            }
        }

        return null;
    }

    /** @param array<string,mixed> $ev */
    public static function fieldDim(array $ev): string
    {
        $locale = $ev['data']['locale'] ?? null;

        return $locale === null ? $ev['data']['field'] : $ev['data']['field'].':'.$locale;
    }

    /**
     * @param array<string, array<string, array{0: string, 1: string}>> $listingCodes
     * @return array<string, array{0: string, 1: string}>
     */
    private static function sharedCodes(array $listingCodes): array
    {
        $out = [];
        foreach ($listingCodes as $set) {
            foreach (Sets::values($set) as $code) {
                if (self::isShared($code)) {
                    $out[Codes::key($code)] = $code;
                }
            }
        }

        return $out;
    }

    /** @param array{0: string, 1: string} $code */
    public static function isShared(array $code): bool
    {
        return Codes::restricted($code) || in_array($code[0], self::NON_BRIDGING_SCHEMES, true);
    }

    /**
     * Chronological order stamp: later recorded_at ⇒ higher order; stable on emission index.
     *
     * @param list<array<string,mixed>> $claims
     * @return list<array<string,mixed>>
     */
    private static function stamp(array $claims): array
    {
        $indexed = [];
        foreach ($claims as $i => $c) {
            $indexed[] = [$c['recorded_at'], $i, $c];
        }
        usort($indexed, static function (array $a, array $b): int {
            return [self::numeric($a[0]), $a[1]] <=> [self::numeric($b[0]), $b[1]];
        });

        $out = [];
        foreach ($indexed as $order => [$_at, $_i, $c]) {
            $c['order'] = $order;
            $out[] = $c;
        }

        return $out;
    }

    private static function numeric(mixed $v): int|float
    {
        return is_numeric($v) ? 0 + $v : 0;
    }

    private static function makeKey(mixed $entity, string $source): string
    {
        return self::entityKeyPart($entity)."\x1f".$source;
    }

    /** @return array{0: mixed, 1: string} */
    private static function splitKey(string $key): array
    {
        $parts = explode("\x1f", $key, 2);

        return [self::decodeEntity($parts[0]), $parts[1] ?? ''];
    }

    private static function entityKeyPart(mixed $entity): string
    {
        // Encode the entity scalar so an int 1 and string "1" can't collide in the key.
        return (is_int($entity) ? 'i:' : 's:').$entity;
    }

    private static function decodeEntity(string $part): mixed
    {
        if (str_starts_with($part, 'i:')) {
            return (int) substr($part, 2);
        }

        return substr($part, 2);
    }

    private static function entityValue(mixed $entity): mixed
    {
        return $entity;
    }

    /**
     * Mirror Elixir's `to_string/1` over the JSON-decoded values that appear as edge `value`s.
     * A list is an iolist/charlist: integers are bytes (codepoints), strings/lists concatenate.
     * Such a value is then canonicalized downstream (which trims it), e.g. `[9]` → "\t" → "".
     */
    private static function toStringValue(mixed $v): string
    {
        if (is_bool($v)) {
            return $v ? 'true' : 'false';
        }
        if (is_array($v)) {
            $out = '';
            foreach ($v as $part) {
                $out .= is_int($part) ? mb_chr($part, 'UTF-8') : self::toStringValue($part);
            }

            return $out;
        }

        return (string) $v;
    }
}
