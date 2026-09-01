#!/usr/bin/env python3

import json
import os
import sys


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "usage: summarize_package_coverage.py CODECOV_JSON PACKAGE_PATH REPORT [SOURCE_TARGET ...]",
            file=sys.stderr,
        )
        return 64

    export_path, package_path, report_path = sys.argv[1:4]
    package_name = os.path.basename(os.path.realpath(package_path))
    source_targets = sys.argv[4:] or [package_name]
    sources_directory = os.path.realpath(os.path.join(package_path, "Sources"))
    source_roots = []
    for source_target in source_targets:
        source_root = os.path.realpath(
            os.path.join(sources_directory, source_target)
        )
        if os.path.commonpath([sources_directory, source_root]) != sources_directory:
            print(f"invalid production source target: {source_target}", file=sys.stderr)
            return 1
        if not os.path.isdir(source_root):
            print(
                f"production target directory is missing: Sources/{source_target}",
                file=sys.stderr,
            )
            return 1
        source_roots.append(source_root + os.sep)
    with open(export_path, encoding="utf-8") as handle:
        document = json.load(handle)

    files = []
    for data in document.get("data", []):
        for item in data.get("files", []):
            filename = item.get("filename")
            if not isinstance(filename, str):
                continue
            if any(
                os.path.realpath(filename).startswith(source_root)
                for source_root in source_roots
            ):
                files.append(item)

    covered = sum(item["summary"]["lines"]["covered"] for item in files)
    count = sum(item["summary"]["lines"]["count"] for item in files)
    if count == 0:
        print("coverage export has no selected package production source lines", file=sys.stderr)
        return 1

    percent = covered * 100.0 / count
    with open(report_path, "w", encoding="utf-8") as handle:
        handle.write(f"production_source_lines={count}\n")
        handle.write(f"covered_lines={covered}\n")
        handle.write(f"line_coverage_percent={percent:.2f}\n")
    print(f"{percent:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
