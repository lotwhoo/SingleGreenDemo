#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture_root=$(mktemp -d /private/tmp/SingleGreenDemo-CoverageSelection.XXXXXX)
fake_bin="$fixture_root/bin"
mkdir -p "$fake_bin"

cleanup() {
    rm -rf "$fixture_root"
}
trap cleanup EXIT HUP INT TERM

cat > "$fake_bin/swift" <<'SH'
#!/bin/sh
case " $* " in
    *" --show-codecov-path "*)
        printf '%s\n' "$FAKE_COVERAGE_EXPORT"
        ;;
esac
SH

cat > "$fake_bin/python3" <<'SH'
#!/bin/sh
report=${4:?missing report path}
printf '%s\n' 'fixture coverage report' > "$report"
printf '%s\n' '100.00'
SH

chmod +x "$fake_bin/swift" "$fake_bin/python3"
export PATH="$fake_bin:$PATH"
export FAKE_COVERAGE_EXPORT="$fixture_root/codecov.json"
printf '%s\n' '{}' > "$FAKE_COVERAGE_EXPORT"

selected_output="$fixture_root/selected"
"$script_directory/coverage_gate.sh" "$selected_output" LLMKit VoiceChatCore >/dev/null
selected_rows=$(wc -l < "$selected_output/summary.tsv" | tr -d ' ')
[ "$selected_rows" = 3 ] || {
    echo "error: selected coverage summary should contain header plus two packages" >&2
    exit 1
}
grep -q '^LLMKit[[:space:]]100.00[[:space:]]60$' "$selected_output/summary.tsv"
grep -q '^VoiceChatCore[[:space:]]100.00[[:space:]]55$' "$selected_output/summary.tsv"

full_output="$fixture_root/full"
"$script_directory/coverage_gate.sh" "$full_output" >/dev/null
full_rows=$(wc -l < "$full_output/summary.tsv" | tr -d ' ')
[ "$full_rows" = 8 ] || {
    echo "error: no package selection must preserve the full seven-package gate" >&2
    exit 1
}

unknown_output="$fixture_root/unknown"
if "$script_directory/coverage_gate.sh" "$unknown_output" UnknownPackage >/dev/null 2>&1; then
    echo "error: unknown coverage package was accepted" >&2
    exit 1
fi
[ ! -e "$unknown_output" ] || {
    echo "error: unknown selection created an output directory before validation" >&2
    exit 1
}

duplicate_output="$fixture_root/duplicate"
if "$script_directory/coverage_gate.sh" "$duplicate_output" LLMKit LLMKit >/dev/null 2>&1; then
    echo "error: duplicate coverage package was accepted" >&2
    exit 1
fi
[ ! -e "$duplicate_output" ] || {
    echo "error: duplicate selection created an output directory before validation" >&2
    exit 1
}

echo "Coverage gate selection tests passed."
