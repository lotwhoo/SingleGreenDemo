#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture_root=/private/tmp/SingleGreenDemo-CoverageScopeFixture
package_path="$fixture_root/CurrentPackage"
dependency_path="$fixture_root/DependencyPackage"
export_path="$fixture_root/mixed-codecov.json"
report_path="$fixture_root/report.txt"

mkdir -p \
    "$package_path/Sources/CurrentPackage" \
    "$package_path/Sources/ProviderAdapter" \
    "$package_path/Sources/BenchmarkSupport" \
    "$dependency_path/Sources/Dependency"
python3 - "$package_path" "$dependency_path" "$export_path" <<'PY'
import json
import os
import sys

package, dependency, destination = sys.argv[1:]
document = {
    "data": [{
        "files": [
            {
                "filename": os.path.join(package, "Sources/CurrentPackage/Feature.swift"),
                "summary": {"lines": {"covered": 5, "count": 10}},
            },
            {
                "filename": os.path.join(package, "Sources/ProviderAdapter/Client.swift"),
                "summary": {"lines": {"covered": 15, "count": 20}},
            },
            {
                "filename": os.path.join(package, "Sources/BenchmarkSupport/Energy.swift"),
                "summary": {"lines": {"covered": 100, "count": 100}},
            },
            {
                "filename": os.path.join(dependency, "Sources/Dependency/Library.swift"),
                "summary": {"lines": {"covered": 100, "count": 100}},
            },
            {
                "filename": os.path.join(package, "Tests/CurrentTests/FeatureTests.swift"),
                "summary": {"lines": {"covered": 50, "count": 50}},
            },
        ]
    }]
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
PY

result=$(python3 "$script_directory/summarize_package_coverage.py" \
    "$export_path" "$package_path" "$report_path" \
    CurrentPackage ProviderAdapter)
[ "$result" = "66.67" ] || {
    echo "error: expected selected production-target coverage 66.67, got $result" >&2
    exit 1
}
grep -q '^production_source_lines=30$' "$report_path"
grep -q '^covered_lines=20$' "$report_path"

echo "Coverage scope regression passed."
