#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
public_header="$package_root/Sources/CWebRTCVAD/include/CWebRTCVAD.h"
probe_root=$(mktemp -d /private/tmp/sgd-webrtc-vad-consumer.XXXXXX)
trap 'rm -rf "$probe_root"' EXIT HUP INT TERM

python3 - "$package_root" "$public_header" "$probe_root" <<'PY'
import pathlib
import re
import shutil
import sys

package_root = pathlib.Path(sys.argv[1])
header_path = pathlib.Path(sys.argv[2])
probe_root = pathlib.Path(sys.argv[3])
header = header_path.read_text(encoding="utf-8")

if "webrtc_vad.h" in header or re.search(r"\bWebRtcVad_", header):
    raise SystemExit("public C facade must not include or declare upstream WebRTC API")

expected = {
    "SGDWebRtcVad_Create",
    "SGDWebRtcVad_Init",
    "SGDWebRtcVad_SetMode",
    "SGDWebRtcVad_Process",
    "SGDWebRtcVad_Free",
}
actual = set(re.findall(r"\bSGDWebRtcVad_[A-Za-z0-9_]+", header))
if actual != expected:
    raise SystemExit(f"unexpected public C facade: {sorted(actual)}")
if "typedef struct SGDWebRTCVADHandle SGDWebRTCVADHandle;" not in header:
    raise SystemExit("public C facade must use its project-owned opaque handle")
if not re.search(
    r"SGDWebRTCVADHandle\s*\*\s*_Nullable\s+SGDWebRtcVad_Create\s*\(void\)",
    header,
):
    raise SystemExit("checked create must be explicitly nullable for Swift import")

escaped_path = str(package_root).replace("\\", "\\\\").replace('"', '\\"')
manifest = f'''// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebRTCVADConsumerProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "VoiceActivityDetectionKit", path: "{escaped_path}")
    ],
    targets: [
        .executableTarget(
            name: "ConsumerProbe",
            dependencies: [
                .product(
                    name: "WebRTCVoiceActivityDetection",
                    package: "VoiceActivityDetectionKit"
                )
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
'''

positive = probe_root / "positive"
(positive / "Sources/ConsumerProbe").mkdir(parents=True)
(positive / "Package.swift").write_text(manifest, encoding="utf-8")
(positive / "Sources/ConsumerProbe/main.swift").write_text('''
import CWebRTCVAD
import WebRTCVoiceActivityDetection

guard let handle = SGDWebRtcVad_Create() else { fatalError("allocation failed") }
defer { SGDWebRtcVad_Free(handle) }
precondition(SGDWebRtcVad_Init(handle) == 0)
precondition(SGDWebRtcVad_SetMode(handle, 2) == 0)
var samples = Array(repeating: Int16(0), count: 320)
let result = samples.withUnsafeBufferPointer { buffer in
    guard let baseAddress = buffer.baseAddress else { return Int32(-1) }
    return SGDWebRtcVad_Process(handle, 16_000, baseAddress, buffer.count)
}
precondition(result == 0 || result == 1)
_ = try WebRTCVoiceActivityDetector(aggressiveness: .aggressive)
''', encoding="utf-8")

negative = probe_root / "negative"
(negative / "Sources/ConsumerProbe").mkdir(parents=True)
(negative / "Package.swift").write_text(manifest, encoding="utf-8")
(negative / "Sources/ConsumerProbe/main.swift").write_text('''
import CWebRTCVAD

_ = WebRtcVad_Create()
''', encoding="utf-8")

nullable_negative = probe_root / "nullable-negative"
(nullable_negative / "Sources/ConsumerProbe").mkdir(parents=True)
(nullable_negative / "Package.swift").write_text(manifest, encoding="utf-8")
(nullable_negative / "Sources/ConsumerProbe/main.swift").write_text('''
import CWebRTCVAD

let required: OpaquePointer = SGDWebRtcVad_Create()
''', encoding="utf-8")

scm_repository = probe_root / "VoiceActivityDetectionKit"
shutil.copytree(
    package_root,
    scm_repository,
    ignore=shutil.ignore_patterns(".build", ".swiftpm"),
)
scm_manifest = f'''// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebRTCVADSCMConsumerProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "{scm_repository.as_uri()}", exact: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ConsumerProbe",
            dependencies: [
                .product(
                    name: "WebRTCVoiceActivityDetection",
                    package: "VoiceActivityDetectionKit"
                )
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
'''
scm_consumer = probe_root / "scm-consumer"
(scm_consumer / "Sources/ConsumerProbe").mkdir(parents=True)
(scm_consumer / "Package.swift").write_text(scm_manifest, encoding="utf-8")
(scm_consumer / "Sources/ConsumerProbe/main.swift").write_text(
    (positive / "Sources/ConsumerProbe/main.swift").read_text(encoding="utf-8"),
    encoding="utf-8",
)
PY

