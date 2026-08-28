#!/bin/sh

set -eu

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [SIMCTL_DEVICES.json]" >&2
    exit 64
fi

if [ "$#" -eq 1 ]; then
    input=$1
else
    input=$(mktemp "${TMPDIR:-/tmp}/single-green-simctl.XXXXXX")
    trap 'rm -f "$input"' EXIT HUP INT TERM
    xcrun simctl list devices available -j > "$input"
fi

python3 - "$input" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)

devices = []
for runtime, values in document.get("devices", {}).items():
    version_match = re.search(r"iOS-(\d+)(?:-(\d+))?", runtime)
    version = tuple(int(value or 0) for value in version_match.groups()) if version_match else (0, 0)
    for device in values:
        name = device.get("name", "")
        udid = device.get("udid")
        if not name.startswith("iPhone ") or not udid or device.get("isAvailable") is False:
            continue
        preferred = 1 if name == "iPhone 17 Pro" else 0
        devices.append((preferred, version, name, udid))

if not devices:
    raise SystemExit("no available iPhone Simulator destination")

devices.sort(reverse=True)
print(devices[0][3])
PY
