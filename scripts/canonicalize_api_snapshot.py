#!/usr/bin/env python3
"""Write a deterministic API snapshot after rejecting volatile host metadata."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--temporary-root", required=True)
    arguments = parser.parse_args()

    try:
        payload = json.loads(arguments.input.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"error: cannot read API snapshot: {error}", file=sys.stderr)
        return 1

    volatile_paths = {
        str(Path(arguments.repository_root).absolute()),
        str(Path(arguments.repository_root).resolve()),
        str(Path(arguments.temporary_root).absolute()),
        str(Path(arguments.temporary_root).resolve()),
        "/Users/",
        "/private/tmp/",
    }
    violations: list[str] = []

    def inspect(value: object, location: str) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "tool_arguments":
                    violations.append(f"{location}.tool_arguments")
                inspect(child, f"{location}.{key}")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                inspect(child, f"{location}[{index}]")
        elif isinstance(value, str):
            for needle in volatile_paths:
                if needle and needle in value:
                    violations.append(f"{location} contains {needle}")

    inspect(payload, "snapshot")
    if violations:
        for violation in sorted(set(violations)):
            print(f"error: volatile API snapshot metadata: {violation}", file=sys.stderr)
        return 1

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True, ensure_ascii=False)
        stream.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
