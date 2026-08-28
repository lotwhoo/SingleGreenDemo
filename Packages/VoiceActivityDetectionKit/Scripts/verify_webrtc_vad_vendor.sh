#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

python3 - "$package_root" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
manifest_path = root / "ThirdParty/WebRTC/provenance.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

expected_identity = {
    "dependency": "webrtc-vad-minimal",
    "remote": "https://webrtc.googlesource.com/src",
    "commit": "1e7f4c3c39e1aacaf8884452f80cd82749b1f8f1",
    "tree": "9e1c614027e41b4885cb3712cd9b2444388fac73",
}
for key, expected in expected_identity.items():
    actual = manifest.get(key)
    if actual != expected:
        raise SystemExit(f"provenance mismatch for {key}: {actual!r}")

groups = {
    "sourceFiles": 11,
    "headerFiles": 12,
    "projectFiles": 13,
    "legalFiles": 5,
}
listed = []
for group, count in groups.items():
    entries = manifest.get(group)
    if not isinstance(entries, list) or len(entries) != count:
        raise SystemExit(f"{group} must contain exactly {count} entries")
    for entry in entries:
        relative = entry.get("path", "")
        digest = entry.get("sha256", "")
        if not relative or pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
            raise SystemExit(f"unsafe path in {group}: {relative!r}")
        path = root / relative
        if not path.is_file():
            raise SystemExit(f"missing vendored file: {relative}")
        actual_digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual_digest != digest:
            raise SystemExit(f"SHA-256 mismatch: {relative}")
        listed.append(relative)

if len(listed) != len(set(listed)):
    raise SystemExit("manifest contains duplicate paths")

source_root = root / "Sources/CWebRTCVAD"
actual_c = sorted(str(path.relative_to(root)) for path in source_root.rglob("*.c"))
actual_h = sorted(str(path.relative_to(root)) for path in source_root.rglob("*.h"))
expected_c = sorted(
    entry["path"]
    for entry in manifest["sourceFiles"] + manifest["projectFiles"]
    if entry["path"].endswith(".c")
)
expected_h = sorted(
    entry["path"]
    for entry in manifest["headerFiles"] + manifest["projectFiles"]
    if entry["path"].endswith(".h")
)
if actual_c != expected_c:
    raise SystemExit(f"unexpected C file inventory: {actual_c}")
if actual_h != expected_h:
    raise SystemExit(f"unexpected header inventory: {actual_h}")

for forbidden in ("min_max_operations.c", "resample_by_2.c", "spl_init.c"):
    if any(pathlib.PurePosixPath(path).name == forbidden for path in actual_c):
        raise SystemExit(f"probe-only source is forbidden: {forbidden}")

if not all(entry.get("upstream") is True for entry in manifest["sourceFiles"] + manifest["headerFiles"]):
    raise SystemExit("upstream source/header entries must be marked upstream=true")
if not all(entry.get("upstream") is False for entry in manifest["projectFiles"]):
    raise SystemExit("project file entries must be marked upstream=false")

upstream_sources = {
    (root / entry["path"]).resolve()
    for entry in manifest["sourceFiles"]
}
wrappers = [
    root / entry["path"]
    for entry in manifest["projectFiles"]
    if "/CompilationUnits/" in entry["path"]
]
if len(wrappers) != 11:
    raise SystemExit("exactly 11 one-source visibility wrappers are required")
included_sources = set()
for wrapper in wrappers:
    lines = wrapper.read_text(encoding="utf-8").splitlines()
    if len(lines) != 3:
        raise SystemExit(f"wrapper must contain exactly three lines: {wrapper}")
    if lines[0] != "#pragma GCC visibility push(hidden)" or lines[2] != "#pragma GCC visibility pop":
        raise SystemExit(f"wrapper must bracket its source with hidden visibility: {wrapper}")
    match = __import__("re").fullmatch(r'#include "([^"]+\.c)"', lines[1])
    if match is None:
        raise SystemExit(f"wrapper must include exactly one upstream C file: {wrapper}")
    included = (wrapper.parent / match.group(1)).resolve()
    if included not in upstream_sources:
        raise SystemExit(f"wrapper includes an unapproved source: {wrapper}")
    if included in included_sources:
        raise SystemExit(f"upstream source is included by multiple wrappers: {included}")
    included_sources.add(included)
if included_sources != upstream_sources:
    raise SystemExit("every upstream C file must compile through exactly one wrapper")

fatal_source = (root / "Sources/CWebRTCVAD/rtc_fatal_message.c").read_text(encoding="utf-8")
if "abort();" not in fatal_source or "fprintf" in fatal_source or "printf" in fatal_source:
    raise SystemExit("fatal compatibility policy must terminate without logging")

public_header = (root / "Sources/CWebRTCVAD/include/CWebRTCVAD.h").read_text(encoding="utf-8")
if "SGDWebRTCVADHandle* _Nullable\nSGDWebRtcVad_Create(void);" not in public_header:
    raise SystemExit("checked create must declare a nullable return")

api_input = manifest.get("apiInput", {})
if api_input != {
    "sampleRateHz": 16000,
    "frameMs": 20,
    "sampleCount": 320,
    "channelCount": 1,
    "encoding": "signed-int16-little-endian",
}:
    raise SystemExit("unexpected production input contract")

compiler = manifest.get("compiler", {})
if compiler.get("vendor") != "Apple clang" or compiler.get("language") != "C11":
    raise SystemExit("unexpected compiler contract")
if compiler.get("productUnsafeFlags") != []:
    raise SystemExit("product dependency graph must not contain unsafe flags")
if compiler.get("verificationFlags") != ["-Wall", "-Wextra", "-Wpedantic", "-Werror"]:
    raise SystemExit("unexpected C warning policy")

package_manifest = (root / "Package.swift").read_text(encoding="utf-8")
if "cLanguageStandard: .c11" not in package_manifest:
    raise SystemExit("Package.swift must select C11")
if ".unsafeFlags" in package_manifest:
    raise SystemExit("Package.swift must remain consumable from a tagged Git dependency")
for source in manifest["sourceFiles"]:
    excluded = source["path"].removeprefix("Sources/CWebRTCVAD/")
    if f'"{excluded}"' not in package_manifest:
        raise SystemExit(f"upstream C source must be excluded from direct compilation: {excluded}")

build_script_path = root / "Scripts/verify_webrtc_vad_builds.sh"
if not build_script_path.is_file() or build_script_path.stat().st_mode & 0o111 == 0:
    raise SystemExit("three-triple build verifier must exist and be executable")
build_script = build_script_path.read_text(encoding="utf-8")
for required in (
    "iphoneos-arm64",
    "simulator-arm64",
    "simulator-x86_64",
    "-Wall -Wextra -Wpedantic -Werror",
):
    if required not in build_script:
        raise SystemExit(f"build verifier is missing required gate: {required}")

print("Verified WebRTC VAD vendor closure: 11 upstream C, 12 upstream headers, 12 project C, 1 project header, 5 legal files")
PY
