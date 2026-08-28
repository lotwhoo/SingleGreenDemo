#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
scan_root=$repository_root
if [ "$#" -eq 2 ] && [ "$1" = "--root" ]; then
    scan_root=$(CDPATH= cd -- "$2" && pwd)
elif [ "$#" -ne 0 ]; then
    echo "usage: $0 [--root DIRECTORY]" >&2
    exit 64
fi
cd "$scan_root"

patterns="-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|Bearer[[:space:]]+[A-Za-z0-9_=-]{24,}|sk-[A-Za-z0-9_-]{20,}|AKLT[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{30,}|(api[_-]?key|token|secret)[[:space:]]*[:=][[:space:]]*['\"][A-Za-z0-9_./+=-]{24,}['\"]"

find . -type f \
    ! -path '*/.git/*' \
    ! -path '*/.build/*' \
    ! -path '*/build/*' \
    ! -path '*/DerivedData*/*' \
    ! -path '*/.coverage/*' \
    ! -path '*/.swiftpm/*' \
    ! -path '*/Pods/*' \
    ! -path '*.xcresult/*' \
    -print | LC_ALL=C sort | while IFS= read -r candidate; do
    # The scanner necessarily contains its own detection expressions.
    if [ "$scan_root" = "$repository_root" ] && [ "$candidate" = "./scripts/scan_secrets.sh" ]; then
        continue
    fi
    [ -f "$candidate" ] || continue
    # -a keeps detection active after a NUL byte; generated binaries are
    # excluded by path, but textual fixtures and accidental binary blobs are not.
    if LC_ALL=C grep -Eal -e "$patterns" "$candidate" >/dev/null 2>&1; then
        echo "error: possible secret material found in ${candidate#./}" >&2
        exit 1
    fi
done

echo "Secret scan passed."
