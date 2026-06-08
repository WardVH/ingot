#!/usr/bin/env python3
"""
Fixture generator (one-off ORACLE, not the runtime ingest).

Reads the real medipim `products_deltas` history for legacy entity 422156
(`medipim_be_422156.raw.jsonl`, a faithful dump) and emits the decoded-but-
unresolved `HistoryEnvelope` (`medipim_be_422156.json`) per contract C.

This script applies medipim's decode rules (documented in ../HISTORY_ENVELOPE.md
and reverse-engineered from medipimv2's ProductDeltaApplier / Event / GtinCodeHelper /
ProductMetaFieldBuilder). It is NOT the production decoder: the real system-of-record
ingest consumes envelopes emitted by medipim's own PHP endpoint (bead gr-867), which
reuses medipim's battle-tested code. This generator exists only to bootstrap a committed
fixture from a one-time dump — and its output is precisely the contract that endpoint
must reproduce. Regenerate:  python3 gen_422156.py

Decode rules applied here (validated against the real 422156 data):
  - opcode 1=set 2=add 3=remove 4=delete; the string opcode "update_sources" is dropped
    (it is a survivorship recompute, not a data change — this engine owns resolution).
  - key grammar field[:locale][:organizationId]: a trailing all-digit segment is the
    source (organization id); a 2-letter alpha segment is the locale.
  - opcode 4 (delete) carries the source in the VALUE, not the key
    (e.g. ["4","eanGtin13",1034] = drop org 1034's eanGtin13 entry).
  - eanGtin8/12/13/14 values are stored with a "{field}_" prefix which is stripped.
  - meta fields (updatedAt/updatedBy/createdAt/createdBy/legacyId) are dropped; a delta
    that reduces to nothing but meta is a touch-only delta (dropped_meta_count++).
  - last_touched_at = max updatedAt over ALL deltas, including dropped ones.
  - NO survivorship, NO folding, NO clustering: every source's events are kept, flat
    and time-ordered. legacy_entity rides along as metadata only.
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "medipim_be_422156.raw.jsonl")
OUT = os.path.join(HERE, "medipim_be_422156.json")

LEGACY_ENTITY = 422156
SOURCE_SYSTEM = "medipim-be"
SCHEMA_VERSION = "1"

OP = {"1": "set", "2": "add", "3": "remove", "4": "delete"}

IDENTITY = {"cnk", "ean", "gtin", "eanGtin8", "eanGtin12", "eanGtin13", "eanGtin14"}
GTIN_PREFIXED = {"eanGtin8", "eanGtin12", "eanGtin13", "eanGtin14"}
MEDIA = {"media", "descriptions"}
EDGE = {"publicCategories", "brands", "labos", "internationalBrands",
        "medipimCategories", "organizations"}
# dropped at the boundary: medipim-internal plumbing + touch signal
META_DROP = {"updatedAt", "updatedBy", "createdAt", "createdBy", "legacyId"}


def parse_key(key):
    """field[:locale][:org] -> (field, locale|None, source|None)."""
    parts = key.split(":")
    field = parts[0]
    locale = None
    source = None
    for seg in parts[1:]:
        if seg.isdigit():
            source = seg
        elif seg.isalpha():
            locale = seg
    return field, locale, source


def kind_of(field):
    if field in IDENTITY:
        return "identity"
    if field in MEDIA:
        return "media"
    if field in EDGE:
        return "edge"
    return "attribute"


def decode_triple(field, locale, source, op, value):
    """Build the kind-specific payload for one kept event."""
    kind = kind_of(field)
    ev = {"op": op, "kind": kind}
    if source is not None:
        ev["source"] = source

    if kind == "identity":
        ev["scheme"] = field
        if op == "delete":
            pass  # whole scheme entry for `source` is dropped; no code
        elif value is None:
            ev["code"] = None  # a "clear" (set null) — clears the code
        else:
            code = str(value)
            if field in GTIN_PREFIXED:
                prefix = field + "_"
                if code.startswith(prefix):
                    code = code[len(prefix):]
            ev["code"] = code
    elif kind == "attribute":
        ev["field"] = field
        if locale is not None:
            ev["locale"] = locale
        if op != "delete":
            ev["value"] = value
    elif kind == "edge":
        ev["collection"] = field
        if op != "delete":
            ev["value"] = value
    elif kind == "media":
        ev["collection"] = field
        if op != "delete":
            ev["asset"] = value
    return ev


def main():
    events = []
    dropped_meta_count = 0
    last_touched_at = 0

    with open(RAW) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            delta = json.loads(line)
            recorded_at = delta["created_at"]
            by = delta.get("created_by")
            tag = delta.get("tag")
            kept = []

            for triple in delta["events"]:
                opcode, key, value = triple[0], triple[1], (triple[2] if len(triple) > 2 else None)

                if opcode == "update_sources":
                    continue

                field = key.split(":")[0]
                if field == "updatedAt":
                    if isinstance(value, int):
                        last_touched_at = max(last_touched_at, value)
                    continue
                if field in META_DROP:
                    continue

                _, locale, source = parse_key(key)
                op = OP.get(str(opcode), str(opcode))

                # opcode 4: the value IS the source whose entry is deleted
                if op == "delete":
                    source = str(value) if value is not None else source
                    value = None

                ev = {"recorded_at": recorded_at}
                if by is not None:
                    ev["by"] = by
                if tag is not None:
                    ev["tag"] = tag
                ev.update(decode_triple(field, locale, source, op, value))
                kept.append(ev)

            if kept:
                events.extend(kept)
            else:
                dropped_meta_count += 1

            last_touched_at = max(last_touched_at, recorded_at)

    envelope = {
        "schema_version": SCHEMA_VERSION,
        "source_system": SOURCE_SYSTEM,
        "legacy_entity": LEGACY_ENTITY,
        "last_touched_at": last_touched_at,
        "dropped_meta_count": dropped_meta_count,
        "events": events,
    }

    with open(OUT, "w") as fh:
        json.dump(envelope, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    # summary to stderr-ish stdout
    by_kind = {}
    for e in events:
        by_kind[e["kind"]] = by_kind.get(e["kind"], 0) + 1
    print(f"events kept       : {len(events)}")
    print(f"  by kind         : {by_kind}")
    print(f"dropped (touch)   : {dropped_meta_count} deltas")
    print(f"last_touched_at   : {last_touched_at}")
    print(f"wrote             : {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main()