swift build \
  --package-path "$probe_root/positive" \
  --scratch-path "$probe_root/positive-build" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  > "$probe_root/positive.log" 2>&1

git -C "$probe_root/VoiceActivityDetectionKit" init -q
git -C "$probe_root/VoiceActivityDetectionKit" add --all
git -C "$probe_root/VoiceActivityDetectionKit" \
  -c user.name=WebRTCVADVerifier \
  -c user.email=webrtc-vad-verifier.invalid \
  commit -qm "verification snapshot"
git -C "$probe_root/VoiceActivityDetectionKit" tag 1.0.0

swift build \
  --package-path "$probe_root/scm-consumer" \
  --scratch-path "$probe_root/scm-consumer-build" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  > "$probe_root/scm-consumer.log" 2>&1

if swift build \
  --package-path "$probe_root/negative" \
  --scratch-path "$probe_root/negative-build" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  > "$probe_root/negative.log" 2>&1; then
  echo "consumer unexpectedly compiled upstream WebRtcVad_Create" >&2
  exit 1
fi
if ! grep -q "cannot find 'WebRtcVad_Create' in scope" "$probe_root/negative.log"; then
  echo "negative consumer failed for an unexpected reason" >&2
  sed -n '1,160p' "$probe_root/negative.log" >&2
  exit 1
fi

if swift build \
  --package-path "$probe_root/nullable-negative" \
  --scratch-path "$probe_root/nullable-negative-build" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors \
  > "$probe_root/nullable-negative.log" 2>&1; then
  echo "consumer unexpectedly treated checked create as nonoptional" >&2
  exit 1
fi
if ! grep -Eq "optional type 'OpaquePointer\\?' must be unwrapped|value of optional type 'OpaquePointer\\?'" "$probe_root/nullable-negative.log"; then
  echo "nullable create consumer failed for an unexpected reason" >&2
  sed -n '1,160p' "$probe_root/nullable-negative.log" >&2
  exit 1
fi

shim_object=$(find "$probe_root/positive-build" -path '*CWebRTCVAD.build*' -name 'rtc_fatal_message.c.o' -type f | head -n 1)
wrapper_count=$(find "$probe_root/positive-build" -path '*CWebRTCVAD.build*' -name '*_wrapper.c.o' -type f | wc -l | tr -d ' ')
production_object_count=$(find "$probe_root/positive-build" -path '*CWebRTCVAD.build*' -name '*.c.o' -type f | wc -l | tr -d ' ')
if [ -z "$shim_object" ] || [ "$wrapper_count" -ne 11 ] || [ "$production_object_count" -ne 12 ]; then
  echo "expected 11 wrapper objects plus one facade object" >&2
  exit 1
fi
if find "$probe_root/positive-build" -path '*CWebRTCVAD.build*' -name 'webrtc_vad.c.o' -type f | grep -q .; then
  echo "raw upstream C source was compiled directly" >&2
  exit 1
fi
nm -m "$shim_object" > "$probe_root/shim-symbols.txt"
find "$probe_root/positive-build" \
  -path '*CWebRTCVAD.build*' \
  -name '*_wrapper.c.o' \
  -type f \
  -exec nm -m {} + > "$probe_root/upstream-symbols.txt"

for symbol in Create Init SetMode Process Free; do
  if ! grep -Eq " external _SGDWebRtcVad_${symbol}$" "$probe_root/shim-symbols.txt"; then
    echo "missing default-visible facade symbol: SGDWebRtcVad_${symbol}" >&2
    exit 1
  fi
done
if ! grep -Eq "private external _SGDWebRtcVad_CreateWithAllocator$" "$probe_root/shim-symbols.txt"; then
  echo "allocator injection seam is not hidden" >&2
  exit 1
fi
if ! grep -Eq "private external _rtc_FatalMessage$" "$probe_root/shim-symbols.txt"; then
  echo "fatal callback is not hidden" >&2
  exit 1
fi
for symbol in Create Init set_mode Process Free ValidRateAndFrameLength; do
  if ! grep -Eq "private external _WebRtcVad_${symbol}$" "$probe_root/upstream-symbols.txt"; then
    echo "upstream symbol is not hidden: WebRtcVad_${symbol}" >&2
    exit 1
  fi
done

echo "Verified external consumer facade: 5 project symbols available; checked create imports Optional; upstream WebRtcVad_Create unavailable; 11 wrapper units and internal symbols hidden; tagged SCM consumer builds"
