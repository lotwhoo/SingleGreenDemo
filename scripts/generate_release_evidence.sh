#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 VERSION OUTPUT.json" >&2
    exit 64
fi

version=$1
output=$2
case "$version" in
    *[!0-9A-Za-z._-]*|'') echo "error: invalid version" >&2; exit 64 ;;
esac

commit=$(git rev-parse HEAD)
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
dirty=false
if [ -n "$(git status --porcelain)" ]; then dirty=true; fi

template='{
  "schemaVersion": 1,
  "version": "__VERSION__",
  "commit": "__COMMIT__",
  "generatedAt": "__GENERATED_AT__",
  "workingTreeDirty": __DIRTY__,
  "automated": {
    "packageStrictGate": "not_run",
    "asrCLIPrivacyBuild": "not_run",
    "appSimulatorTests": "not_run",
    "releaseSimulatorBuild": "not_run",
    "coverageGate": "not_run",
    "secretScan": "not_run"
  },
  "manual": {
    "physicalDevice": "not_run",
    "realServices": "not_run",
    "accessibility": "not_run",
    "opticalCalibration": "not_run"
  },
  "residualRisks": []
}'

printf '%s\n' "$template" |
    sed -e "s/__VERSION__/$version/" \
        -e "s/__COMMIT__/$commit/" \
        -e "s/__GENERATED_AT__/$generated_at/" \
        -e "s/__DIRTY__/$dirty/" > "$output"

"$(dirname "$0")/validate_release_evidence.sh" "$output"
