#!/usr/bin/env python3

import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: summarize_package_coverage.py CODECOV_JSON PACKAGE_PATH REPORT",
            file=sys.stderr,
        )
        return 64

    export_path, package_path, report_path = sys.argv[1:]
    package_name = os.path.basename(os.path.realpath(package_path))
    source_root = os.path.realpath(
        os.path.join(package_path, "Sources", package_name)
    ) + os.sep
    if not os.path.isdir(source_root):
        print(
            f"canonical production target directory is missing: Sources/{package_name}",
            file=sys.stderr,
        )
        return 1
    with open(export_path, encoding="utf-8") as handle:
        document = json.load(handle)

    files = []
    for data in document.get("data", []):
        for item in data.get("files", []):
            filename = item.get("filename")
            if not isinstance(filename, str):
                continue
            if os.path.realpath(filename).startswith(source_root):
                files.append(item)

    covered = sum(item["summary"]["lines"]["covered"] for item in files)
    count = sum(item["summary"]["lines"]["count"] for item in files)
    if count == 0:
        print("coverage export has no canonical package production source lines", file=sys.stderr)
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
