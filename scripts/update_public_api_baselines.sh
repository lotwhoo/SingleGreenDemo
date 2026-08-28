#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)

if [ "${CI:-}" = "true" ]; then
    echo "error: public API baselines must never be updated automatically in CI" >&2
    exit 1
fi
if [ "${1:-}" != "--accept-current-api" ] || [ "$#" -ne 1 ]; then
    echo "usage: $0 --accept-current-api" >&2
    echo "This command replaces reviewed snapshots with the current public API." >&2
    exit 2
fi

baseline_version=$(python3 - "$repository_root/config/toolchain.json" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream).get("api_baseline_version")
if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) or value in {".", ".."}:
    raise SystemExit("error: api_baseline_version must be one safe non-dot slug")
print(value)
PY
)
api_parent="$repository_root/api-baselines"
mkdir -p "$api_parent"
python3 - "$repository_root" "$api_parent" <<'PY'
from pathlib import Path
import sys
repository_root = Path(sys.argv[1]).resolve()
actual_parent = Path(sys.argv[2]).resolve()
expected_parent = repository_root / "api-baselines"
if actual_parent != expected_parent:
    raise SystemExit(
        f"error: canonical API baseline parent must be {expected_parent}, got {actual_parent}"
    )
PY

destination="$api_parent/$baseline_version"
staging=$(mktemp -d "$api_parent/.update-$baseline_version.XXXXXX")
payload="$staging/payload"
backup="$api_parent/.backup-$baseline_version-$$"
backup_active=0

remove_tree() {
    target=$1
    if [ -e "$target" ] || [ -L "$target" ]; then
        find "$target" -depth -delete
    fi
}

cleanup() {
    if [ "$backup_active" -eq 1 ] && [ ! -e "$destination" ] && [ -e "$backup" ]; then
        mv "$backup" "$destination" || true
    fi
    remove_tree "$staging"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

"$script_directory/check_public_api_baselines.sh" --emit-current "$payload"
if [ ! -d "$payload" ]; then
    echo "error: API baseline generator did not produce a staged directory" >&2
    exit 1
fi

if [ -e "$backup" ] || [ -L "$backup" ]; then
    echo "error: rollback path already exists: $backup" >&2
    exit 1
fi
if [ -e "$destination" ] || [ -L "$destination" ]; then
    backup_active=1
    if ! mv "$destination" "$backup"; then
        backup_active=0
        echo "error: could not create rollback copy of the prior API baseline" >&2
        exit 1
    fi
fi

replacement_failed=0
if [ "${SINGLE_GREEN_TEST_SIMULATE_API_REPLACEMENT_FAILURE:-0}" = "1" ]; then
    replacement_failed=1
elif ! mv "$payload" "$destination"; then
    replacement_failed=1
fi

if [ "$replacement_failed" -eq 1 ]; then
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        remove_tree "$destination"
    fi
    if [ "$backup_active" -eq 1 ]; then
        mv "$backup" "$destination"
        backup_active=0
    fi
    echo "error: API baseline replacement failed; the prior baseline was restored" >&2
    exit 1
fi

if [ "$backup_active" -eq 1 ]; then
    remove_tree "$backup"
    backup_active=0
fi
echo "Updated reviewed public API baseline: ${destination#"$repository_root/"}"
