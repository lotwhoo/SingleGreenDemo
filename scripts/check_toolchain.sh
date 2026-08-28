#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
config_path=${1:-"$repository_root/config/toolchain.json"}

python3 - "$config_path" <<'PY'
import json
import platform
import re
import shutil
import subprocess
import sys

config_path = sys.argv[1]
try:
    with open(config_path, encoding="utf-8") as stream:
        config = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"error: cannot read toolchain configuration {config_path}: {error}")

def output(*command: str) -> str:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise SystemExit(f"error: {' '.join(command)} failed: {detail}")
    return result.stdout.strip()

errors = []
xcode = output("xcodebuild", "-version").splitlines()
actual_xcode = xcode[0].removeprefix("Xcode ") if xcode else ""
actual_build = xcode[1].removeprefix("Build version ") if len(xcode) > 1 else ""
if actual_xcode != config["xcode_version"]:
    errors.append(f"Xcode expected {config['xcode_version']}, got {actual_xcode}")
if actual_build != config["xcode_build"]:
    errors.append(f"Xcode build expected {config['xcode_build']}, got {actual_build}")

swift = output("swift", "--version")
match = re.search(r"Apple Swift version\s+([0-9.]+)", swift)
actual_swift = match.group(1) if match else "unrecognized"
if actual_swift != config["swift_version"]:
    errors.append(f"Apple Swift expected {config['swift_version']}, got {actual_swift}")

for sdk, key, label in (
    ("macosx", "macos_sdk", "macOS SDK"),
    ("iphonesimulator", "iphone_simulator_sdk", "iPhone Simulator SDK"),
):
    actual = output("xcrun", "--sdk", sdk, "--show-sdk-version")
    if actual != config[key]:
        errors.append(f"{label} expected {config[key]}, got {actual}")

architecture = platform.machine()
if architecture not in config["allowed_host_architectures"]:
    errors.append(
        f"host architecture expected one of {config['allowed_host_architectures']}, got {architecture}"
    )

digester = output("xcrun", "--find", "swift-api-digester")
if not digester or not shutil.which(digester):
    errors.append("swift-api-digester is unavailable")

if errors:
    for error in errors:
        print(f"error: toolchain rule: {error}", file=sys.stderr)
    raise SystemExit(1)

print(
    "Toolchain check passed "
    f"(Xcode {actual_xcode} {actual_build}, Apple Swift {actual_swift}, "
    f"SDKs {config['macos_sdk']}/{config['iphone_simulator_sdk']}, host {architecture})."
)
PY
