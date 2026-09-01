#!/bin/sh

set -eu

usage() {
    echo "usage: $0 <Internal .app directory>" >&2
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
    echo "error: Internal artifact does not exist or is not a directory: $artifact" >&2
    exit 2
fi

info_plist="$artifact/Info.plist"
if [ ! -f "$info_plist" ]; then
    echo "error: Internal artifact is missing Info.plist: $artifact" >&2
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

if [ "$bundle_identifier" != "com.local.SingleGreenDemo.internal" ]; then
    echo "error: Internal artifact has an unexpected CFBundleIdentifier" >&2
    exit 1
fi

if [ "$display_name" != "单绿内部版" ]; then
    echo "error: Internal artifact has an unexpected CFBundleDisplayName" >&2
    exit 1
fi

capability_file="$artifact/SingleGreenInternalCapabilities.txt"
if [ ! -f "$capability_file" ]; then
    echo "error: Internal artifact is missing the reviewed capability resource" >&2
    exit 1
fi

expected_capability='diagnostics-demo-credentials-v1'
capability_contents=$(cat "$capability_file")
capability_size=$(wc -c <"$capability_file" | tr -d '[:space:]')
expected_size=$((${#expected_capability} + 1))
if [ "$capability_contents" != "$expected_capability" ] || [ "$capability_size" -ne "$expected_size" ]; then
    echo "error: Internal capability resource has unexpected content" >&2
    exit 1
fi

artifact_contains_literal() {
    marker=$1
    LC_ALL=C grep -aFR -m 1 -- "$marker" "$artifact" >/dev/null 2>&1
}

require_marker() {
    marker=$1
    description=$2
    if ! artifact_contains_literal "$marker"; then
        echo "error: Internal artifact is missing $description" >&2
        exit 1
    fi
}

# Accessibility identifiers and export header are durable evidence that the
# owner-only diagnostics surface and its export action were linked.
require_marker "DiagnosticsPanelView" "the diagnostics panel type marker"
require_marker "ConversationTelemetryStore" "the diagnostics store type marker"
require_marker "InternalVoiceActivatedDiagnosticsSession" "the VAD diagnostics implementation marker"
require_marker "vad-diagnostics-live-wiring-v2" "the VAD diagnostics live-wiring marker"
require_marker "InternalTeleprompterASRDiagnosticsSession" "the teleprompter ASR diagnostics implementation marker"
require_marker "teleprompter-asr-diagnostics-live-wiring-v1" "the teleprompter ASR diagnostics live-wiring marker"
require_marker "offline_asr_capability_check_button" "the offline ASR capability probe marker"
require_marker "diagnostics_button" "the diagnostics accessibility marker"
require_marker "diagnostics_export_button" "the diagnostics export marker"
require_marker "debug_toggle_button" "the debug-toggle accessibility marker"
require_marker "SingleGreenDemo diagnostics" "the diagnostics export header"

# These reviewed, non-secret identifiers prove that local demo credential
# storage and UI were linked. No credential value is read or printed.
require_marker "DemoKeychainCredentialProvider" "the demo credential provider marker"
require_marker "DemoSpeechCredentialProvider" "the demo speech credential provider marker"
require_marker "KeychainHelper" "the Keychain helper marker"
require_marker "demo_llm_api_key_field" "the demo credential UI marker"
require_marker "demo_asr_api_key_field" "the demo ASR credential UI marker"
require_marker "demo_search_api_key_field" "the demo search credential UI marker"

test_bundle=$(find "$artifact" \( -name '*.xctest' -o -name 'XCTest.framework' -o -name 'XCTest' \) -print -quit 2>/dev/null || true)
if [ -n "$test_bundle" ]; then
    echo "error: Internal artifact embeds a test bundle or XCTest runtime" >&2
    exit 1
fi

if LC_ALL=C grep -aEr -m 1 -- 'XCTest' "$artifact" >/dev/null 2>&1; then
    echo "error: Internal artifact contains an XCTest marker" >&2
    exit 1
fi

echo "Internal artifact capability check passed."
