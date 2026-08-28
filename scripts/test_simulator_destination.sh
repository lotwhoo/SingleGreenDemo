#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
actual=$("$script_directory/resolve_simulator_destination.sh" \
    "$script_directory/fixtures/simctl-devices.json")
expected=00000000-0000-0000-0000-000000000002

if [ "$actual" != "$expected" ]; then
    echo "error: expected preferred iPhone 17 Pro UDID, got $actual" >&2
    exit 1
fi

echo "Simulator destination resolver test passed."
