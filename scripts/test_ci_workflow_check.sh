#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
checker="$script_dir/check_ci_workflow.sh"
source_workflow="$repository_root/.github/workflows/ci.yml"
source_promotion_workflow="$repository_root/.github/workflows/promote-internal.yml"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-ci-workflow.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

if [ ! -x "$checker" ]; then
    echo "CI workflow fixture test failed: checker is not executable: $checker" >&2
    exit 1
fi

"$checker" "$source_workflow" "$source_promotion_workflow"

mutation_count=0

expect_mutation_failure() {
    mutation_name=$1
    target_workflow=${2:-ci}
    mutation_root="$fixture_root/$mutation_name"
    ci_fixture_path="$mutation_root/ci.yml"
    promotion_fixture_path="$mutation_root/promote-internal.yml"
    log_path="$fixture_root/$mutation_name.log"

    mkdir -p "$mutation_root"
    cp "$source_workflow" "$ci_fixture_path"
    cp "$source_promotion_workflow" "$promotion_fixture_path"

    if [ "$target_workflow" = "ci" ]; then
        source_path=$source_workflow
        fixture_path=$ci_fixture_path
    elif [ "$target_workflow" = "promotion" ]; then
        source_path=$source_promotion_workflow
        fixture_path=$promotion_fixture_path
    elif [ "$target_workflow" = "extra" ]; then
        source_path=$source_promotion_workflow
        fixture_path="$mutation_root/unauthorized-writer.yml"
    else
        echo "CI workflow fixture test failed: unknown mutation target: $target_workflow" >&2
        exit 1
    fi

    ruby - "$source_path" "$fixture_path" "$mutation_name" <<'RUBY'
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
when "unpinned-ci-checkout"
  text.sub!("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7")
when "unpinned-ci-upload"
  text.sub!("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", "actions/upload-artifact@v7")
when "missing-required-ci"
  marker = "\n  required-ci:\n"
  index = text.index(marker)
  abort "required-ci marker not found" unless index
  text.slice!(index..-1)
when "required-ci-not-always"
  text.sub!("    if: always()\n", "    if: success()\n")
when "required-ci-missing-need"
  text.sub!("      - public-api\n", "")
when "required-ci-allows-failure"
  text.sub!('[ "$result" != "success" ]', '[ "$result" = "cancelled" ]')
when "ci-job-write"
  text.sub!("    name: Branch contract\n", "    name: Branch contract\n    permissions:\n      contents: write\n")
when "required-ci-job-continue-on-error"
  text.sub!("    name: Required CI\n", "    name: Required CI\n    continue-on-error: true\n")
when "required-ci-step-continue-on-error"
  text.sub!("      - name: Require every CI dependency to succeed\n", "      - name: Require every CI dependency to succeed\n        continue-on-error: true\n")
when "required-ci-step-condition"
  text.sub!("      - name: Require every CI dependency to succeed\n", "      - name: Require every CI dependency to succeed\n        if: false\n")
when "upstream-ci-job-continue-on-error"
  text.sub!("    name: Branch contract\n", "    name: Branch contract\n    continue-on-error: true\n")
when "branch-fixture-step-condition"
  text.sub!("      - name: Run branch-policy fixtures\n", "      - name: Run branch-policy fixtures\n        if: false\n")
when "package-test-step-condition"
  line = text.lines.find { |candidate| candidate.include?('run: swift test --package-path') }
  abort "package test step not found" unless line
  text.sub!(line, line.sub("      - run:", "      - if: false\n        run:"))
when "app-test-step-condition"
  text.sub!("      - name: Resolve Simulator and run App tests\n", "      - name: Resolve Simulator and run App tests\n        if: false\n")
when "ci-top-level-custom-shell"
  text.sub!("permissions:\n  contents: read\n", "permissions:\n  contents: read\n\ndefaults:\n  run:\n    shell: bash -c 'bash {0} || true'\n")
when "required-ci-step-custom-shell"
  text.sub!("      - name: Require every CI dependency to succeed\n", "      - name: Require every CI dependency to succeed\n        shell: bash -c 'bash {0} || true'\n")
when "failing-extra-ci-job"
  marker = "\n  required-ci:\n"
  addition = <<~YAML

      unaggregated-failure:
        name: Unaggregated failure
        runs-on: ubuntu-latest
        steps:
          - run: exit 1

      required-ci:
  YAML
  text.sub!(marker, addition)
when "unreviewed-ci-step-action"
  marker = "      - name: Run branch-policy fixtures\n"
  text.sub!(marker, "      - uses: unreviewed/action@0123456789012345678901234567890123456789\n#{marker}")
when "promotion-dispatch-input"
  text.sub!("  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      reviewed_sha:\n        required: true\n")
when "promotion-top-level-write"
  text.sub!("permissions: {}\n", "permissions:\n  contents: write\n")
when "promotion-unstable-authorization-name"
  text.sub!("    name: Internal promotion authorization\n", "    name: Authorize current main\n")
when "promotion-authorize-write"
  text.sub!("      contents: read\n", "      contents: write\n")
when "promotion-unpinned-checkout"
  text.sub!("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7")
when "promotion-user-sha"
  text.sub!('          event_sha="$GITHUB_SHA"', '          event_sha="${{ inputs.reviewed_sha }}"')
when "promotion-wrong-main-gate"
  text.sub!('[ "$GITHUB_REF" != "refs/heads/main" ]', '[ "$GITHUB_REF" != "refs/heads/develop" ]')
when "promotion-authorize-mutation"
  text.sub!('          echo "approved_sha=$main_sha" >> "$GITHUB_OUTPUT"', "          git push origin main\n          echo \"approved_sha=$main_sha\" >> \"$GITHUB_OUTPUT\"")
when "promotion-authorize-job-continue-on-error"
  text.sub!("    name: Internal promotion authorization\n", "    name: Internal promotion authorization\n    continue-on-error: true\n")
when "promotion-authorize-step-continue-on-error"
  text.sub!("        id: authorize\n", "        id: authorize\n        continue-on-error: true\n")
when "promotion-extra-authorize-step"
  marker = "      - name: Authorize the exact current main commit\n"
  text.sub!(marker, "      - name: Unexpected authorize step\n        run: echo unexpected\n#{marker}")
when "promotion-extra-push-step"
  marker = "      - name: Fast-forward the internal delivery pointer\n"
  text.sub!(marker, "      - name: Unexpected write step\n        run: git push origin HEAD:refs/heads/unreviewed\n#{marker}")
when "promotion-job-condition"
  text.sub!("    name: Internal promotion authorization\n", "    name: Internal promotion authorization\n    if: false\n")
when "promotion-step-condition"
  text.sub!("        id: authorize\n", "        id: authorize\n        if: false\n")
when "promotion-step-custom-shell"
  text.sub!("        id: authorize\n", "        id: authorize\n        shell: bash -c 'bash {0} || true'\n")
when "promotion-wrong-check-app"
  text.sub!(".app.id == 15368", ".app.id == 99999")
when "promotion-check-not-exact-sha"
  text.sub!("/commits/$main_sha/check-runs?", "/commits/main/check-runs?")
when "promotion-not-latest-run"
  text.sub!("sort_by(.updated_at, .run_attempt, .id)", "sort_by(.id)")
when "promotion-rejects-safe-reruns"
  text.sub!('if [ "$workflow_run_count" -lt 1 ]; then', 'if [ "$workflow_run_count" -ne 1 ]; then')
when "promotion-missing-authorization-dependency"
  text.sub!("    needs: authorize\n", "")
when "promotion-stale-authorization-allowed"
  text.sub!('[ "$APPROVED_SHA" != "$main_sha" ]', '[ "$event_sha" != "$main_sha" ]')
when "promotion-force-push"
  text.sub!('          git push origin "$main_sha:refs/heads/codex/internal-debug"', '          git push --force origin "$main_sha:refs/heads/codex/internal-debug"')
when "promotion-missing-fast-forward-proof"
  text.sub!('            if ! git merge-base --is-ancestor "$previous_internal_sha" "$main_sha"; then', '            if [ "$previous_internal_sha" = "$main_sha" ]; then')
when "promotion-push-before-precheck"
  precheck = '          scripts/check_internal_branch_policy.sh "$APPROVED_SHA" "$main_sha" "$checkout_sha"'
  push = '          git push origin "$main_sha:refs/heads/codex/internal-debug"'
  abort "precheck or push not found" unless text.include?(precheck) && text.include?(push)
  text.sub!(precheck, "          __PRECHECK_SENTINEL__")
  text.sub!(push, precheck)
  text.sub!("          __PRECHECK_SENTINEL__", push)
  true
when "promotion-missing-postcheck"
  text.sub!('          scripts/check_internal_branch_policy.sh "$APPROVED_SHA" "$post_main_sha" "$internal_sha"', '')
when "promotion-secret-pat"
  text.sub!("        env:\n          APPROVED_SHA:", "        env:\n          DEPLOY_PAT: ${{ secrets.DEPLOY_PAT }}\n          APPROVED_SHA:")
when "extra-top-level-writer"
  text = <<~YAML
    name: Unauthorized Writer
    on:
      push:
    permissions: write-all
    jobs:
      unauthorized:
        runs-on: ubuntu-latest
        steps:
          - run: echo unauthorized
  YAML
  true
when "extra-job-level-writer"
  text = <<~YAML
    name: Unauthorized Job Writer
    on:
      push:
    permissions: {}
    jobs:
      unauthorized:
        runs-on: ubuntu-latest
        permissions:
          contents: write
        steps:
          - run: echo unauthorized
  YAML
  true
when "extra-omitted-permissions"
  text = <<~YAML
    name: Default Permission Workflow
    on:
      push:
    jobs:
      defaulted:
        runs-on: ubuntu-latest
        steps:
          - run: echo defaulted
  YAML
  true
else
  abort "unknown mutation: #{mutation}"
end

abort "mutation made no change: #{mutation}" unless changed
File.write(destination_path, text)
RUBY

    if "$checker" "$ci_fixture_path" "$promotion_fixture_path" >"$log_path" 2>&1; then
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
expect_mutation_failure unpinned-ci-checkout
expect_mutation_failure unpinned-ci-upload
expect_mutation_failure missing-required-ci
expect_mutation_failure required-ci-not-always
expect_mutation_failure required-ci-missing-need
expect_mutation_failure required-ci-allows-failure
expect_mutation_failure ci-job-write
expect_mutation_failure required-ci-job-continue-on-error
expect_mutation_failure required-ci-step-continue-on-error
expect_mutation_failure required-ci-step-condition
expect_mutation_failure upstream-ci-job-continue-on-error
expect_mutation_failure branch-fixture-step-condition
expect_mutation_failure package-test-step-condition
expect_mutation_failure app-test-step-condition
expect_mutation_failure ci-top-level-custom-shell
expect_mutation_failure required-ci-step-custom-shell
expect_mutation_failure failing-extra-ci-job
expect_mutation_failure unreviewed-ci-step-action
expect_mutation_failure promotion-dispatch-input promotion
expect_mutation_failure promotion-top-level-write promotion
expect_mutation_failure promotion-unstable-authorization-name promotion
expect_mutation_failure promotion-authorize-write promotion
expect_mutation_failure promotion-unpinned-checkout promotion
expect_mutation_failure promotion-user-sha promotion
expect_mutation_failure promotion-wrong-main-gate promotion
expect_mutation_failure promotion-authorize-mutation promotion
expect_mutation_failure promotion-authorize-job-continue-on-error promotion
expect_mutation_failure promotion-authorize-step-continue-on-error promotion
expect_mutation_failure promotion-extra-authorize-step promotion
expect_mutation_failure promotion-extra-push-step promotion
expect_mutation_failure promotion-job-condition promotion
expect_mutation_failure promotion-step-condition promotion
expect_mutation_failure promotion-step-custom-shell promotion
expect_mutation_failure promotion-wrong-check-app promotion
expect_mutation_failure promotion-check-not-exact-sha promotion
expect_mutation_failure promotion-not-latest-run promotion
expect_mutation_failure promotion-rejects-safe-reruns promotion
expect_mutation_failure promotion-missing-authorization-dependency promotion
expect_mutation_failure promotion-stale-authorization-allowed promotion
expect_mutation_failure promotion-force-push promotion
expect_mutation_failure promotion-missing-fast-forward-proof promotion
expect_mutation_failure promotion-push-before-precheck promotion
expect_mutation_failure promotion-missing-postcheck promotion
expect_mutation_failure promotion-secret-pat promotion
expect_mutation_failure extra-top-level-writer extra
expect_mutation_failure extra-job-level-writer extra
expect_mutation_failure extra-omitted-permissions extra

echo "CI workflow fixture tests passed: $mutation_count/$mutation_count mutations rejected"
