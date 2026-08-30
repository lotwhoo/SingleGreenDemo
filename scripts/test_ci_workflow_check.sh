#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
checker="$script_dir/check_ci_workflow.sh"
source_workflow="$repository_root/.github/workflows/ci.yml"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-ci-workflow.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

if [ ! -x "$checker" ]; then
    echo "CI workflow fixture test failed: checker is not executable: $checker" >&2
    exit 1
fi

"$checker" "$source_workflow"

mutation_count=0

expect_mutation_failure() {
    mutation_name=$1
    fixture_path="$fixture_root/$mutation_name.yml"
    log_path="$fixture_root/$mutation_name.log"

    ruby - "$source_workflow" "$fixture_path" "$mutation_name" <<'RUBY'
source_path, destination_path, mutation = ARGV
text = File.read(source_path)

changed = case mutation
when "missing-internal-trigger"
  before = "  push:\n    branches:\n      - main\n      - codex/internal-debug\n"
  after = "  push:\n    branches:\n      - main\n"
  text.sub!(before, after)
when "shallow-checkout"
  text.sub!("          fetch-depth: 0\n", "          fetch-depth: 1\n")
when "missing-internal-debug-test"
  text.sub!("          - { variant: internal, scheme: SingleGreenInternal, configuration: Internal-Debug, artifact_suffix: internal-debug }\n", "")
when "missing-internal-release-build"
  text.sub!("          - { variant: internal, scheme: SingleGreenInternal, configuration: Internal-Release, artifact_suffix: internal-release }\n", "")
when "missing-internal-debug-scanner"
  scanner = "      - name: Scan Internal Debug App\n" \
            "        if: matrix.variant == 'internal'\n" \
            '        run: scripts/check_internal_artifact_capabilities.sh "$RUNNER_TEMP/SingleGreenDemo-${{ matrix.artifact_suffix }}-artifact/Build/Products/${{ matrix.configuration }}-iphonesimulator/SingleGreenDemo.app"' + "\n"
  text.sub!(scanner, "")
when "reused-debug-test-derived-data"
  artifact_path = 'SingleGreenDemo-${{ matrix.artifact_suffix }}-artifact'
  test_path = 'SingleGreenDemo-${{ matrix.artifact_suffix }}'
  occurrences = text.scan(artifact_path).length
  abort "unexpected App-only artifact path count: #{occurrences}" unless occurrences == 3
  text.gsub!(artifact_path, test_path)
when "swapped-scanners"
  user = "scripts/check_user_artifact_isolation.sh"
  internal = "scripts/check_internal_artifact_capabilities.sh"
  if text.include?(user) && text.include?(internal)
    text.gsub!(user, "scripts/__scanner_swap_sentinel__.sh")
    text.gsub!(internal, user)
    text.gsub!("scripts/__scanner_swap_sentinel__.sh", internal)
    true
  end
when "missing-branch-policy-call"
  text.sub!("          scripts/check_internal_branch_policy.sh \"$reviewed_main_sha\" \"$main_sha\" \"$internal_sha\"\n", "")
when "workflow-dispatch-input"
  dispatch = "on:\n" \
             "  workflow_dispatch:\n" \
             "    inputs:\n" \
             "      reviewed_sha:\n" \
             "        required: true\n"
  text.sub!("on:\n", dispatch)
else
  abort "unknown mutation: #{mutation}"
end

abort "mutation made no change: #{mutation}" unless changed
File.write(destination_path, text)
RUBY

    if "$checker" "$fixture_path" >"$log_path" 2>&1; then
        echo "CI workflow fixture test failed: mutation unexpectedly passed: $mutation_name" >&2
        cat "$log_path" >&2
        exit 1
    fi

    mutation_count=$((mutation_count + 1))
    echo "Expected CI workflow rejection: $mutation_name"
}

expect_mutation_failure missing-internal-trigger
expect_mutation_failure shallow-checkout
expect_mutation_failure missing-internal-debug-test
expect_mutation_failure missing-internal-release-build
expect_mutation_failure missing-internal-debug-scanner
expect_mutation_failure reused-debug-test-derived-data
expect_mutation_failure swapped-scanners
expect_mutation_failure missing-branch-policy-call
expect_mutation_failure workflow-dispatch-input

echo "CI workflow fixture tests passed: $mutation_count/$mutation_count mutations rejected"
