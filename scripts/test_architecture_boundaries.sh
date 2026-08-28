#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/private/tmp}/single-green-architecture-tests.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

syntax_fixture="$temporary_root/legal-import-syntax"
mkdir -p "$syntax_fixture"
cat >"$syntax_fixture/PackageWhole.swift" <<'SWIFT'
package import Foundation
SWIFT
cat >"$syntax_fixture/FileprivateSelective.swift" <<'SWIFT'
fileprivate import struct Foundation.Date
SWIFT
cat >"$syntax_fixture/SPIWhole.swift" <<'SWIFT'
@_spi(Testing) import Dispatch
SWIFT
cat >"$syntax_fixture/SPISelective.swift" <<'SWIFT'
@_spi(Testing) package import class Foundation.NSObject
SWIFT
for syntax_source in "$syntax_fixture"/*.swift; do
    xcrun swiftc -typecheck -package-name ArchitectureFixture "$syntax_source" >/dev/null 2>&1
done

base="$temporary_root/base"
mkdir -p "$base/config" "$base/SingleGreenDemo/Platform" "$base/SingleGreenDemo.xcodeproj"
cp "$repository_root/config/architecture-boundaries.json" "$base/config/"
cp "$repository_root/SingleGreenDemo.xcodeproj/project.pbxproj" "$base/SingleGreenDemo.xcodeproj/"
cp -R "$repository_root/SingleGreenDemo/Platform/Rendering" "$base/SingleGreenDemo/Platform/"
rsync -a --exclude '.build' --exclude '.swiftpm' "$repository_root/Packages/" "$base/Packages/"

run_check() {
    fixture=$1
    "$script_directory/check_architecture_boundaries.sh" \
        --repository-root "$fixture" \
        --config "$fixture/config/architecture-boundaries.json"
}

expect_failure() {
    fixture=$1
    pattern=$2
    output="$fixture/check-output.txt"
    if run_check "$fixture" >"$output" 2>&1; then
        echo "error: architecture fixture unexpectedly passed: $fixture" >&2
        exit 1
    fi
    if ! grep -Eq "$pattern" "$output"; then
        echo "error: architecture fixture did not report expected pattern: $pattern" >&2
        cat "$output" >&2
        exit 1
    fi
}

valid="$temporary_root/valid"
cp -R "$base" "$valid"
run_check "$valid" >/dev/null

conversation_adapters="$temporary_root/conversation-adapters-boundary"
cp -R "$base" "$conversation_adapters"
cat >"$conversation_adapters/Packages/SingleGreenConversationAdapters/Sources/SingleGreenConversationAdapters/FixtureViolation.swift" <<'SWIFT'
import SwiftUI
import VoiceActivityDetectionKit
import WebRTCVoiceActivityDetection
import CWebRTCVAD
SWIFT
expect_failure "$conversation_adapters" 'Packages/SingleGreenConversationAdapters/Sources/SingleGreenConversationAdapters/FixtureViolation.swift:1: import rule conversation-adapters-semantic-bridge-only forbids module SwiftUI'
for adapter_violation in \
    'FixtureViolation.swift:2: import rule conversation-adapters-semantic-bridge-only forbids module VoiceActivityDetectionKit' \
    'FixtureViolation.swift:3: import rule conversation-adapters-semantic-bridge-only forbids module WebRTCVoiceActivityDetection' \
    'FixtureViolation.swift:4: import rule conversation-adapters-semantic-bridge-only forbids module CWebRTCVAD'
do
    if ! grep -Fq "$adapter_violation" "$conversation_adapters/check-output.txt"; then
        echo "error: conversation adapter boundary violation was not detected: $adapter_violation" >&2
        cat "$conversation_adapters/check-output.txt" >&2
        exit 1
    fi
done

swiftui="$temporary_root/sgk-swiftui"
cp -R "$base" "$swiftui"
cat >"$swiftui/Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/FixtureViolation.swift" <<'SWIFT'
@preconcurrency import SwiftUI
@_exported import UIKit
@_implementationOnly import AVFoundation
@testable import Network
import struct SwiftUI.View
@preconcurrency import protocol UIKit.UIApplicationDelegate
package import SwiftUI
fileprivate import UIKit
@_spi(Testing) import AVFoundation
@_spi(Testing) package import class UIKit.UIView
@_spi(Testing) fileprivate import struct SwiftUI.Color
SWIFT
expect_failure "$swiftui" 'Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/FixtureViolation.swift:1: import rule single-green-core-framework-neutral forbids module SwiftUI'
for decorated_import in \
    'FixtureViolation.swift:2: import rule single-green-core-framework-neutral forbids module UIKit' \
    'FixtureViolation.swift:3: import rule single-green-core-framework-neutral forbids module AVFoundation' \
    'FixtureViolation.swift:4: import rule single-green-core-framework-neutral forbids module Network' \
    'FixtureViolation.swift:5: import rule single-green-core-framework-neutral forbids module SwiftUI' \
    'FixtureViolation.swift:6: import rule single-green-core-framework-neutral forbids module UIKit' \
    'FixtureViolation.swift:7: import rule single-green-core-framework-neutral forbids module SwiftUI' \
    'FixtureViolation.swift:8: import rule single-green-core-framework-neutral forbids module UIKit' \
    'FixtureViolation.swift:9: import rule single-green-core-framework-neutral forbids module AVFoundation' \
    'FixtureViolation.swift:10: import rule single-green-core-framework-neutral forbids module UIKit' \
    'FixtureViolation.swift:11: import rule single-green-core-framework-neutral forbids module SwiftUI'
do
    if ! grep -Fq "$decorated_import" "$swiftui/check-output.txt"; then
        echo "error: decorated import was not detected: $decorated_import" >&2
        cat "$swiftui/check-output.txt" >&2
        exit 1
    fi
done

voice_llm="$temporary_root/voice-core-llm"
cp -R "$base" "$voice_llm"
python3 - "$voice_llm/Packages/VoiceChatCore/Package.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'name: "VoiceChatCore",\n            dependencies: ["VoiceActivityDetectionKit"]'
new = 'name: "VoiceChatCore",\n            dependencies: ["VoiceActivityDetectionKit", "LLMKit"]'
if old not in text:
    raise SystemExit("fixture mutation anchor missing")
path.write_text(text.replace(old, new, 1))
PY
expect_failure "$voice_llm" 'target dependency rule: VoiceChatCore.*LLMKit'
if grep -Fq 'ASRCLI' "$voice_llm/check-output.txt" && ! grep -Fq 'VoiceChatCore' "$voice_llm/check-output.txt"; then
    echo "error: ASRCLI's reviewed LLMKit edge was incorrectly rejected" >&2
    exit 1
fi

vad_adapter="$temporary_root/vad-adapter"
cp -R "$base" "$vad_adapter"
python3 - "$vad_adapter/Packages/VoiceActivityDetectionKit/Package.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '.target(name: "VoiceActivityDetectionKit"),'
new = '.target(name: "VoiceActivityDetectionKit", dependencies: ["WebRTCVoiceActivityDetection"]),'
if old not in text:
    raise SystemExit("fixture mutation anchor missing")
path.write_text(text.replace(old, new, 1))
PY
expect_failure "$vad_adapter" 'target dependency rule: VoiceActivityDetectionKit.*WebRTCVoiceActivityDetection'

remote_dependency="$temporary_root/remote-dependency"
cp -R "$base" "$remote_dependency"
python3 - "$remote_dependency/Packages/LLMKit/Package.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'products: [\n        .library(name: "LLMKit", targets: ["LLMKit"])\n    ],'
new = old + '\n    dependencies: [.package(url: "https://example.invalid/Remote.git", exact: "1.0.0")],'
if old not in text:
    raise SystemExit("fixture mutation anchor missing")
path.write_text(text.replace(old, new, 1))
PY
expect_failure "$remote_dependency" 'remote dependency rule: LLMKit declares sourceControl'

redirected="$temporary_root/redirected-local-package"
cp -R "$base" "$redirected"
mkdir -p "$redirected/redirect"
cp -R "$redirected/Packages/VoiceChatDomain" "$redirected/redirect/VoiceChatDomain"
python3 - "$redirected/Packages/SingleGreenGlassesKit/Package.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '.package(path: "../VoiceChatDomain")'
new = '.package(path: "../../redirect/VoiceChatDomain")'
if old not in text:
    raise SystemExit("fixture mutation anchor missing")
path.write_text(text.replace(old, new, 1))
PY
expect_failure "$redirected" 'canonical local package path rule: SingleGreenGlassesKit dependency VoiceChatDomain expected .*Packages/VoiceChatDomain, got .*redirect/VoiceChatDomain'

cycle="$temporary_root/cycle"
cp -R "$base" "$cycle"
python3 - "$cycle/config/architecture-boundaries.json" "$cycle/Packages/VoiceChatDomain/Package.swift" <<'PY'
from pathlib import Path
import json
import sys
config_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
config = json.loads(config_path.read_text())
package = next(item for item in config["packages"] if item["name"] == "VoiceChatDomain")
package["local_dependencies"] = ["SingleGreenGlassesKit"]
target = next(item for item in package["targets"] if item["name"] == "VoiceChatDomain")
target["dependencies"] = ["SingleGreenGlassesKit"]
config_path.write_text(json.dumps(config, indent=2) + "\n")
text = manifest_path.read_text()
text = text.replace(
    'products: [\n        .library(name: "VoiceChatDomain", targets: ["VoiceChatDomain"])\n    ],',
    'products: [\n        .library(name: "VoiceChatDomain", targets: ["VoiceChatDomain"])\n    ],\n    dependencies: [.package(path: "../SingleGreenGlassesKit")],'
)
text = text.replace(
    '.target(name: "VoiceChatDomain"),',
    '.target(name: "VoiceChatDomain", dependencies: ["SingleGreenGlassesKit"]),',
)
manifest_path.write_text(text)
PY
expect_failure "$cycle" 'package cycle rule: .*SingleGreenGlassesKit -> VoiceChatDomain -> SingleGreenGlassesKit'

app_adapter="$temporary_root/app-rendering-adapter"
cp -R "$base" "$app_adapter"
cat >"$app_adapter/SingleGreenDemo/Platform/Rendering/FixtureViolation.swift" <<'SWIFT'
import WebRTCVoiceActivityDetection
SWIFT
expect_failure "$app_adapter" 'SingleGreenDemo/Platform/Rendering/FixtureViolation.swift:1: import rule app-rendering-does-not-own-adapters forbids module WebRTCVoiceActivityDetection'

app_link="$temporary_root/app-link-drift"
cp -R "$base" "$app_link"
python3 - "$app_link/SingleGreenDemo.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'productName = WebRTCVoiceActivityDetection;'
new = 'productName = VoiceActivityDetectionKit;'
if old not in text:
    raise SystemExit("fixture mutation anchor missing")
path.write_text(text.replace(old, new, 1))
PY
expect_failure "$app_link" 'App link rule: SingleGreenDemo expected products .*WebRTCVoiceActivityDetection.*got .*VoiceActivityDetectionKit'

remote_xcode="$temporary_root/remote-xcode-package"
cp -R "$base" "$remote_xcode"
python3 - "$remote_xcode/SingleGreenDemo.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
anchor = '/* Begin XCSwiftPackageProductDependency section */'
section = '''/* Begin XCRemoteSwiftPackageReference section */
        DEADBEEF0000000000000001 /* XCRemoteSwiftPackageReference "RemoteFixture" */ = {
            isa = XCRemoteSwiftPackageReference;
            repositoryURL = "https://example.invalid/RemoteFixture.git";
            requirement = { kind = exactVersion; version = 1.0.0; };
        };
/* End XCRemoteSwiftPackageReference section */

'''
if anchor not in text:
    raise SystemExit("fixture mutation anchor missing")
path.write_text(text.replace(anchor, section + anchor, 1))
PY
expect_failure "$remote_xcode" 'App remote package rule: XCRemoteSwiftPackageReference is forbidden'

ownership_drift="$temporary_root/app-product-ownership-drift"
cp -R "$base" "$ownership_drift"
python3 - "$ownership_drift/SingleGreenDemo.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = 'package = A00000000000000000000068 /* XCLocalSwiftPackageReference "Packages/LLMKit" */;'
new = 'package = A00000000000000000000061 /* XCLocalSwiftPackageReference "Packages/VoiceChatCore" */;'
if old not in text:
    raise SystemExit("fixture mutation anchor missing")
path.write_text(text.replace(old, new, 1))
PY
expect_failure "$ownership_drift" 'App product ownership rule: SingleGreenDemo product LLMKit expected local owner .*Packages/LLMKit.*got Packages/VoiceChatCore'

echo "Architecture boundary self-tests passed (legal import syntax, valid graph, and 11 negative fixtures)."
