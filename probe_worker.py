"""Read only the installed worker's own lease and heartbeat receipts.

This probe uses the installed SQL helper and deliberately prints no job,
customer, credential, or configuration rows.
"""

from __future__ import annotations

import argparse
import ast
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys


def literal_worker_name(source: Path) -> str:
    tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    for statement in tree.body:
        if (isinstance(statement, ast.Assign) and len(statement.targets) == 1
                and isinstance(statement.targets[0], ast.Name)
                and statement.targets[0].id == "WORKER"
                and isinstance(statement.value, ast.Constant)
                and isinstance(statement.value.value, str)):
            name = statement.value.value
            if re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", name):
                return name
    raise ValueError("worker_identity_unavailable")


def quoted(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def probe(root: Path, since: datetime) -> dict:
    runtime = root / ".runtime"
    worker = literal_worker_name(runtime / "stage5_shift_ai.py")
    if since.tzinfo is None:
        raise ValueError("since_must_include_timezone")
    since_utc = since.astimezone(timezone.utc).isoformat()
    prefix = worker + ":"
    identity = worker + ":ai"

    os.chdir(root)
    sys.path[:0] = [str(runtime), str(root / "app-source"), str(root)]
    from run_stage5_worker import configure_docker
    from stage5_live_batch import sql

    configure_docker()
    query = f"""
      select json_build_object(
        'active_leases', (select count(*) from public.jobs
          where state='leased' and lease_until>clock_timestamp()
            and left(lease_owner,{len(prefix)})={quoted(prefix)}),
        'heartbeat', (select json_build_object(
          'last_seen_at', last_seen_at, 'status', status,
          'mode', details->>'mode',
          'pattern_pipeline_enabled', details->'pattern_pipeline_enabled',
          'pattern_discovery', details->>'pattern_discovery',
          'pattern_last_result', details->>'pattern_last_result')
          from public.worker_status where id={quoted(identity)}),
        'completed_pattern_since', (select count(*) from public.jobs
          where type='pattern_review' and state='done'
            and finished_at>={quoted(since_utc)}::timestamptz)
      )::text;
    """
    result = json.loads(sql(query))
    if (not isinstance(result, dict) or type(result.get("active_leases")) is not int
            or type(result.get("completed_pattern_since")) is not int):
        raise ValueError("invalid_probe_result")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--since", required=True)
    args = parser.parse_args()
    try:
        result = probe(args.root.resolve(strict=True), datetime.fromisoformat(args.since))
    except Exception as error:
        print(json.dumps({"probe": "unavailable", "reason": type(error).__name__}), file=sys.stderr)
        raise SystemExit(2) from None
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
