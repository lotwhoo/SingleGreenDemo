#!/bin/sh

set -eu

usage() {
    echo "usage: $0 <User .app directory>" >&2
    exit 2
}

if [ "$#" -ne 1 ]; then
    usage
fi

artifact=$1
case "$artifact" in
    *.app) ;;
    *)
        echo "error: expected exactly one .app directory: $artifact" >&2
        exit 2
        ;;
esac

if [ ! -d "$artifact" ]; then
    echo "error: User artifact does not exist or is not a directory: $artifact" >&2
    exit 2
fi

info_plist="$artifact/Info.plist"
if [ ! -f "$info_plist" ]; then
    echo "error: User artifact is missing Info.plist: $artifact" >&2
    exit 2
fi

plist_buddy=/usr/libexec/PlistBuddy
if [ ! -x "$plist_buddy" ]; then
    echo "error: /usr/libexec/PlistBuddy is required to inspect the app identity" >&2
    exit 2
fi

plist_value() {
    "$plist_buddy" -c "Print :$1" "$info_plist" 2>/dev/null
}

bundle_identifier=$(plist_value CFBundleIdentifier || true)
display_name=$(plist_value CFBundleDisplayName || true)

if [ "$bundle_identifier" != "com.local.SingleGreenDemo" ]; then
    echo "error: User artifact has an unexpected CFBundleIdentifier" >&2
    exit 1
fi

if [ "$display_name" != "单绿测试平台" ]; then
    echo "error: User artifact has an unexpected CFBundleDisplayName" >&2
    exit 1
fi

capability_file="$artifact/SingleGreenInternalCapabilities.txt"
if [ -e "$capability_file" ]; then
    echo "error: User artifact contains the internal capability resource" >&2
    exit 1
fi

artifact_contains_pattern() {
    pattern=$1
    LC_ALL=C grep -aEr -m 1 -- "$pattern" "$artifact" >/dev/null 2>&1
}

internal_patterns='diagnostics-demo-credentials-v1|DiagnosticsPanelView|ConversationTelemetryStore|DiagnosticsExportItem|DiagnosticsExportError|ActivityShareView|InternalVoiceActivatedDiagnosticsSession|vad-diagnostics-live-wiring-v[12]|InternalTeleprompterASRDiagnosticsSession|teleprompter-asr-diagnostics-live-wiring-v1|offline_asr_capability_check_button|diagnosticLines|removeAllDiagnostics|diagnostics_button|diagnostics_export_button|debug_toggle_button|SingleGreenDemo diagnostics|makeExportURL|Debug 与日志|导出全部日志|日志导出失败'
if artifact_contains_pattern "$internal_patterns"; then
    echo "error: User artifact contains an internal diagnostics or export marker" >&2
    exit 1
fi

test_bundle=$(find "$artifact" \( -name '*.xctest' -o -name 'XCTest.framework' -o -name 'XCTest' \) -print -quit 2>/dev/null || true)
if [ -n "$test_bundle" ]; then
    echo "error: User artifact embeds a test bundle or XCTest runtime" >&2
    exit 1
fi

if artifact_contains_pattern 'XCTest'; then
    echo "error: User artifact contains an XCTest marker" >&2
    exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
"$script_dir/check_release_credential_isolation.sh" "$artifact"

echo "User artifact isolation check passed."
