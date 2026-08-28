#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
"$script_directory/check_toolchain.sh"

fixture=$(mktemp -d "${TMPDIR:-/private/tmp}/single-green-api-self-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

cat >"$fixture/canonical-safe.json" <<'JSON'
{"ABIRoot":{"kind":"Root","name":"FixtureAPI"}}
JSON
python3 "$script_directory/canonicalize_api_snapshot.py" \
    "$fixture/canonical-safe.json" "$fixture/canonical-output.json" \
    --repository-root "$repository_root" --temporary-root "$fixture"
python3 - "$script_directory/canonicalize_api_snapshot.py" "$fixture" "$repository_root" <<'PY'
from pathlib import Path
import json
import subprocess
import sys

canonicalizer = Path(sys.argv[1])
fixture = Path(sys.argv[2])
repository_root = Path(sys.argv[3])
bad_payloads = (
    {"ABIRoot": {"tool_arguments": ["-dump-sdk"]}},
    {"ABIRoot": {"location": str(repository_root / "Packages")}},
    {"ABIRoot": {"location": str(fixture / "build")}},
    {"ABIRoot": {"location": "/Users/example/source.swift"}},
    {"ABIRoot": {"location": "/private/tmp/build/source.swift"}},
)
for index, payload in enumerate(bad_payloads):
    source = fixture / f"canonical-bad-{index}.json"
    output = fixture / f"canonical-bad-{index}-output.json"
    source.write_text(json.dumps(payload))
    result = subprocess.run(
        [
            sys.executable, str(canonicalizer), str(source), str(output),
            "--repository-root", str(repository_root),
            "--temporary-root", str(fixture),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode == 0 or "volatile API snapshot metadata" not in result.stderr:
        raise SystemExit(f"volatile API snapshot was not rejected: {payload}")
PY
mkdir -p "$fixture/Sources/FixtureAPI"
cat >"$fixture/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FixtureAPI",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FixtureAPI", targets: ["FixtureAPI"])],
    targets: [.target(name: "FixtureAPI")],
    swiftLanguageModes: [.v6]
)
SWIFT
cat >"$fixture/Sources/FixtureAPI/API.swift" <<'SWIFT'
public struct PublicThing {
    public init() {}
}

struct InternalThing {}
SWIFT

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
target_triple=arm64-apple-macosx14.0

snapshot() {
    scratch=$1
    output=$2
    swift build --package-path "$fixture" --scratch-path "$scratch" \
        --triple "$target_triple" --sdk "$sdk_path" >/dev/null
    raw="$output.raw"
    xcrun swift-api-digester -dump-sdk -module FixtureAPI -o "$raw" \
        -avoid-location -avoid-tool-args -swift-only -abort-on-module-fail \
        -I "$scratch/arm64-apple-macosx/debug/Modules" \
        -sdk "$sdk_path" -target "$target_triple"
    python3 "$script_directory/canonicalize_api_snapshot.py" \
        "$raw" "$output" \
        --repository-root "$repository_root" \
        --temporary-root "$fixture"
}

snapshot "$fixture/build-baseline" "$fixture/baseline.json"
cat >>"$fixture/Sources/FixtureAPI/API.swift" <<'SWIFT'

struct AnotherInternalThing {}
SWIFT
snapshot "$fixture/build-internal" "$fixture/internal.json"
if ! cmp -s "$fixture/baseline.json" "$fixture/internal.json"; then
    echo "error: internal-only change unexpectedly changed the public API snapshot" >&2
    exit 1
fi

cat >"$fixture/Sources/FixtureAPI/API.swift" <<'SWIFT'
struct InternalThing {}
SWIFT
snapshot "$fixture/build-removed" "$fixture/removed.json"
if cmp -s "$fixture/baseline.json" "$fixture/removed.json"; then
    echo "error: removed public symbol was not detected" >&2
    exit 1
fi
diagnosis="$fixture/diagnosis.txt"
if ! xcrun swift-api-digester -diagnose-sdk \
    -baseline-path "$fixture/baseline.json" -module FixtureAPI \
    -avoid-location -avoid-tool-args -swift-only -abort-on-module-fail \
    -I "$fixture/build-removed/arm64-apple-macosx/debug/Modules" \
    -sdk "$sdk_path" -target "$target_triple" -o "$diagnosis"; then
    echo "error: swift-api-digester failed to diagnose the removed public symbol" >&2
    exit 1
fi
if ! grep -Fq 'PublicThing' "$diagnosis"; then
    echo "error: digester diagnosis did not name the removed public symbol" >&2
    exit 1
fi

inventory_base="$fixture/inventory-base"
mkdir -p "$inventory_base/scripts" "$inventory_base/config" \
    "$inventory_base/api-baselines/fixture/macos-arm64" \
    "$inventory_base/api-baselines/fixture/ios-simulator-arm64"
cp "$script_directory/check_public_api_baselines.sh" "$inventory_base/scripts/"
cp "$repository_root/config/architecture-boundaries.json" "$inventory_base/config/"
cat >"$inventory_base/config/toolchain.json" <<'JSON'
{"api_baseline_version":"fixture"}
JSON
cat >"$inventory_base/scripts/check_toolchain.sh" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$inventory_base/scripts/check_toolchain.sh"
python3 - "$inventory_base/config/architecture-boundaries.json" "$inventory_base/api-baselines/fixture" <<'PY'
from pathlib import Path
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    modules = [item["module"] for item in json.load(stream)["public_api_modules"]]
root = Path(sys.argv[2])
for platform in ("macos-arm64", "ios-simulator-arm64"):
    for module in modules:
        (root / platform / f"{module}.json").write_text("{}\n")
PY
"$inventory_base/scripts/check_public_api_baselines.sh" --validate-inventory-only >/dev/null

expect_inventory_failure() {
    fixture_root=$1
    pattern=$2
    if "$fixture_root/scripts/check_public_api_baselines.sh" --validate-inventory-only \
        >"$fixture_root/output.txt" 2>&1; then
        echo "error: invalid public API inventory unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -Fq "$pattern" "$fixture_root/output.txt"; then
        echo "error: public API inventory failure did not report: $pattern" >&2
        cat "$fixture_root/output.txt" >&2
        exit 1
    fi
}

removed_mapping="$fixture/inventory-removed"
cp -R "$inventory_base" "$removed_mapping"
python3 - "$removed_mapping/config/architecture-boundaries.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
config = json.loads(path.read_text())
config["public_api_modules"].pop()
path.write_text(json.dumps(config, indent=2) + "\n")
PY
expect_inventory_failure "$removed_mapping" 'missing public API product mappings'

duplicate_mapping="$fixture/inventory-duplicate"
cp -R "$inventory_base" "$duplicate_mapping"
python3 - "$duplicate_mapping/config/architecture-boundaries.json" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1])
config = json.loads(path.read_text())
config["public_api_modules"].append(dict(config["public_api_modules"][0]))
path.write_text(json.dumps(config, indent=2) + "\n")
PY
expect_inventory_failure "$duplicate_mapping" 'duplicate public API product mappings'

stale_snapshot="$fixture/inventory-stale"
cp -R "$inventory_base" "$stale_snapshot"
printf '{}\n' >"$stale_snapshot/api-baselines/fixture/macos-arm64/StaleModule.json"
expect_inventory_failure "$stale_snapshot" 'unexpected public API snapshot files'

echo "Public API baseline self-test passed (symbol changes plus mapping and snapshot inventory negatives)."
