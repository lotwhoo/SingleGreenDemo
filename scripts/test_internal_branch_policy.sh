#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
check="$script_dir/check_internal_branch_policy.sh"

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-internal-branch-policy.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM

repository="$temp_root/repository"
stdout_file="$temp_root/check.stdout"
stderr_file="$temp_root/check.stderr"
pass_count=0

expect_pass() {
    description=$1
    shift

    if "$@" >"$stdout_file" 2>"$stderr_file"; then
        pass_count=$((pass_count + 1))
        return
    fi

    echo "FAIL: expected success: $description" >&2
    sed -n '1,20p' "$stderr_file" >&2
    exit 1
}

expect_failure() {
    description=$1
    expected_reason=$2
    shift 2

    set +e
    "$@" >"$stdout_file" 2>"$stderr_file"
    command_status=$?
    set -e

    if [ "$command_status" -eq 0 ]; then
        echo "FAIL: expected rejection: $description" >&2
        exit 1
    fi

    actual_reason=$(sed -n '1p' "$stderr_file")
    extra_reason=$(sed -n '2p' "$stderr_file")
    if [ "$actual_reason" != "$expected_reason" ] || [ -n "$extra_reason" ]; then
        echo "FAIL: unexpected rejection reason: $description" >&2
        echo "expected: $expected_reason" >&2
        echo "actual: $actual_reason" >&2
        if [ -n "$extra_reason" ]; then
            echo "additional stderr: $extra_reason" >&2
        fi
        exit 1
    fi

    pass_count=$((pass_count + 1))
}

commit_all() {
    message=$1
    commit_date=$2

    git -C "$repository" add --all
    GIT_AUTHOR_DATE="$commit_date" \
        GIT_COMMITTER_DATE="$commit_date" \
        git -C "$repository" commit -q -m "$message"
    git -C "$repository" rev-parse HEAD
}

write_fixture_file() {
    path=$1
    content=$2

    mkdir -p "$(dirname -- "$repository/$path")"
    printf '%s\n' "$content" >"$repository/$path"
}

run_check() {
    (
        cd "$repository"
        "$check" "$@"
    )
}

run_check_outside_git() {
    (
        cd "$temp_root"
        "$check" "$@"
    )
}

run_check_outside_git_with_locale() {
    (
        cd "$temp_root"
        LC_ALL="$utf8_locale" "$check" "$@"
    )
}

mutated_commit() {
    branch_name=$1
    path=$2
    content=$3
    commit_date=$4

    git -C "$repository" checkout -q -B "$branch_name" "$main_tip_sha"
    printf '%s\n' "$content" >>"$repository/$path"
    commit_all "mutate $path" "$commit_date"
}

git init -q -b main "$repository"
git -C "$repository" config user.name "SingleGreen Branch Policy Test"
git -C "$repository" config user.email "branch-policy@example.invalid"

write_fixture_file "Configurations/Internal-Debug.xcconfig" "INTERNAL_DIAGNOSTICS = YES"
write_fixture_file "SingleGreenDemo.xcodeproj/xcshareddata/xcschemes/SingleGreenInternal.xcscheme" "<Scheme version=\"1.7\" />"
write_fixture_file "SingleGreenDemo/App/AppShellView.swift" "struct AppShellView {}"
write_fixture_file "SingleGreenDemoTests/ExperienceRuntimeTests.swift" "final class ExperienceRuntimeTests {}"
write_fixture_file "Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/Fixture.swift" "public struct Fixture {}"
write_fixture_file "SingleGreenDemo.xcodeproj/project.pbxproj" '// !$*UTF8*$!'
write_fixture_file ".github/workflows/ci.yml" "name: CI"
write_fixture_file "README.md" "# Fixture"

base_sha=$(commit_all "canonical base" "2000-01-01T00:00:00+0000")
write_fixture_file "README.md" "# Fixture tip"
main_tip_sha=$(commit_all "canonical tip" "2000-01-02T00:00:00+0000")

uppercase_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
nonexistent_sha=0000000000000000000000000000000000000000
usage_message="usage: $check REVIEWED_MAIN_SHA MAIN_SHA INTERNAL_SHA"

expect_failure "missing all arguments before Git" "$usage_message" run_check_outside_git
expect_failure "missing one SHA before Git" "$usage_message" run_check_outside_git "$base_sha" "$main_tip_sha"
expect_failure "extra SHA before Git" "$usage_message" run_check_outside_git "$base_sha" "$main_tip_sha" "$base_sha" "$main_tip_sha"
expect_failure "short reviewed SHA before Git" "error: invalid-reviewed-sha" run_check_outside_git "${base_sha%????????}" "$main_tip_sha" "$base_sha"
expect_failure "uppercase main SHA before Git" "error: invalid-main-sha" run_check_outside_git "$base_sha" "$uppercase_sha" "$base_sha"
expect_failure "non-hex internal SHA before Git" "error: invalid-internal-sha" run_check_outside_git "$base_sha" "$main_tip_sha" "gggggggggggggggggggggggggggggggggggggggg"

