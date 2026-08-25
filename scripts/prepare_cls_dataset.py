#!/usr/bin/env python3
"""Turn a PCC judge export bundle into an ImageFolder classification dataset.

Reads records.jsonl + crops/ from an exported bundle, keeps only answered,
successfully-mapped judgments, and copies each crop into:

    <out>/train/<bin>/<name>.jpg
    <out>/val/<bin>/<name>.jpg

Splitting is done per sessionId so near-duplicate crops of the same physical
item cannot leak between train and val.

Usage:
    python3 prepare_cls_dataset.py <bundle_dir> -o dataset [--val-share 0.2]
"""
from __future__ import annotations

import argparse
import json
import random
import shutil
from collections import Counter, defaultdict
from pathlib import Path


def outcome_of(record: dict) -> str | None:
    """The codec encodes Outcome as a tagged object: {"outcome": "answered"}.
    Handle that form (and tolerate a flat string for older exports)."""
    outcome = record.get("outcome")
    if isinstance(outcome, dict):
        return outcome.get("outcome")
    return outcome


def is_pcc_teacher(record: dict) -> bool:
    """Only PCC verdicts may label training data. The smoke screen's AFM
    cross-check records (pipeline containing 'afm') are ON-DEVICE model
    verdicts — a different teacher; mixing them would dilute the label
    source this flywheel exists to distill."""
    return "afm" not in (record.get("pipeline") or "").lower()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="exported bundle directory")
    parser.add_argument("-o", "--out", type=Path, default=Path("dataset"))
    parser.add_argument("--val-share", type=float, default=0.2)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    records_path = args.bundle / "records.jsonl"
    crops_dir = args.bundle / "crops"
    records = [json.loads(line) for line in records_path.read_text().splitlines() if line.strip()]

    drop_reasons: Counter[str] = Counter()
    usable = []
    for r in records:
        if outcome_of(r) != "answered":
            drop_reasons["not answered"] += 1
        elif r.get("mappingFailed"):
            drop_reasons["mapping failed"] += 1
        elif not r.get("pccBinID"):
            drop_reasons["no pccBinID"] += 1
        elif not r.get("cropFile"):
            drop_reasons["no crop"] += 1
        elif not is_pcc_teacher(r):
            drop_reasons["non-PCC teacher (afm cross-check)"] += 1
        else:
            usable.append(r)
    dropped = len(records) - len(usable)

    by_session: dict[str, list[dict]] = defaultdict(list)
    no_session: list[dict] = []
    for record in usable:
        key = record.get("sessionId") or ""
        if key:
            by_session[key].append(record)
        else:
            no_session.append(record)

    rng = random.Random(args.seed)
    session_keys = sorted(by_session)
    rng.shuffle(session_keys)
    val_cutoff = int(len(session_keys) * args.val_share)
    val_sessions = set(session_keys[:val_cutoff])

    counts: Counter[str] = Counter()
    for record in usable:
        session = record.get("sessionId") or ""
        split = "val" if session and session in val_sessions else "train"
        # Sessionless records go to train; they are one-off items anyway.
        destination = args.out / split / str(record["pccBinID"])
        destination.mkdir(parents=True, exist_ok=True)
        source = args.bundle / record["cropFile"]
        shutil.copy2(source, destination / Path(record["cropFile"]).name)
        counts[f"{split}/{record['pccBinID']}"] += 1

    print(f"records total: {len(records)}  usable: {len(usable)}  dropped: {dropped}")
    for reason, count in sorted(drop_reasons.items()):
        print(f"  dropped ({reason}): {count}")
    print(f"sessions: {len(session_keys)} train-sessions: {len(session_keys) - len(val_sessions)}")
    for name, count in sorted(counts.items()):
        print(f"  {name}: {count}")
    imbalance = [c for c in counts.values() if c < max(counts.values(), default=0) * 0.25]
    if imbalance:
        print("WARNING: a class has <25% of the largest class's count; collect more data before trusting results.")


if __name__ == "__main__":
    main()
