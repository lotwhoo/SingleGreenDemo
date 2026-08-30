#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
user_check="$script_dir/check_user_artifact_isolation.sh"
internal_check="$script_dir/check_internal_artifact_capabilities.sh"

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-flavor-checks.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM

pass_count=0

write_info_plist() {
    destination=$1
    bundle_identifier=$2
    display_name=$3

    mkdir -p "$destination"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0">'
        echo '<dict>'
        echo '    <key>CFBundleExecutable</key>'
        echo '    <string>SingleGreenDemo</string>'
        echo '    <key>CFBundleIdentifier</key>'
        printf '    <string>%s</string>\n' "$bundle_identifier"
        echo '    <key>CFBundleDisplayName</key>'
        printf '    <string>%s</string>\n' "$display_name"
        echo '</dict>'
        echo '</plist>'
    } >"$destination/Info.plist"
}

write_user_fixture() {
    destination=$1
    bundle_identifier=${2-com.local.SingleGreenDemo}
    display_name=${3-单绿测试平台}
    write_info_plist "$destination" "$bundle_identifier" "$display_name"
    printf '%s\n' 'SingleGreenDemo user executable fixture' >"$destination/SingleGreenDemo"
}

write_internal_fixture() {
    destination=$1
    bundle_identifier=${2-com.local.SingleGreenDemo.internal}
    display_name=${3-单绿内部版}
    write_info_plist "$destination" "$bundle_identifier" "$display_name"
    printf '%s\n' 'diagnostics-demo-credentials-v1' >"$destination/SingleGreenInternalCapabilities.txt"
    {
        echo 'SingleGreenDemo internal executable fixture'
        echo 'diagnostics_button'
        echo 'diagnostics_export_button'
        echo 'debug_toggle_button'
        echo 'DiagnosticsPanelView'
        echo 'ConversationTelemetryStore'
        echo 'SingleGreenDemo diagnostics'
        echo 'DemoKeychainCredentialProvider'
        echo 'DemoSpeechCredentialProvider'
        echo 'KeychainHelper'
        echo 'demo_llm_api_key_field'
        echo 'demo_asr_api_key_field'
        echo 'demo_search_api_key_field'
    } >"$destination/SingleGreenDemo"
}

expect_pass() {
    description=$1
    shift
    if "$@" >"$temp_root/last.stdout" 2>"$temp_root/last.stderr"; then
        pass_count=$((pass_count + 1))
        return
    fi
    echo "FAIL: expected success: $description" >&2
    sed -n '1,80p' "$temp_root/last.stderr" >&2
    exit 1
}

expect_fail() {
    description=$1
    shift
    if "$@" >"$temp_root/last.stdout" 2>"$temp_root/last.stderr"; then
        echo "FAIL: expected rejection: $description" >&2
        exit 1
    fi
    pass_count=$((pass_count + 1))
}

expect_fail "User checker rejects no arguments" "$user_check"
expect_fail "User checker rejects more than one argument" "$user_check" one.app two.app
expect_fail "User checker rejects a non-app path" "$user_check" "$temp_root/not-an-app"
expect_fail "Internal checker rejects no arguments" "$internal_check"
expect_fail "Internal checker rejects more than one argument" "$internal_check" one.app two.app
expect_fail "Internal checker rejects a non-app path" "$internal_check" "$temp_root/not-an-app"

user_safe="$temp_root/UserSafe.app"
write_user_fixture "$user_safe"
expect_pass "User artifact without owner-only capabilities" "$user_check" "$user_safe"

user_bad_bundle="$temp_root/UserBadBundle.app"
write_user_fixture "$user_bad_bundle" "com.local.SingleGreenDemo.internal"
expect_fail "User artifact with internal bundle identity" "$user_check" "$user_bad_bundle"

user_bad_name="$temp_root/UserBadName.app"
write_user_fixture "$user_bad_name" "com.local.SingleGreenDemo" "单绿内部版"
expect_fail "User artifact with internal display name" "$user_check" "$user_bad_name"