utf8_locale=
available_locales=$(locale -a 2>/dev/null || true)
for locale_candidate in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8 UTF-8; do
    if printf '%s\n' "$available_locales" | LC_ALL=C grep -F -x -- "$locale_candidate" >/dev/null 2>&1; then
        utf8_locale=$locale_candidate
        break
    fi
done
if [ -n "$utf8_locale" ]; then
    expect_failure "uppercase main SHA under UTF-8 locale before Git" "error: invalid-main-sha" run_check_outside_git_with_locale "$base_sha" "$uppercase_sha" "$base_sha"
else
    echo "SKIP: no UTF-8 locale available for uppercase SHA regression." >&2
fi

expect_failure "nonexistent reviewed object" "error: missing-reviewed-commit-object" run_check "$nonexistent_sha" "$main_tip_sha" "$base_sha"
expect_failure "nonexistent main object" "error: missing-main-commit-object" run_check "$base_sha" "$nonexistent_sha" "$base_sha"
expect_failure "nonexistent internal object" "error: missing-internal-commit-object" run_check "$base_sha" "$main_tip_sha" "$nonexistent_sha"

blob_sha=$(printf '%s' 'not a commit' | git -C "$repository" hash-object -w --stdin)
expect_failure "reviewed object is not a commit" "error: missing-reviewed-commit-object" run_check "$blob_sha" "$main_tip_sha" "$base_sha"
expect_failure "main object is not a commit" "error: missing-main-commit-object" run_check "$base_sha" "$blob_sha" "$base_sha"
expect_failure "internal object is not a commit" "error: missing-internal-commit-object" run_check "$base_sha" "$main_tip_sha" "$blob_sha"

expect_pass "current canonical main reviewed and delivered" run_check "$main_tip_sha" "$main_tip_sha" "$main_tip_sha"
expect_failure "older main ancestor is not current canonical main" "error: reviewed-not-current-main" run_check "$base_sha" "$main_tip_sha" "$base_sha"

git -C "$repository" checkout -q -B reviewed-side "$base_sha"
printf '%s\n' "side branch" >>"$repository/README.md"
side_sha=$(commit_all "unreachable reviewed commit" "2000-01-03T00:00:00+0000")
expect_failure "reviewed SHA is on a side branch" "error: reviewed-not-reachable" run_check "$side_sha" "$main_tip_sha" "$side_sha"

git -C "$repository" checkout -q -B divergent-internal "$main_tip_sha"
printf '%s\n' "divergent internal" >>"$repository/README.md"
divergent_internal_sha=$(commit_all "divergent internal content" "2000-01-04T00:00:00+0000")
expect_failure "divergent nonempty internal commit" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$divergent_internal_sha"

git -C "$repository" checkout -q -B empty-internal "$main_tip_sha"
GIT_AUTHOR_DATE="2000-01-05T00:00:00+0000" \
    GIT_COMMITTER_DATE="2000-01-05T00:00:00+0000" \
    git -C "$repository" commit -q --allow-empty -m "empty divergent internal commit"
empty_internal_sha=$(git -C "$repository" rev-parse HEAD)
expect_failure "empty divergent internal commit" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$empty_internal_sha"

internal_config_sha=$(mutated_commit "mutation-internal-config" "Configurations/Internal-Debug.xcconfig" "OTHER_SWIFT_FLAGS = -DUNREVIEWED" "2000-01-06T00:00:00+0000")
expect_failure "Internal xcconfig mutation" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$internal_config_sha"

internal_scheme_sha=$(mutated_commit "mutation-internal-scheme" "SingleGreenDemo.xcodeproj/xcshareddata/xcschemes/SingleGreenInternal.xcscheme" "<!-- unreviewed -->" "2000-01-07T00:00:00+0000")
expect_failure "shared Internal scheme mutation" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$internal_scheme_sha"

source_sha=$(mutated_commit "mutation-source" "SingleGreenDemo/App/AppShellView.swift" "// unreviewed source" "2000-01-08T00:00:00+0000")
expect_failure "shared source mutation" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$source_sha"

tests_sha=$(mutated_commit "mutation-tests" "SingleGreenDemoTests/ExperienceRuntimeTests.swift" "// unreviewed test" "2000-01-09T00:00:00+0000")
expect_failure "tests mutation" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$tests_sha"

package_sha=$(mutated_commit "mutation-package" "Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/Fixture.swift" "// unreviewed Package" "2000-01-10T00:00:00+0000")
expect_failure "Package mutation" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$package_sha"

project_sha=$(mutated_commit "mutation-project" "SingleGreenDemo.xcodeproj/project.pbxproj" "// unreviewed project setting" "2000-01-11T00:00:00+0000")
expect_failure "project.pbxproj mutation" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$project_sha"

ci_sha=$(mutated_commit "mutation-ci" ".github/workflows/ci.yml" "# unreviewed CI" "2000-01-12T00:00:00+0000")
expect_failure "CI mutation" "error: internal-not-reviewed" run_check "$main_tip_sha" "$main_tip_sha" "$ci_sha"

echo "Internal branch policy tests passed: $pass_count cases."
