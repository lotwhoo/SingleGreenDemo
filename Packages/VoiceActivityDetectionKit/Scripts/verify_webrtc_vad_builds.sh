#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
evidence_root=${1:-$(mktemp -d /private/tmp/sgd-webrtc-vad-builds.XXXXXX)}

mkdir -p "$evidence_root"

run_build() {
  label=$1
  destination=$2
  architecture=$3
  derived_data="$evidence_root/$label"
  log="$evidence_root/$label.log"

  xcodebuild \
    -scheme WebRTCVoiceActivityDetection \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -configuration Release \
    CODE_SIGNING_ALLOWED=NO \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    ARCHS="$architecture" \
    ONLY_ACTIVE_ARCH=YES \
    SWIFT_VERSION=6 \
    SWIFT_STRICT_CONCURRENCY=complete \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    'OTHER_CFLAGS=$(inherited) -Wall -Wextra -Wpedantic -Werror' \
    build > "$log" 2>&1

  if grep -Eq "warning:|error:" "$log"; then
    echo "unexpected diagnostic in $label" >&2
    grep -En "warning:|error:" "$log" >&2
    exit 1
  fi
  if ! grep -q "\*\* BUILD SUCCEEDED \*\*" "$log"; then
    echo "missing build success marker in $label" >&2
    tail -n 80 "$log" >&2
    exit 1
  fi

  object_directory=$(find "$derived_data/Build/Intermediates.noindex" \
    -path "*CWebRTCVAD.build/Objects-normal/$architecture" \
    -type d \
    | head -n 1)
  if [ -z "$object_directory" ]; then
    echo "missing CWebRTCVAD object directory in $label" >&2
    exit 1
  fi
  wrapper_count=$(find "$object_directory" -name '*_wrapper.o' -type f | wc -l | tr -d ' ')
  production_object_count=$(find "$object_directory" -name '*.o' -type f | wc -l | tr -d ' ')
  if [ "$wrapper_count" -ne 11 ] || [ "$production_object_count" -ne 12 ]; then
    echo "expected 11 wrapper objects plus one facade object in $label" >&2
    exit 1
  fi
  if find "$object_directory" \
    -name '*.o' \
    ! -name '*_wrapper.o' \
    ! -name 'rtc_fatal_message.o' \
    | grep -q .; then
    echo "raw upstream C source was compiled directly in $label" >&2
    exit 1
  fi

  find "$object_directory" \
    -name '*_wrapper.o' \
    -type f \
    -exec nm -m {} + > "$evidence_root/$label-upstream-symbols.txt"
  if grep -E " external _WebRtc" "$evidence_root/$label-upstream-symbols.txt" \
    | grep -v "(undefined)" \
    | grep -v "private external" > "$evidence_root/$label-visible-upstream.txt"; then
    echo "upstream implementation symbol is not hidden in $label" >&2
    cat "$evidence_root/$label-visible-upstream.txt" >&2
    exit 1
  fi

  echo "Verified $label ($architecture)"
}

cd "$package_root"
run_build iphoneos-arm64 "generic/platform=iOS" arm64
run_build simulator-arm64 "generic/platform=iOS Simulator" arm64
run_build simulator-x86_64 "generic/platform=iOS Simulator" x86_64

echo "Verified WebRTC VAD Release builds with strict C warnings on 3 Apple triples; logs: $evidence_root"
