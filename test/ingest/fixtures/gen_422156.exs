#!/usr/bin/env elixir
#
# Thin wrapper around the general fixture oracle `gen.exs`, pinned to the Belgian PoC fixture
# (legacy entity 422156, an Aderma Primalba wash gel). It exists as a named, zero-argument entry
# point and the byte-for-byte REGRESSION GUARD: `medipim_be_422156.json` must reproduce unchanged
# from `medipim_be_422156.raw.jsonl` after any decode-rule change.
#
# The real decode logic + decode-rule documentation live in `gen.exs` (general over markets, with
# the identity field-set driven by CodeRegistry.identity_fields/0). Run via `mix run` so lib/ is
# compiled and CodeRegistry is loadable:
#
#     mix run test/ingest/fixtures/gen_422156.exs
#     # equivalently:  mix run test/ingest/fixtures/gen.exs medipim-be 422156

Code.require_file("gen.exs", __DIR__)

Gen.run("medipim-be", 422_156)
