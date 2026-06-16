<?php

declare(strict_types=1);

namespace GoldenRecord;

/**
 * Identity-grade public ids (CNK) — ported from `PublicId` in lib/golden_record_core.ex.
 *
 * The surrogate key is internal; CNK is the public key — strictly unique, never shared. Two
 * sources giving different CNKs for one product become canonical + alias(es) on one key (canonical
 * chosen by source priority). `collisions` is the hard invariant: a code of a scheme must never own
 * more than one key.
 */
final class PublicId
{
    /**
     * Canonical public id of `scheme` for `key` (by source priority), plus its aliases, or null.
     *
     * @param list<array<string,mixed>> $log
     * @return array{canonical: array{0: string, 1: string}, aliases: list<array{0: string, 1: string}>}|null
     */
    public static function canonical(string $scheme, string $key, array $log, Priority $priority): ?array
    {
        $members = self::ledger($log)->members[$key] ?? [];
        $codes = [];
        foreach (Sets::values($members) as $code) {
            if ($code[0] === $scheme) {
                $codes[] = $code;
            }
        }

        if ($codes === []) {
            return null;
        }

        $idclaims = self::identityClaims($log);

        $entries = [];
        foreach ($codes as $code) {
            foreach (self::sourcesOf($code, $idclaims) as $src) {
                $entries[] = ['source' => $src, 'value' => $code, 'order' => 0];
            }
        }

        $winner = $entries === []
            ? $codes[0]
            : Survivorship::decide($scheme, $entries, $priority)['value'];

        $aliases = [];
        foreach ($codes as $code) {
            if ($code !== $winner) {
                $aliases[] = $code;
            }
        }

        return ['canonical' => $winner, 'aliases' => $aliases];
    }

    /**
     * Identity-grade invariant check: a code of `scheme` must never own >1 key. Returns violations.
     *
     * @param list<array<string,mixed>> $log
     * @return list<array{code: array{0: string, 1: string}, keys: list<string>}>
     */
    public static function collisions(string $scheme, array $log): array
    {
        $members = self::ledger($log)->members;

        /** @var array<string, array{code: array{0: string, 1: string}, keys: array<string,true>}> $byCode */
        $byCode = [];
        $codeOrder = [];
        foreach ($members as $k => $codes) {
            foreach (Sets::values($codes) as $c) {
                if ($c[0] !== $scheme) {
                    continue;
                }
                $ck = Codes::key($c);
                if (!isset($byCode[$ck])) {
                    $byCode[$ck] = ['code' => $c, 'keys' => []];
                    $codeOrder[] = $ck;
                }
                $byCode[$ck]['keys'][$k] = true;
            }
        }

        $out = [];
        foreach ($codeOrder as $ck) {
            $keys = array_keys($byCode[$ck]['keys']);
            if (count($keys) > 1) {
                sort($keys, SORT_STRING);
                $out[] = ['code' => $byCode[$ck]['code'], 'keys' => $keys];
            }
        }

        return $out;
    }

    /**
     * @param array{0: string, 1: string} $code
     * @param list<array<string,mixed>> $idclaims
     * @return list<string>
     */
    private static function sourcesOf(array $code, array $idclaims): array
    {
        $out = [];
        foreach ($idclaims as $c) {
            foreach ($c['data']['codes'] as $cc) {
                if ($cc === $code) {
                    $out[] = $c['source'];
                    break;
                }
            }
        }

        return $out;
    }

    /**
     * @param list<array<string,mixed>> $log
     * @return list<array<string,mixed>>
     */
    private static function identityClaims(array $log): array
    {
        $claims = [];
        foreach ($log as $e) {
            if (($e['type'] ?? null) === Events::TYPE_CLAIM_ASSERTED && $e['kind'] === 'identity') {
                $claims[] = $e;
            }
        }

        return Substrate::current($claims);
    }

    /**
     * @param list<array<string,mixed>> $log
     */
    private static function ledger(array $log): LedgerState
    {
        $state = IdentityLedger::new();
        foreach ($log as $e) {
            $state = IdentityLedger::evolve($state, $e);
        }

        return $state;
    }
}
