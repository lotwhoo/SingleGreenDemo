#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
fixture_directory=$(mktemp -d "${TMPDIR:-/tmp}/single-green-evidence.XXXXXX")
trap 'rm -rf "$fixture_directory"' EXIT HUP INT TERM

cd "$repository_root"
"$script_directory/generate_release_evidence.sh" qa "$fixture_directory/valid.json" >/dev/null
"$script_directory/validate_release_evidence.sh" "$fixture_directory/valid.json" >/dev/null

sed -E 's/"workingTreeDirty": (true|false)/"workingTreeDirty": "\1"/' \
    "$fixture_directory/valid.json" > "$fixture_directory/boolean-as-string.json"
sed 's/"residualRisks"/"unexpected": 1, "residualRisks"/' \
    "$fixture_directory/valid.json" > "$fixture_directory/extra-property.json"
sed -E 's/"generatedAt": "[^"]+"/"generatedAt": "not-a-date"/' \
    "$fixture_directory/valid.json" > "$fixture_directory/bad-date.json"

for fixture in boolean-as-string extra-property bad-date; do
    if "$script_directory/validate_release_evidence.sh" \
        "$fixture_directory/$fixture.json" >/dev/null 2>&1; then
        echo "error: invalid evidence fixture passed validation: $fixture" >&2
        exit 1
    fi
done

echo "Release evidence validator mutation tests passed."
