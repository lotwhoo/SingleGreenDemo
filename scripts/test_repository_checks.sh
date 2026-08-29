#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fixture_directory=$(mktemp -d "${TMPDIR:-/tmp}/single-green-scan.XXXXXX")
trap 'rm -rf "$fixture_directory"' EXIT HUP INT TERM

safe_directory="$fixture_directory/safe"
binary_secret_directory="$fixture_directory/binary-secret"
text_secret_directory="$fixture_directory/text-secret"
mkdir -p "$safe_directory" "$binary_secret_directory" "$text_secret_directory"

printf '%s\n' 'ordinary fixture text' > "$safe_directory/safe.txt"
printf '\000%s\n' 'ordinary binary fixture bytes' > "$safe_directory/binary.data"
"$script_directory/scan_secrets.sh" --root "$safe_directory" >/dev/null

printf '\000%s%s %s%s' 'Bear' 'er' 'binary_fixture_' 'abcdefghijklmnopqrstuvwxyz' \
    > "$binary_secret_directory/unsafe.data"
if "$script_directory/scan_secrets.sh" --root "$binary_secret_directory" >/dev/null 2>&1; then
    echo "error: NUL-prefixed binary secret fixture was not rejected" >&2
    exit 1
fi

printf '%s%s %s%s\n' 'Bear' 'er' 'fixture_' 'abcdefghijklmnopqrstuvwxyz' \
    > "$text_secret_directory/unsafe.log"
if "$script_directory/scan_secrets.sh" --root "$text_secret_directory" >/dev/null 2>&1; then
    echo "error: textual log fixture was not rejected" >&2
    exit 1
fi

documentation_output=$(PATH=/usr/bin:/bin "$script_directory/check_vad_documentation_state.sh")
case "$documentation_output" in
    *"VAD documentation state check passed"*) ;;
    *)
        echo "error: VAD documentation check did not pass without ripgrep" >&2
        exit 1
        ;;
esac

echo "Repository scan regression tests passed."