user_capability="$temp_root/UserCapability.app"
write_user_fixture "$user_capability"
printf '%s\n' 'diagnostics-demo-credentials-v1' >"$user_capability/SingleGreenInternalCapabilities.txt"
expect_fail "User artifact with internal capability resource" "$user_check" "$user_capability"

user_capability_marker="$temp_root/UserCapabilityMarker.app"
write_user_fixture "$user_capability_marker"
printf '%s\n' 'diagnostics-demo-credentials-v1' >>"$user_capability_marker/SingleGreenDemo"
expect_fail "User artifact with internal capability marker bytes" "$user_check" "$user_capability_marker"

user_diagnostics="$temp_root/UserDiagnostics.app"
write_user_fixture "$user_diagnostics"
printf '%s\n' 'diagnostics_export_button' >>"$user_diagnostics/SingleGreenDemo"
expect_fail "User artifact with diagnostics marker" "$user_check" "$user_diagnostics"

user_export_type="$temp_root/UserExportType.app"
write_user_fixture "$user_export_type"
printf '%s\n' 'ConversationTelemetryStore' >>"$user_export_type/SingleGreenDemo"
expect_fail "User artifact with diagnostics implementation type" "$user_check" "$user_export_type"

user_credentials="$temp_root/UserCredentials.app"
write_user_fixture "$user_credentials"
printf '%s\n' 'DemoCredentialStore' >>"$user_credentials/SingleGreenDemo"
expect_fail "User artifact with demo credential marker" "$user_check" "$user_credentials"

user_tests="$temp_root/UserTests.app"
write_user_fixture "$user_tests"
mkdir -p "$user_tests/PlugIns/SingleGreenDemoTests.xctest"
expect_fail "User artifact with embedded test bundle" "$user_check" "$user_tests"

user_xctest="$temp_root/UserXCTest.app"
write_user_fixture "$user_xctest"
printf '%s\n' 'XCTestCase' >>"$user_xctest/SingleGreenDemo"
expect_fail "User artifact with linked XCTest marker" "$user_check" "$user_xctest"

internal_safe="$temp_root/InternalSafe.app"
write_internal_fixture "$internal_safe"
expect_pass "Internal artifact with reviewed capabilities" "$internal_check" "$internal_safe"

internal_bad_bundle="$temp_root/InternalBadBundle.app"
write_internal_fixture "$internal_bad_bundle" "com.local.SingleGreenDemo"
expect_fail "Internal artifact with User bundle identity" "$internal_check" "$internal_bad_bundle"

internal_bad_name="$temp_root/InternalBadName.app"
write_internal_fixture "$internal_bad_name" "com.local.SingleGreenDemo.internal" "单绿测试平台"
expect_fail "Internal artifact with User display name" "$internal_check" "$internal_bad_name"

internal_no_capability="$temp_root/InternalNoCapability.app"
write_internal_fixture "$internal_no_capability"
rm "$internal_no_capability/SingleGreenInternalCapabilities.txt"
expect_fail "Internal artifact without reviewed capability resource" "$internal_check" "$internal_no_capability"

internal_wrong_capability="$temp_root/InternalWrongCapability.app"
write_internal_fixture "$internal_wrong_capability"
printf '%s\n' 'unreviewed-capability' >"$internal_wrong_capability/SingleGreenInternalCapabilities.txt"
expect_fail "Internal artifact with an unreviewed capability resource" "$internal_check" "$internal_wrong_capability"

internal_extra_capability_content="$temp_root/InternalExtraCapabilityContent.app"
write_internal_fixture "$internal_extra_capability_content"
printf '\n' >>"$internal_extra_capability_content/SingleGreenInternalCapabilities.txt"
expect_fail "Internal artifact with extra capability resource content" "$internal_check" "$internal_extra_capability_content"

