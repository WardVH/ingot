<?php

declare(strict_types=1);

namespace GoldenRecord;

/**
 * The single source of medipim product-code knowledge — ported from `CodeRegistry`
 * (lib/ingest/code_registry.ex). Maps each medipim field to {engine scheme, classification}, and
 * provides the bridge-grade axis the over-merge guard uses (national vs barcode vs none).
 */
final class CodeRegistry
{
    /** medipim field name => [engine scheme, classification]. */
    private const REGISTRY = [
        'cnk' => ['cnk', 'identity'],
        'cipOrAcl7' => ['cip_acl7', 'identity'],
        'acl13' => ['acl13', 'identity'],
        'cip13' => ['cip13', 'identity'],
        'pzn' => ['pzn', 'identity'],
        'pznAustria' => ['pzn_austria', 'identity'],
        'sukl' => ['sukl', 'identity'],
        'pdk' => ['pdk', 'identity'],
        'cn' => ['cn', 'identity'],
        'cefip' => ['cefip', 'identity'],
        'nationalCode' => ['national_code', 'identity'],
        'ndc' => ['ndc', 'identity'],
        'hri' => ['hri', 'identity'],
        'pin' => ['pin', 'identity'],
        'fred' => ['fred', 'identity'],
        'zcode' => ['zcode', 'identity'],
        'lppr' => ['lppr', 'identity'],
        'ean' => ['gtin', 'identity'],
        'gtin' => ['gtin', 'identity'],
        'eanGtin8' => ['gtin', 'identity'],
        'eanGtin12' => ['gtin', 'identity'],
        'eanGtin13' => ['gtin', 'identity'],
        'eanGtin14' => ['gtin', 'identity'],
        'undefinedEanGtinCode' => ['gtin', 'identity'],
        'usaGtinCode' => ['gtin', 'identity'],
        'upc10' => ['gtin', 'identity'],
        'upc11' => ['gtin', 'identity'],
        'upc12' => ['gtin', 'identity'],
        'cbId' => ['cb_id', 'external_ref'],
        'ospId' => ['osp_id', 'external_ref'],
        'offisanteId' => ['offisante_id', 'external_ref'],
        'cisCode' => ['cis_code', 'external_ref'],
        'publicPageIdentifier' => ['public_page_identifier', 'external_ref'],
        'isbn13' => ['isbn13', 'identity'],
        'isbn10' => ['isbn10', 'identity'],
        'productId' => ['product_id', 'entity_id'],
        'hsCode' => ['hs_code', 'attribute'],
        'pbs' => ['pbs', 'attribute'],
    ];

    private const DEFAULT_CLASSIFICATION = 'attribute';

    /** Engine-native scheme names not derived from a medipim field. */
    private const EXTRA_ENGINE_SCHEMES = [
        'mpn' => 'mpn',
        'supplier_ref' => 'supplier_ref',
        'ean' => 'ean',
        'upc' => 'upc',
        'cas' => 'cas',
        'unii' => 'unii',
        'substance_id' => 'substance_id',
        'text_id' => 'text_id',
        'asset_id' => 'asset_id',
        'uuid' => 'uuid',
    ];

    private const NATIONAL_SCHEMES = [
        'cnk', 'cip_acl7', 'cefip', 'pzn', 'pzn_austria', 'sukl', 'national_code', 'cn',
        'pdk', 'ndc', 'hri', 'pin', 'lppr', 'fred', 'zcode', 'isbn13', 'isbn10',
    ];

    private const BARCODE_SCHEMES = ['gtin', 'acl13', 'cip13'];

    /** Engine scheme for a medipim field; unknown fields stay their raw string. */
    public static function scheme(string $field): string
    {
        return self::REGISTRY[$field][0] ?? $field;
    }

    /** Engine scheme for an engine-native scheme NAME ("cnk" => 'cnk'); unknown names pass through. */
    public static function engineScheme(string $name): string
    {
        if (isset(self::EXTRA_ENGINE_SCHEMES[$name])) {
            return self::EXTRA_ENGINE_SCHEMES[$name];
        }
        foreach (self::REGISTRY as [$scheme, $_class]) {
            if ($scheme === $name) {
                return $scheme;
            }
        }

        return $name;
    }

    /** Classification for a medipim field. */
    public static function classification(string $field): string
    {
        return self::REGISTRY[$field][1] ?? self::DEFAULT_CLASSIFICATION;
    }

    /** Bridge grade of an engine scheme: 'national' | 'barcode' | 'none'. */
    public static function bridgeGrade(string $scheme): string
    {
        if (in_array($scheme, self::NATIONAL_SCHEMES, true)) {
            return 'national';
        }
        if (in_array($scheme, self::BARCODE_SCHEMES, true)) {
            return 'barcode';
        }

        return 'none';
    }

    public static function nationalGrade(string $scheme): bool
    {
        return self::bridgeGrade($scheme) === 'national';
    }

    public static function barcodeGrade(string $scheme): bool
    {
        return self::bridgeGrade($scheme) === 'barcode';
    }
}
