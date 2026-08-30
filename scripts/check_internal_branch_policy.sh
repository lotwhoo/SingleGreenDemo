#!/bin/sh

set -eu

usage() {
    echo "usage: $0 REVIEWED_MAIN_SHA MAIN_SHA INTERNAL_SHA" >&2
    exit 2
}

fail() {
    echo "error: $1" >&2
    exit 1
}

if [ "$#" -ne 3 ]; then
    usage
fi

reviewed_main_sha=$1
main_sha=$2
internal_sha=$3

is_lowercase_full_sha() {
    candidate=$1
    if [ "${#candidate}" -ne 40 ]; then
        return 1
    fi

    case "$candidate" in
        *[!0-9a-f]*) return 1 ;;
        *) return 0 ;;
    esac
}

if ! is_lowercase_full_sha "$reviewed_main_sha"; then
    fail "invalid-reviewed-sha"
fi

if ! is_lowercase_full_sha "$main_sha"; then
    fail "invalid-main-sha"
fi

if ! is_lowercase_full_sha "$internal_sha"; then
    fail "invalid-internal-sha"
fi

require_commit_object() {
    object_sha=$1
    failure_reason=$2
    object_type=$(git cat-file -t "$object_sha" 2>/dev/null || true)
    if [ "$object_type" != "commit" ]; then
        fail "$failure_reason"
    fi
}

require_commit_object "$reviewed_main_sha" "missing-reviewed-commit-object"
require_commit_object "$main_sha" "missing-main-commit-object"
require_commit_object "$internal_sha" "missing-internal-commit-object"

if ! git merge-base --is-ancestor "$reviewed_main_sha" "$main_sha" >/dev/null 2>&1; then
    fail "reviewed-not-reachable"
fi

# Promotion workflows are sourced from the pushed canonical-main commit, so a
# reachable but older main ancestor is deliberately not eligible for delivery.
if [ "$reviewed_main_sha" != "$main_sha" ]; then
    fail "reviewed-not-current-main"
fi

if [ "$internal_sha" != "$reviewed_main_sha" ]; then
    fail "internal-not-reviewed"
fi

reviewed_tree=$(git show --no-patch --format=%T "$reviewed_main_sha" 2>/dev/null)
internal_tree=$(git show --no-patch --format=%T "$internal_sha" 2>/dev/null)
if [ "$internal_tree" != "$reviewed_tree" ]; then
    fail "tree-mismatch"
fi

if ! git diff --exit-code --no-ext-diff "$reviewed_main_sha" "$internal_sha" -- >/dev/null; then
    fail "nonempty-delta"
fi

echo "Internal branch policy check passed: reviewed SHA is current canonical main."
