<?php

declare(strict_types=1);

namespace Ingot\Storage;

/**
 * The reference {@see ClaimStore} — an in-memory adapter used by the package's tests and as the
 * executable spec a DBAL adapter must match. No locking is needed (single process, single thread):
 * {@see transactionally} just runs the closure.
 */
final class InMemoryClaimStore implements ClaimStore
{
    /** @var list<array<string,mixed>> */
    private array $events = [];

    /** @var array<string, array{lane: string, codes: array<string, array{0:string,1:string}>, claims: list<array<string,mixed>>, last_seq: int}> */
    private array $snapshots = [];

    /** @var array<string, array{key: string, lane: string}> code => placement */
    private array $members = [];

    /** @var array<string, array{new_key: string, at: mixed}> */
    private array $redirects = [];

    /** @var array<string, int> */
    private array $laneSeq = [];

    /** @var array<string, true> */
    private array $backfillSeen = [];

    public function transactionally(callable $fn): mixed
    {
        return $fn();
    }

    public function maxSeq(): int
    {
        $max = 0;
        foreach ($this->events as $e) {
            $max = max($max, (int) $e['order']);
        }

        return $max;
    }

    public function appendEvents(array $events): void
    {
        foreach ($events as $e) {
            $this->events[] = $e;
        }
    }

    public function log(): array
    {
        $log = $this->events;
        usort($log, static fn (array $a, array $b): int => $a['order'] <=> $b['order']);

        return $log;
    }

    public function resolveKeys(array $codeKeys): array
    {
        $out = [];
        foreach ($codeKeys as $ck) {
            if (isset($this->members[$ck])) {
                $out[$ck] = $this->members[$ck]['key'];
            }
        }

        return $out;
    }

    public function resolveKey(string $codeKey): ?string
    {
        $key = $this->members[$codeKey]['key'] ?? null;
        if ($key === null) {
            return null;
        }

        // Follow redirects to the live key.
        while (isset($this->redirects[$key])) {
            $key = $this->redirects[$key]['new_key'];
        }

        return $key;
    }

    public function loadKeys(array $surrogateKeys): array
    {
        $out = [];
        foreach ($surrogateKeys as $k) {
            if (isset($this->snapshots[$k])) {
                $out[$k] = $this->snapshots[$k];
            }
        }

        return $out;
    }

    public function saveKey(string $surrogateKey, string $lane, array $codes, array $claims, int $lastSeq): void
    {
        $this->snapshots[$surrogateKey] = [
            'lane' => $lane,
            'codes' => $codes,
            'claims' => array_values($claims),
            'last_seq' => $lastSeq,
        ];

        // Rewrite this key's `members` rows to exactly its current code-set.
        foreach ($this->members as $code => $placement) {
            if ($placement['key'] === $surrogateKey) {
                unset($this->members[$code]);
            }
        }
        foreach ($codes as $codeKey => $_pair) {
            $this->members[$codeKey] = ['key' => $surrogateKey, 'lane' => $lane];
        }
    }

    public function removeKey(string $surrogateKey): void
    {
        unset($this->snapshots[$surrogateKey]);
        foreach ($this->members as $code => $placement) {
            if ($placement['key'] === $surrogateKey) {
                unset($this->members[$code]);
            }
        }
    }

    public function addRedirect(string $oldKey, string $newKey, mixed $at): void
    {
        $this->redirects[$oldKey] = ['new_key' => $newKey, 'at' => $at];
    }

    public function laneNext(string $lane): int
    {
        return $this->laneSeq[$lane] ?? 1;
    }

    public function setLaneNext(string $lane, int $next): void
    {
        $this->laneSeq[$lane] = $next;
    }

    public function backfillSeen(string $legacyEntity, string $fingerprint): bool
    {
        return isset($this->backfillSeen[$legacyEntity."\x1f".$fingerprint]);
    }

    public function markBackfillSeen(string $legacyEntity, string $fingerprint): void
    {
        $this->backfillSeen[$legacyEntity."\x1f".$fingerprint] = true;
    }
}
