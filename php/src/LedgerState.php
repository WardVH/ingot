<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The IdentityLedger's state — ported from the `%IdentityLedger{}` struct.
 *
 * `members` maps each surrogate key to its code-set; `next` is the integer counter for the next
 * key to mint; `prefix` is the lane qualifier ("SK" for products, "SUB"/"DSC"/"MED" for the other
 * lanes). Readonly so threading the fold can never accidentally mutate a prior state.
 */
final class LedgerState
{
    /**
     * @param array<string, array<string, array{0: string, 1: string}>> $members key => code-set
     */
    public function __construct(
        public readonly array $members,
        public readonly int $next,
        public readonly string $prefix = 'SK',
    ) {
    }

    /**
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     */
    public function with(?array $members = null, ?int $next = null): self
    {
        return new self(
            $members ?? $this->members,
            $next ?? $this->next,
            $this->prefix,
        );
    }
}
