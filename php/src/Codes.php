<?php

declare(strict_types=1);

namespace GoldenRecord;

/**
 * Code normalization & validation. Ported from `Codes` in lib/golden_record_core.ex.
 *
 * The GTIN family (EAN-8 / UPC-12 / EAN-13 / GTIN-14) is ONE scheme at different widths:
 * canonicalize to a 14-digit, zero-filled GTIN so equal trade items compare equal.
 * Conservative — non-GTIN schemes and non-GTIN-length values pass through untouched.
 *
 * A code is a [scheme, value] pair (the Elixir {scheme, value} tuple; atoms -> strings).
 */
final class Codes
{
    private const GTIN_SCHEMES = ['gtin', 'ean', 'upc'];

    /** National short codes medipim zero-pads to a fixed width. :cnk is deliberately excluded. */
    private const PAD = [
        'cip_acl7' => 7,
        'pzn' => 8,
        'pzn_austria' => 7,
        'sukl' => 7,
        'cefip' => 7,
        'national_code' => 7,
        'cn' => 6,
    ];

    /**
     * Canonical [scheme, value] for matching. GTIN family -> ['gtin', 14-digit zero-filled].
     *
     * @param array{0: string, 1: string} $code
     * @return array{0: string, 1: string}
     */
    public static function canonicalize(array $code): array
    {
        [$scheme, $value] = $code;
        $v = trim($value);

        if (in_array($scheme, self::GTIN_SCHEMES, true)) {
            return self::gtinish($v) ? ['gtin', str_pad($v, 14, '0', STR_PAD_LEFT)] : [$scheme, $v];
        }

        if (isset(self::PAD[$scheme])) {
            $width = self::PAD[$scheme];

            return self::allDigits($v) && strlen($v) < $width
                ? [$scheme, str_pad($v, $width, '0', STR_PAD_LEFT)]
                : [$scheme, $v];
        }

        return [$scheme, $v];
    }

    /** Do two codes denote the same thing once canonicalized? */
    public static function same(array $a, array $b): bool
    {
        return self::canonicalize($a) === self::canonicalize($b);
    }

    /** Mod-10 check-digit validity for a GTIN-family code. */
    public static function validGtin(array $code): bool
    {
        [$scheme, $v] = self::canonicalize($code);

        if ($scheme === 'gtin' && strlen($v) === 14) {
            return substr($v, -1) === (string) self::checkDigit(substr($v, 0, 13));
        }

        return false;
    }

    /** GTIN-14 indicator digit: 0 = base unit, 1-8 = packaging levels, 9 = variable measure. */
    public static function indicator(array $code): ?int
    {
        [$scheme, $v] = self::canonicalize($code);

        if ($scheme === 'gtin' && strlen($v) === 14) {
            return (int) $v[0];
        }

        return null;
    }

    /** Restricted-distribution / in-store GTIN (GS1 prefix 02 or 20-29) — NOT globally unique. */
    public static function restricted(array $code): bool
    {
        [$scheme, $v] = self::canonicalize($code);

        if ($scheme === 'gtin' && strlen($v) === 14) {
            $prefix = substr($v, 1, 2);

            return $prefix === '02' || ($prefix >= '20' && $prefix <= '29');
        }

        return false;
    }

    /**
     * The set key for a code: "scheme\x1fvalue". A MapSet of codes is an assoc array keyed by this.
     * The 0x1f unit separator can never appear in a scheme or value, so the join is unambiguous.
     *
     * @param array{0: string, 1: string} $code
     */
    public static function key(array $code): string
    {
        return $code[0]."\x1f".$code[1];
    }

    private static function gtinish(string $v): bool
    {
        return preg_match('/^\d+$/', $v) === 1 && in_array(strlen($v), [8, 12, 13, 14], true);
    }

    private static function allDigits(string $v): bool
    {
        return $v !== '' && preg_match('/^\d+$/', $v) === 1;
    }

    private static function checkDigit(string $payload): int
    {
        $digits = array_reverse(array_map('intval', str_split($payload)));
        $sum = 0;
        foreach ($digits as $i => $d) {
            $sum += $d * ($i % 2 === 0 ? 3 : 1);
        }

        return (10 - $sum % 10) % 10;
    }
}
