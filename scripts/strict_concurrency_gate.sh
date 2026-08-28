#!/bin/sh

set -eu

# Usage: scripts/strict_concurrency_gate.sh
# Runs every package test suite in Swift 6 complete-concurrency mode and treats
# compiler warnings as errors. The script exits immediately on the first failure.
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)

for package in \
    StreamingTextKit \
    VoiceChatDomain \
    VoiceActivityDetectionKit \
    SingleGreenGlassesKit \
    LLMKit \
    VoiceChatCore
do
    echo "==> Strict concurrency: $package"
    swift test \
        --package-path "$repository_root/Packages/$package" \
        -Xswiftc -strict-concurrency=complete \
        -Xswiftc -warnings-as-errors
done

echo "==> Strict concurrency: VoiceActivityDetectionKit/VADBenchmark product"
swift build \
    --package-path "$repository_root/Packages/VoiceActivityDetectionKit" \
    --product VADBenchmark \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors

echo "==> Strict concurrency: VoiceChatCore/ASRCLI product"
swift build \
    --package-path "$repository_root/Packages/VoiceChatCore" \
    --product ASRCLI \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors
