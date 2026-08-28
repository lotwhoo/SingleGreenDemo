#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
cd "$repository_root"

failed=0

for path in .build DerivedData DerivedDataDevice build .coverage; do
    if git ls-files --error-unmatch "$path" >/dev/null 2>&1 ||
       git ls-files "$path/**" | grep -q .; then
        echo "error: generated directory is tracked: $path" >&2
        failed=1
    fi
done

tracked_artifacts=$(git ls-files | grep -E '(\.xcresult/|\.ipa$|\.prof(raw|data)$|\.log$|\.DS_Store$|xcuserdata/|\.xcuserstate$)' || true)
if [ -n "$tracked_artifacts" ]; then
    echo "error: generated artifacts are tracked:" >&2
    echo "$tracked_artifacts" >&2
    failed=1
fi

if git ls-files | grep -E '(^|/)(\.env|Volcengine\.plist)$' >/dev/null; then
    echo "error: a local credential/configuration file is tracked" >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "Repository hygiene check passed."
