#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)

expected_packages='LLMKit
SingleGreenGlassesKit
StreamingTextKit
VoiceActivityDetectionKit
VoiceChatCore
VoiceChatDomain'
actual_packages=$(find "$repository_root/Packages" -mindepth 1 -maxdepth 1 -type d \
    ! -name '.build' ! -name '.swiftpm' -exec basename {} \; | LC_ALL=C sort)

if [ "$actual_packages" != "$expected_packages" ]; then
    echo "error: local package inventory differs from the reviewed six-package set" >&2
    echo "expected:" >&2
    echo "$expected_packages" >&2
    echo "actual:" >&2
    echo "$actual_packages" >&2
    exit 1
fi

for package in $expected_packages; do
    if [ ! -f "$repository_root/Packages/$package/Package.swift" ]; then
        echo "error: package manifest is missing: Packages/$package/Package.swift" >&2
        exit 1
    fi
    if ! grep -Fq "$package" "$repository_root/Packages/README.md"; then
        echo "error: Packages/README.md does not inventory $package" >&2
        exit 1
    fi
done

for gate in \
    "$repository_root/scripts/strict_concurrency_gate.sh" \
    "$repository_root/scripts/coverage_gate.sh" \
    "$repository_root/.github/workflows/ci.yml"
do
    if ! grep -Fq 'VoiceActivityDetectionKit' "$gate"; then
        echo "error: VoiceActivityDetectionKit is missing from ${gate#"$repository_root/"}" >&2
        exit 1
    fi
done

echo "Package inventory check passed (6 local packages)."
