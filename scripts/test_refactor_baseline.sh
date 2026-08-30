#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
collector="$script_directory/collect_refactor_baseline.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-baseline-test.XXXXXX")
trap 'rm -rf -- "$fixture_root"' EXIT HUP INT TERM

repository="$fixture_root/repository"
fake_bin="$fixture_root/bin"
mkdir -p \
    "$repository/Packages/Alpha/Sources/Alpha" \
    "$repository/Packages/Alpha/Tests/AlphaTests" \
    "$repository/App" \
    "$repository/AppTests" \
    "$repository/DerivedData" \
    "$repository/Fixture.xcodeproj/xcshareddata/xcschemes" \
    "$repository/Configurations" \
    "$fake_bin"

printf '%s\n' '// manifest' > "$repository/Packages/Alpha/Package.swift"
printf '%s\n' 'struct Alpha {' '    let value: Int' '}' > "$repository/Packages/Alpha/Sources/Alpha/Alpha.swift"
printf '%s\n' 'import XCTest' 'final class AlphaTests: XCTestCase {}' > "$repository/Packages/Alpha/Tests/AlphaTests/AlphaTests.swift"
printf '%s\n' 'struct Feature {' '    let first: Int' '    let second: Int' '}' > "$repository/App/Feature.swift"
printf '%s\n' 'final class AppTests {}' > "$repository/AppTests/AppTests.swift"
printf '%s\n' 'this generated file must be ignored' > "$repository/DerivedData/Generated.swift"
printf '%s\n' \
    '/* Begin XCBuildConfiguration section */' \
    'name = Debug;' \
    'name = Release;' \
    '/* End XCBuildConfiguration section */' \
    > "$repository/Fixture.xcodeproj/project.pbxproj"
printf '%s\n' '<Scheme version="1.7"></Scheme>' > "$repository/Fixture.xcodeproj/xcshareddata/xcschemes/Fixture.xcscheme"
printf '%s\n' \
    'SWIFT_VERSION = 6.0' \
    'PRIVATE_SETTING = PRIVATE_SENTINEL_VALUE' \
    > "$repository/Configurations/Base.xcconfig"

cat > "$fake_bin/xcodebuild" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"project":{"configurations":["Debug","Release"],"schemes":["Alpha","Fixture"]}}
JSON
EOF
chmod +x "$fake_bin/xcodebuild"

git -C "$repository" init -q
git -C "$repository" add Packages App AppTests Fixture.xcodeproj Configurations DerivedData
git -C "$repository" -c user.name='Baseline Test' -c user.email='baseline@example.invalid' commit -qm 'fixture'
git -C "$repository" branch -M fixture-main

first_report="$fixture_root/first.md"
PATH="$fake_bin:$PATH" BASELINE_TIMESTAMP='2026-08-30T00:00:00Z' \
    "$collector" --repo-root "$repository" --output "$first_report" >/dev/null

assert_contains() {
    expected=$1
    file=$2
    if ! grep -Fq -- "$expected" "$file"; then
        echo "error: expected report text was not found: $expected" >&2
        exit 1
    fi
}

assert_not_contains() {
    unexpected=$1
    file=$2
    if grep -Fq -- "$unexpected" "$file"; then
        echo "error: unexpected report text was found: $unexpected" >&2
        exit 1
    fi
}

assert_contains '| Branch | `fixture-main` |' "$first_report"
assert_contains '| Working tree | clean |' "$first_report"
assert_contains '| Production | 2 | 7 |' "$first_report"
assert_contains '| Test | 2 | 3 |' "$first_report"
assert_contains '| 4 | `App/Feature.swift` |' "$first_report"
assert_contains '- `Packages/Alpha`' "$first_report"
assert_contains '- `Debug`' "$first_report"
assert_contains '- `Release`' "$first_report"
assert_contains '- `Alpha`' "$first_report"
assert_contains '- `Fixture`' "$first_report"
assert_contains '- `Configurations/Base.xcconfig`' "$first_report"
assert_not_contains 'DerivedData/Generated.swift' "$first_report"
assert_not_contains 'Package.swift` |' "$first_report"
assert_not_contains 'PRIVATE_SENTINEL_VALUE' "$first_report"

# A failing xcodebuild must fall back to project metadata and tracked schemes.
cat > "$fake_bin/xcodebuild" <<'EOF'
#!/bin/sh
exit 9
EOF
chmod +x "$fake_bin/xcodebuild"

failing_xcodebuild_report="$fixture_root/failing-xcodebuild.md"
PATH="$fake_bin:$PATH" BASELINE_TIMESTAMP='2026-08-30T00:00:00Z' \
    "$collector" --repo-root "$repository" --output "$failing_xcodebuild_report" >/dev/null

assert_contains 'Discovery: project file.' "$failing_xcodebuild_report"
assert_contains 'Discovery: tracked shared schemes.' "$failing_xcodebuild_report"
assert_contains '- `Debug`' "$failing_xcodebuild_report"
assert_contains '- `Release`' "$failing_xcodebuild_report"
assert_contains '- `Fixture`' "$failing_xcodebuild_report"
assert_not_contains '- `Alpha`' "$failing_xcodebuild_report"
assert_not_contains 'PRIVATE_SENTINEL_VALUE' "$failing_xcodebuild_report"

# Successful execution with invalid JSON must use the same deterministic fallback.
cat > "$fake_bin/xcodebuild" <<'EOF'
#!/bin/sh
printf '%s\n' 'not-json'
EOF
chmod +x "$fake_bin/xcodebuild"

invalid_json_report="$fixture_root/invalid-json.md"
PATH="$fake_bin:$PATH" BASELINE_TIMESTAMP='2026-08-30T00:00:00Z' \
    "$collector" --repo-root "$repository" --output "$invalid_json_report" >/dev/null

assert_contains 'Discovery: project file.' "$invalid_json_report"
assert_contains 'Discovery: tracked shared schemes.' "$invalid_json_report"
assert_contains '- `Debug`' "$invalid_json_report"
assert_contains '- `Release`' "$invalid_json_report"
assert_contains '- `Fixture`' "$invalid_json_report"
assert_not_contains '- `Alpha`' "$invalid_json_report"
assert_not_contains 'PRIVATE_SENTINEL_VALUE' "$invalid_json_report"

# Mutate one tracked production file and verify that both inventory and Git state change.
printf '%s\n' 'extension Feature {}' >> "$repository/App/Feature.swift"
second_report="$fixture_root/second.md"
PATH="$fake_bin:$PATH" BASELINE_TIMESTAMP='2026-08-30T00:00:00Z' \
    "$collector" --repo-root "$repository" --output "$second_report" >/dev/null

assert_contains '| Working tree | dirty (1 change entries) |' "$second_report"
assert_contains '| Production | 2 | 8 |' "$second_report"
assert_contains '| 5 | `App/Feature.swift` |' "$second_report"

# Omitting --output must create the report outside the repository.
default_result=$(PATH="$fake_bin:$PATH" BASELINE_TIMESTAMP='2026-08-30T00:00:00Z' \
    "$collector" --repo-root "$repository")
default_report=${default_result#Baseline report written to: }
case "$default_report" in
    "$repository"/*)
        echo "error: default report was created inside the repository" >&2
        exit 1
        ;;
esac
[ -f "$default_report" ] || { echo "error: default report was not created" >&2; exit 1; }
rm -f -- "$default_report"

echo "Refactor baseline collector tests passed."
