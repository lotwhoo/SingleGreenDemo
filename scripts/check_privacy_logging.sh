#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
source_file="$repository_root/Packages/VoiceChatCore/Tools/ASRCLI/main.swift"

forbidden='localizedDescription|CustomStringConvertible|failure\.userSafeMessage|String\(describing:[[:space:]]*failure\)|debugPrint\(|dump\(|print\([[:space:]]*(text|answer|question|delta|error|message|msg)[[:space:]]*\)|print\(.*\\\((text|answer|question|delta|error|message|msg)\)'
if LC_ALL=C grep -En -e "$forbidden" "$source_file"; then
    echo "error: ASRCLI contains a raw-content or raw-error logging path" >&2
    exit 1
fi

if ! grep -Fq 'coarseReason(for: error).rawValue' "$source_file"; then
    echo "error: ASRCLI top-level failures are not mapped to coarse reasons" >&2
    exit 1
fi

if ! grep -Fq 'failed(\(failure.code.rawValue))' "$source_file"; then
    echo "error: ASRCLI state failures are not limited to the typed coarse code" >&2
    exit 1
fi

echo "Privacy logging check passed."
