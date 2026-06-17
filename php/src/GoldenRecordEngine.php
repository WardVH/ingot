<?php

declare(strict_types=1);

namespace GoldenRecord;

/**
 * The single entry point the consuming application (medipim) calls. Collapses the five-module fold
 * the engine otherwise requires — {@see EnvelopeLoader} → {@see GoldenRecords}/{@see LegacyXref}/
 * {@see MigrationDiff} → {@see Canonical422156} — into one call returning a {@see GoldenRecordResult}.
 *
 * Concrete on purpose: there is one implementation, so there is no interface to mock. A medipim-side
 * adapter that needs to satisfy `ProductCodeLookupRepositoryInterface` wraps this class and maps the
 * engine's surrogate keys to `ProductId`s; it does not subclass it.
 *
 * `$at` is the temporal cut-off the log is re-derived against and is REQUIRED — there is no safe
 * default for "as of when", and a wrong default would silently change which claims win survivorship.
 */
final class GoldenRecordEngine
{
    /**
     * Fold already-decoded contract-C envelopes into a golden record at time `$at`.
     *
     * @param list<array<string,mixed>> $envelopes
     */
    public function ingest(array $envelopes, mixed $at, ?Priority $priority = null): GoldenRecordResult
    {
        return new GoldenRecordResult(
            GoldenRecords::fromEnvelopes($envelopes, $at, $priority),
            LegacyXref::fromEnvelopes($envelopes, $at),
            MigrationDiff::fromEnvelopes($envelopes, $at),
        );
    }

    /** Convenience: load one envelope file (validating it), then {@see ingest}. */
    public function ingestFile(string $path, mixed $at, ?Priority $priority = null): GoldenRecordResult
    {
        return $this->ingest([EnvelopeLoader::loadBang($path)], $at, $priority);
    }

    /** Convenience: decode one envelope from a JSON string, then {@see ingest}. */
    public function ingestJson(string $json, mixed $at, ?Priority $priority = null): GoldenRecordResult
    {
        return $this->ingest([EnvelopeLoader::fromJson($json)], $at, $priority);
    }
}
