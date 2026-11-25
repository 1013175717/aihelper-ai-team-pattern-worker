"""Apply a narrowly scoped, hash-pinned Stage 5 source delta.

The source and result hashes are supplied by the release wrapper. This helper
does not import the installed worker or read its private configuration.
"""

from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re


SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def digest(data: bytes) -> str:
    return sha256(data).hexdigest()


def apply_delta(source: Path, delta: Path, output: Path, baseline_hash: str, target_hash: str) -> None:
    if not SHA256.fullmatch(baseline_hash) or not SHA256.fullmatch(target_hash):
        raise ValueError("invalid_expected_hash")
    spec = json.loads(delta.read_text(encoding="utf-8"))
    if spec.get("format") != "aihelper-stage5-line-delta-v1":
        raise ValueError("unexpected_delta_format")
    if spec.get("baseline_sha256") != baseline_hash or spec.get("target_sha256") != target_hash:
        raise ValueError("delta_hash_contract_mismatch")

    original = source.read_bytes()
    if digest(original) != baseline_hash:
        raise ValueError("installed_baseline_hash_mismatch")
    normalized = original.decode("utf-8").replace("\r\n", "\n")
    if "\r" in normalized:
        raise ValueError("unsupported_source_line_endings")
    lines = normalized.splitlines(keepends=True)
    edits = spec.get("edits")
    if not isinstance(edits, list) or not edits:
        raise ValueError("missing_delta_edits")
    previous_end = 0
    for edit in edits:
        if not isinstance(edit, dict) or set(edit) != {"start", "delete", "insert"}:
            raise ValueError("invalid_delta_edit")
        start, deleted, inserted = edit["start"], edit["delete"], edit["insert"]
        if (type(start) is not int or type(deleted) is not int or not isinstance(inserted, str)
                or start < previous_end or deleted < 0 or start + deleted > len(lines)
                or "\r" in inserted):
            raise ValueError("invalid_delta_bounds")
        previous_end = start + deleted
    for edit in reversed(edits):
        lines[edit["start"]:edit["start"] + edit["delete"]] = edit["insert"].splitlines(keepends=True)

    patched = "".join(lines).encode("utf-8")
    if digest(patched) != target_hash:
        raise ValueError("patched_result_hash_mismatch")
    with output.open("xb") as staged:
        staged.write(patched)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--delta", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-sha256", required=True)
    parser.add_argument("--target-sha256", required=True)
    args = parser.parse_args()
    apply_delta(args.source, args.delta, args.output, args.baseline_sha256, args.target_sha256)
    print("staged_hash_verified")


if __name__ == "__main__":
    main()
