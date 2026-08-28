#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
package_root="$repository_root/Packages/VoiceActivityDetectionKit"
production_sources="$package_root/Sources/VoiceActivityDetectionKit"
manifest="$package_root/Package.swift"

forbidden_production='import (AVFoundation|AudioToolbox|Network|OSLog)|URLSession|NWConnection|AVAudio|print\(|debugPrint\(|dump\(|NSLog\(|Logger\(|os_log|upload|transcript|provider'
if LC_ALL=C grep -REn -e "$forbidden_production" "$production_sources"; then
    echo "error: VAD production foundation contains capture, network, provider, content logging, or upload behavior" >&2
    exit 1
fi

if grep -Fq '.package(' "$manifest"; then
    echo "error: VAD foundation must remain dependency-free at the WebRTC approval checkpoint" >&2
    exit 1
fi

if sed -n '/products:/,/targets:/p' "$manifest" | grep -Fq 'VADBenchmarkSupport'; then
    echo "error: the energy detector support target must not be selectable as a package product" >&2
    exit 1
fi

if find "$package_root" -type f \
    \( -name '*.pcm' -o -name '*.wav' -o -name '*.m4a' -o -name '*.caf' -o -name '*.bin' \) \
    ! -path '*/.build/*' | grep -q .; then
    echo "error: VAD fixtures must be generated synthetic data, not checked-in audio/binary content" >&2
    exit 1
fi

print_count=$(grep -RE 'print\(' "$package_root/Sources/VADBenchmark" | wc -l | tr -d ' ')
if [ "$print_count" -ne 1 ]; then
    echo "error: VAD benchmark must have exactly one aggregate-only report" >&2
    exit 1
fi
if ! grep -Fq 'vad_benchmark frame_count=' "$package_root/Sources/VADBenchmark/main.swift" ||
   grep -E 'print\(.*(sample|byte|audio|pcm|content|probability|transcript)' "$package_root/Sources/VADBenchmark/main.swift" >/dev/null; then
    echo "error: VAD benchmark output is not limited to aggregate counters" >&2
    exit 1
fi

echo "VAD privacy and dependency-boundary check passed."