internal_no_diagnostics="$temp_root/InternalNoDiagnostics.app"
write_internal_fixture "$internal_no_diagnostics"
grep -v 'DiagnosticsPanelView' "$internal_no_diagnostics/SingleGreenDemo" >"$temp_root/internal-no-diagnostics"
mv "$temp_root/internal-no-diagnostics" "$internal_no_diagnostics/SingleGreenDemo"
expect_fail "Internal artifact without diagnostics implementation marker" "$internal_check" "$internal_no_diagnostics"

internal_no_export="$temp_root/InternalNoExport.app"
write_internal_fixture "$internal_no_export"
grep -v 'diagnostics_export_button' "$internal_no_export/SingleGreenDemo" >"$temp_root/internal-no-export"
mv "$temp_root/internal-no-export" "$internal_no_export/SingleGreenDemo"
expect_fail "Internal artifact without diagnostics export marker" "$internal_check" "$internal_no_export"

internal_no_credentials="$temp_root/InternalNoCredentials.app"
write_internal_fixture "$internal_no_credentials"
grep -v 'DemoKeychainCredentialProvider' "$internal_no_credentials/SingleGreenDemo" >"$temp_root/internal-no-credentials"
mv "$temp_root/internal-no-credentials" "$internal_no_credentials/SingleGreenDemo"
expect_fail "Internal artifact without demo credential provider marker" "$internal_check" "$internal_no_credentials"

internal_no_credential_ui="$temp_root/InternalNoCredentialUI.app"
write_internal_fixture "$internal_no_credential_ui"
grep -v 'demo_llm_api_key_field' "$internal_no_credential_ui/SingleGreenDemo" >"$temp_root/internal-no-credential-ui"
mv "$temp_root/internal-no-credential-ui" "$internal_no_credential_ui/SingleGreenDemo"
expect_fail "Internal artifact without demo LLM credential UI marker" "$internal_check" "$internal_no_credential_ui"

internal_no_speech_provider="$temp_root/InternalNoSpeechProvider.app"
write_internal_fixture "$internal_no_speech_provider"
grep -v 'DemoSpeechCredentialProvider' "$internal_no_speech_provider/SingleGreenDemo" >"$temp_root/internal-no-speech-provider"
mv "$temp_root/internal-no-speech-provider" "$internal_no_speech_provider/SingleGreenDemo"
expect_fail "Internal artifact without demo speech credential provider marker" "$internal_check" "$internal_no_speech_provider"

internal_no_keychain="$temp_root/InternalNoKeychain.app"
write_internal_fixture "$internal_no_keychain"
grep -v 'KeychainHelper' "$internal_no_keychain/SingleGreenDemo" >"$temp_root/internal-no-keychain"
mv "$temp_root/internal-no-keychain" "$internal_no_keychain/SingleGreenDemo"
expect_fail "Internal artifact without Keychain helper marker" "$internal_check" "$internal_no_keychain"

internal_no_asr_ui="$temp_root/InternalNoASRUI.app"
write_internal_fixture "$internal_no_asr_ui"
grep -v 'demo_asr_api_key_field' "$internal_no_asr_ui/SingleGreenDemo" >"$temp_root/internal-no-asr-ui"
mv "$temp_root/internal-no-asr-ui" "$internal_no_asr_ui/SingleGreenDemo"
expect_fail "Internal artifact without demo ASR credential UI marker" "$internal_check" "$internal_no_asr_ui"

internal_no_search_ui="$temp_root/InternalNoSearchUI.app"
write_internal_fixture "$internal_no_search_ui"
grep -v 'demo_search_api_key_field' "$internal_no_search_ui/SingleGreenDemo" >"$temp_root/internal-no-search-ui"
mv "$temp_root/internal-no-search-ui" "$internal_no_search_ui/SingleGreenDemo"
expect_fail "Internal artifact without demo search credential UI marker" "$internal_check" "$internal_no_search_ui"

internal_tests="$temp_root/InternalTests.app"
write_internal_fixture "$internal_tests"
mkdir -p "$internal_tests/PlugIns/SingleGreenDemoTests.xctest"
expect_fail "Internal artifact with embedded test bundle" "$internal_check" "$internal_tests"

echo "Build flavor checker tests passed: $pass_count cases."
