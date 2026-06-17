<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Codes;
use PHPUnit\Framework\TestCase;

/**
 * Ported from test/golden_record_test.exs (the "Codes" describe block).
 * An Elixir {scheme, value} tuple becomes a PHP [scheme, value] pair (atoms -> strings).
 */
final class CodesTest extends TestCase
{
    public function test_canonicalizes_ean13_to_padded_gtin14(): void
    {
        self::assertSame(['gtin', '05012345678900'], Codes::canonicalize(['ean', '5012345678900']));
    }

    public function test_upc_and_ean_of_same_item_are_equal(): void
    {
        self::assertTrue(Codes::same(['upc', '036000291452'], ['ean', '0036000291452']));
    }

    public function test_ean8_canonicalizes_to_gtin14(): void
    {
        self::assertSame(['gtin', '00000096385074'], Codes::canonicalize(['ean', '96385074']));
        self::assertTrue(Codes::same(['gtin', '96385074'], ['gtin', '000096385074']));
    }

    public function test_upc12_canonicalizes_to_gtin14(): void
    {
        self::assertSame(['gtin', '00036000291452'], Codes::canonicalize(['upc', '036000291452']));
    }

    public function test_non_gtin_scheme_passes_through(): void
    {
        self::assertSame(['cnk', '3216547'], Codes::canonicalize(['cnk', '3216547']));
    }

    public function test_gtin_scheme_but_non_gtin_length_passes_through(): void
    {
        self::assertSame(['gtin', '0111'], Codes::canonicalize(['gtin', '0111']));
    }

    public function test_pads_national_short_codes_to_scheme_width(): void
    {
        self::assertSame(['cip_acl7', '0044813'], Codes::canonicalize(['cip_acl7', '44813']));
        self::assertSame(['pzn', '00012345'], Codes::canonicalize(['pzn', '12345']));
        self::assertSame(['cn', '001234'], Codes::canonicalize(['cn', '1234']));
    }

    public function test_full_width_national_code_is_unchanged(): void
    {
        self::assertSame(['cip_acl7', '4440813'], Codes::canonicalize(['cip_acl7', '4440813']));
    }

    public function test_non_numeric_national_code_passes_through(): void
    {
        self::assertSame(['cip_acl7', 'AB'], Codes::canonicalize(['cip_acl7', 'AB']));
    }

    public function test_cnk_is_never_padded(): void
    {
        self::assertSame(['cnk', '111'], Codes::canonicalize(['cnk', '111']));
        self::assertSame(['cnk', '0111'], Codes::canonicalize(['cnk', '0111']));
    }

    public function test_valid_gtin_check_digit(): void
    {
        self::assertTrue(Codes::validGtin(['ean', '4006381333931']));
        self::assertTrue(Codes::validGtin(['ean', '96385074']));
        self::assertTrue(Codes::validGtin(['gtin', '15012345678907']));
        self::assertTrue(Codes::validGtin(['ean', '4057598014359']));
        self::assertTrue(Codes::validGtin(['gtin', '24057598014353']));
    }

    public function test_invalid_gtin_check_digit(): void
    {
        self::assertFalse(Codes::validGtin(['ean', '4006381333930']));
    }

    public function test_indicator_digit(): void
    {
        self::assertSame(0, Codes::indicator(['ean', '5012345678900']));
        self::assertSame(1, Codes::indicator(['gtin', '15012345678907']));
        self::assertSame(0, Codes::indicator(['ean', '4057598014359']));
        self::assertSame(2, Codes::indicator(['gtin', '24057598014353']));
    }

    public function test_restricted_distribution_gtin(): void
    {
        self::assertTrue(Codes::restricted(['gtin', '2012345678905']));
        self::assertFalse(Codes::restricted(['ean', '5012345678900']));
    }

    public function test_packaging_levels_are_distinct_items(): void
    {
        self::assertFalse(Codes::same(['ean', '4057598014359'], ['gtin', '24057598014353']));
        self::assertSame(['gtin', '04057598014359'], Codes::canonicalize(['ean', '4057598014359']));
    }
}
