<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Engine-minted identity — ported from `Uuid` in lib/golden_record_core.ex.
 *
 * A record born without a source code gets a `['uuid', v4]` identity code. The scheme is shared
 * across lanes (lane-neutral), so such a claim must carry an explicit `entity` (see Lanes::ofClaim).
 * Not on the 422156 fold path — every 422156 record has source codes — but provided for fidelity.
 */
final class Uuid
{
    /** @return array{0: string, 1: string} */
    public static function mint(): array
    {
        return ['uuid', self::v4()];
    }

    public static function v4(): string
    {
        $bytes = random_bytes(16);
        $bytes[6] = chr((ord($bytes[6]) & 0x0F) | 0x40);
        $bytes[8] = chr((ord($bytes[8]) & 0x3F) | 0x80);

        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($bytes), 4));
    }
}
