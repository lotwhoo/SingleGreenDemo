#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
checker=$script_dir/check_build_documentation.sh
test_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-build-docs-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fixture_root=$test_root/repository
project_list_fixture=$test_root/project-list.json
mkdir -p "$fixture_root/docs"

passed=0
failed=0

write_project_list() {
    schemes=$1
    configurations=$2
    printf '%s\n' "{\"project\":{\"name\":\"SingleGreenDemo\",\"schemes\":$schemes,\"configurations\":$configurations,\"targets\":[\"SingleGreenDemo\",\"SingleGreenDemoTests\"]}}" > "$project_list_fixture"
}

write_current_project_list() {
    write_project_list \
        '["SingleGreenUser","SingleGreenInternal","SingleGreenGlassesKit"]' \
        '["User-Debug","User-Release","Internal-Debug","Internal-Release"]'
}

write_clean_documentation() {
    for relative_path in \
        AGENTS.md \
        README.md \
        docs/STREAMING_MODULES_UPGRADE_GUIDE.md \
        docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md
    do
        printf '%s\n' \
            '# Build instructions' \
            '' \
            '```bash' \
            'xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenUser \' \
            '  -configuration User-Release build' \
            '```' > "$fixture_root/$relative_path"
    done
}

run_checker() {
    BUILD_DOCUMENTATION_ROOT=$fixture_root \
    BUILD_DOCUMENTATION_XCODE_LIST_FIXTURE=$project_list_fixture \
        "$checker"
}

expect_pass() {
    test_name=$1
    if output=$(run_checker 2>&1); then
        passed=$((passed + 1))
        printf 'ok - %s\n' "$test_name"
    else
        failed=$((failed + 1))
        printf 'not ok - %s\n%s\n' "$test_name" "$output" >&2
    fi
}

expect_failure_containing() {
    test_name=$1
    expected_text=$2

    if output=$(run_checker 2>&1); then
        failed=$((failed + 1))
        printf 'not ok - %s (unexpected pass)\n' "$test_name" >&2
    elif printf '%s\n' "$output" | grep -F "$expected_text" >/dev/null 2>&1; then
        passed=$((passed + 1))
        printf 'ok - %s\n' "$test_name"
    else
        failed=$((failed + 1))
        printf 'not ok - %s (missing expected diagnostic: %s)\n%s\n' "$test_name" "$expected_text" "$output" >&2
    fi
}

write_current_project_list
write_clean_documentation
expect_pass 'current schemes and configurations pass'

printf '%s\n' \
    '# Stale current command' \
    '```bash' \
    'xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenDemo build' \
    '```' > "$fixture_root/README.md"
expect_failure_containing 'nonexistent scheme mutation fails' 'nonexistent scheme SingleGreenDemo'

write_clean_documentation
printf '%s\n' \
    '# Stale current command' \
    '```sh' \
    'xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenUser -configuration Release build' \
    '```' > "$fixture_root/docs/STREAMING_MODULES_UPGRADE_GUIDE.md"
expect_failure_containing 'bare Release configuration mutation fails' 'bare Debug/Release configuration'

write_clean_documentation
printf '%s\n' \
    '# Historical note' \
    '' \
    'Before PR-02, `xcodebuild -scheme SingleGreenDemo -configuration Debug build` was the documented command.' > "$fixture_root/AGENTS.md"
expect_pass 'historical prose outside runnable blocks is allowed'

write_clean_documentation
write_project_list \
    '["SingleGreenUser","SingleGreenGlassesKit"]' \
    '["User-Debug","User-Release","Internal-Debug","Internal-Release"]'
expect_failure_containing 'missing internal scheme fails' "required scheme 'SingleGreenInternal'"

write_current_project_list
write_project_list \
    '["SingleGreenUser","SingleGreenInternal"]' \
    '["Debug","Release","Internal-Debug","Internal-Release"]'
expect_failure_containing 'configuration set mutation fails' "required configuration 'User-Debug'"

total=$((passed + failed))
printf '%s\n' "Build documentation regression tests: $passed/$total passed."

if [ "$failed" -ne 0 ]; then
    exit 1
fi
