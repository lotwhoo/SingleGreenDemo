#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
checker="$script_dir/check_ci_workflow.sh"
source_workflow="$repository_root/.github/workflows/ci.yml"
source_promotion_workflow="$repository_root/.github/workflows/promote-internal.yml"
source_writer_workflow="$repository_root/.github/workflows/promote-authorized-internal.yml"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-ci-workflow.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

if [ ! -x "$checker" ]; then
    echo "CI workflow fixture test failed: checker is not executable: $checker" >&2
    exit 1
fi

"$checker" "$source_workflow" "$source_promotion_workflow" "$source_writer_workflow"

mutation_count=0

expect_mutation_failure() {
    mutation_name=$1
    target_workflow=${2:-ci}
    mutation_root="$fixture_root/$mutation_name"
    ci_fixture_path="$mutation_root/ci.yml"
    promotion_fixture_path="$mutation_root/promote-internal.yml"
    writer_fixture_path="$mutation_root/promote-authorized-internal.yml"
    log_path="$fixture_root/$mutation_name.log"

    mkdir -p "$mutation_root"
    cp "$source_workflow" "$ci_fixture_path"
    cp "$source_promotion_workflow" "$promotion_fixture_path"
    cp "$source_writer_workflow" "$writer_fixture_path"

    if [ "$target_workflow" = "ci" ]; then
        source_path=$source_workflow
        fixture_path=$ci_fixture_path
    elif [ "$target_workflow" = "promotion" ]; then
        source_path=$source_promotion_workflow
        fixture_path=$promotion_fixture_path
    elif [ "$target_workflow" = "writer" ]; then
        source_path=$source_writer_workflow
        fixture_path=$writer_fixture_path
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
when "branch-policy-echo-only"
  text.sub!("        run: scripts/test_internal_branch_policy.sh\n", "        run: echo scripts/test_internal_branch_policy.sh\n")
when "missing-ruleset-contract-fixtures"
  text.sub!("      - name: Run ruleset-contract fixtures\n        run: scripts/test_internal_ruleset_contract.sh\n", "")
when "ruleset-contract-echo-only"
  text.sub!("        run: scripts/test_internal_ruleset_contract.sh\n", "        run: echo scripts/test_internal_ruleset_contract.sh\n")
when "workflow-dispatch-input"
  text.sub!("  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      reviewed_sha:\n        required: true\n")
when "missing-workflow-dispatch"
  text.sub!("  workflow_dispatch:\n", "")
when "dispatch-aggregate-mints-required-ci"
  text.sub!(%q{name: ${{ github.event_name == 'workflow_dispatch' && 'Internal post-promotion CI' || 'Required CI' }}}, "name: Required CI")
when "dispatch-missing-ref-gate"
  text.sub!(%q{          if [ "$GITHUB_REF" != 'refs/heads/codex/internal-debug' ]; then}, %q{          if false; then})
when "dispatch-broad-sha-gate"
  text.sub!(%q{if [ "$GITHUB_SHA" != "$main_sha" ] || [ "$GITHUB_SHA" != "$internal_sha" ]; then}, %q{if [ "$GITHUB_SHA" != "$main_sha" ]; then})
when "dispatch-branch-policy-echo-only"
  marker = 'scripts/check_internal_branch_policy.sh "$main_sha" "$main_sha" "$internal_sha"'
  index = text.rindex(marker)
  abort "dispatch branch-policy marker not found" unless index
  text[index, marker.length] = "echo #{marker}"
  true
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
  text.sub!("  required-ci:\n", "  required-ci:\n    continue-on-error: true\n")
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
when "authorization-wrong-owner"
  text.sub!("canonical_actor='lotwhoo'", "canonical_actor='attacker'")
when "authorization-missing-triggering-actor"
  text.sub!('$GITHUB_TRIGGERING_ACTOR', '$GITHUB_ACTOR')
when "authorization-wrong-workflow-id"
  text.sub!("canonical_workflow_id='345772544'", "canonical_workflow_id='1'")
when "authorization-allows-rerun"
  text.sub!(%q{[ "$GITHUB_RUN_ATTEMPT" != '1' ]}, %q{[ "$GITHUB_RUN_ATTEMPT" != '2' ]})
when "authorization-missing-current-main-check"
  text.sub!('          scripts/check_internal_branch_policy.sh "$main_sha" "$main_sha" "$main_sha"', '')
when "authorization-adds-push"
  text.sub!('          echo "Authorized current main', "          git push origin main\n          echo \"Authorized current main")
when "authorization-missing-status-write"
  text.sub!("      statuses: write\n", "")
when "authorization-broad-status-write"
  text.sub!("      statuses: write\n", "      statuses: write\n      issues: write\n")
when "authorization-status-echo-only"
  text.sub!('authorization_status=$(gh api --method POST', 'authorization_status=$(echo gh api --method POST')
when "authorization-status-wrong-state"
  text.sub!("-f state='success'", "-f state='pending'")
when "authorization-status-wrong-context"
  text.sub!("-f context='Internal promotion authorization'", "-f context='Broad authorization'")
when "authorization-status-wrong-target"
  text.sub!('-f target_url="$authorization_target_url"', %q{-f target_url="https://example.invalid"})
when "authorization-status-wrong-creator"
  text.sub!('.creator.login == "github-actions[bot]"', '.creator.login == "lotwhoo"')
when "authorization-status-wrong-creator-id"
  text.sub!('.creator.id == 41898282', '.creator.id == 1')
when "authorization-status-wrong-url"
  text.sub!('.url == $status_url', '.url != null')
when "authorization-status-sha-url"
  text.sub!('authorization_status_url="https://api.github.com/repos/$canonical_repository/statuses/$authorization_status_id"',
            'authorization_status_url="https://api.github.com/repos/$canonical_repository/statuses/$main_sha"')
when "authorization-job-condition"
  text.sub!("    name: Internal promotion authorization\n", "    name: Internal promotion authorization\n    if: false\n")
when "authorization-step-condition"
  text.sub!("      - name: Authorize current main for internal delivery\n", "      - name: Authorize current main for internal delivery\n        if: false\n")
when "authorization-extra-step"
  marker = "      - name: Authorize current main for internal delivery\n"
  text.sub!(marker, "      - run: echo unexpected\n#{marker}")
when "writer-manual-trigger"
  text.sub!("on:\n  workflow_run:\n", "on:\n  workflow_dispatch:\n  workflow_run:\n")
when "writer-wrong-source-workflow"
  text.sub!("      - Authorize Internal Delivery Pointer\n", "      - Untrusted Authorization\n")
when "writer-wrong-event-type"
  text.sub!("      - completed\n", "      - requested\n")
when "writer-wrong-event-branch"
  text.sub!("      - main\n", "      - develop\n")
when "writer-verify-write"
  text.sub!("      contents: read\n", "      contents: write\n")
when "writer-emits-authorization-name"
  text.sub!("    name: Verify completed internal authorization\n", "    name: Internal promotion authorization\n")
when "writer-wrong-workflow-id"
  text.sub!("authorization_workflow_id='345772544'", "authorization_workflow_id='1'")
when "writer-wrong-owner"
  text.sub!("owner_actor='lotwhoo'", "owner_actor='attacker'")
when "writer-allows-rerun"
  text.sub!(".run_attempt == 1", ".run_attempt >= 1")
when "writer-missing-latest-authorization"
  text.gsub!("latest_authorization_check_id", "ignored_authorization_check_id")
when "writer-wrong-check-app"
  text.sub!(".app.id == 15368", ".app.id == 99999")
when "writer-missing-suite-link"
  text.sub!(".check_suite.id == $suite_id", ".check_suite.id > 0")
when "writer-missing-details-link"
  text.sub!(".details_url == $details", ".details_url != null")
when "writer-missing-latest-status"
  text.gsub!("latest_authorization_status", "ignored_authorization_status")
when "writer-status-only-authorization"
  text.gsub!('.check_suite.id == $suite_id', '.check_suite.id > 0')
when "writer-status-wrong-state"
  text.sub!('.state == "success"', '.state != "failure"')
when "writer-status-wrong-context"
  text.gsub!('.context == "Internal promotion authorization"', '.context != null')
when "writer-status-wrong-creator"
  text.sub!('.creator.login == "github-actions[bot]"', '.creator.login != null')
when "writer-status-wrong-creator-id"
  text.sub!('.creator.id == 41898282', '.creator.id > 0')
when "writer-status-wrong-url"
  text.sub!('.url == $status_url', '.url != null')
when "writer-status-sha-url"
  text.sub!('authorization_status_url="https://api.github.com/repos/$repository/statuses/$authorization_status_id"',
            'authorization_status_url="https://api.github.com/repos/$repository/statuses/$main_sha"')
when "writer-status-missing-time-bound"
  text.sub!('.updated_at <= $job_completed', '.updated_at != null')
when "writer-does-not-repeat-trust"
  marker = "authorization_workflow_id='345772544'"
  index = text.rindex(marker)
  abort "second writer trust marker not found" unless index
  text[index, marker.length] = "authorization_workflow_id='1'"
  true
when "writer-unvalidated-checkout"
  text.sub!('          ref: ${{ steps.trust.outputs.validated_sha }}', '          ref: ${{ github.sha }}')
when "writer-force-push"
  text.sub!('          git push origin "$main_sha:refs/heads/codex/internal-debug"', '          git push --force origin "$main_sha:refs/heads/codex/internal-debug"')
when "writer-missing-fast-forward"
  text.sub!('            if ! git merge-base --is-ancestor "$previous_internal_sha" "$main_sha"; then', '            if [ "$previous_internal_sha" = "$main_sha" ]; then')
when "writer-push-before-precheck"
  precheck = '          scripts/check_internal_branch_policy.sh "$VALIDATED_SHA" "$main_sha" "$checkout_sha"'
  push = '          git push origin "$main_sha:refs/heads/codex/internal-debug"'
  abort "writer precheck or push not found" unless text.include?(precheck) && text.include?(push)
  text.sub!(precheck, "          __WRITER_PRECHECK__")
  text.sub!(push, precheck)
  text.sub!("          __WRITER_PRECHECK__", push)
  true
when "writer-missing-postcheck"
  text.sub!('          scripts/check_internal_branch_policy.sh "$VALIDATED_SHA" "$post_main_sha" "$internal_sha"', '')
when "writer-job-condition"
  text.sub!("    name: Promote verified internal pointer\n", "    name: Promote verified internal pointer\n    if: false\n")
when "writer-step-condition"
  text.sub!("      - name: Repeat authorization and CI trust checks\n", "      - name: Repeat authorization and CI trust checks\n        if: false\n")
when "writer-step-custom-shell"
  text.sub!("        id: trust\n", "        id: trust\n        shell: bash -c 'bash {0} || true'\n")
when "writer-step-continue-on-error"
  text.sub!("        id: trust\n", "        id: trust\n        continue-on-error: true\n")
when "writer-extra-step"
  marker = "      - name: Fast-forward the authorized internal pointer\n"
  text.sub!(marker, "      - run: echo unexpected\n#{marker}")
when "writer-post-ci-missing-dependency"
  text.sub!("    needs: promote\n", "")
when "writer-post-ci-broad-permissions"
  text.sub!("    permissions:\n      actions: write\n      contents: read\n", "    permissions:\n      actions: write\n      contents: write\n")
when "writer-dispatch-missing-fresh-main"
  text.sub!('/git/ref/heads/main" --jq', '/git/ref/heads/develop" --jq')
when "writer-dispatch-missing-fresh-internal"
  text.sub!('/git/ref/heads/codex/internal-debug" --jq', '/git/ref/heads/main" --jq')
when "writer-dispatch-broad-ref-equality"
  text.sub!('[ "$EXPECTED_SHA" != "$main_sha" ] || [ "$EXPECTED_SHA" != "$internal_sha" ]',
            '[ "$EXPECTED_SHA" != "$main_sha" ]')
when "writer-dispatch-waits-with-write-token"
  text.sub!('          dispatch_response=$(gh api --method POST', "          sleep 10\n          dispatch_response=$(gh api --method POST")
when "writer-dispatch-adds-checkout"
  marker = "      - name: Revalidate pointers and dispatch exact internal CI\n"
  text.sub!(marker, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n#{marker}")
when "writer-post-ci-verifier-missing-dependency"
  text.sub!("    needs: dispatch-post-promotion-ci\n", "")
when "writer-post-ci-verifier-write"
  text.sub!("    permissions:\n      actions: read\n      checks: read\n      contents: read\n",
            "    permissions:\n      actions: write\n      checks: read\n      contents: read\n")
when "writer-post-ci-verifier-post"
  text.sub!("          poll=1\n", "          gh api --method POST /unexpected\n          poll=1\n")
when "writer-dispatch-echo-only"
  text.sub!('dispatch_response=$(gh api --method POST', 'dispatch_response=$(echo gh api --method POST')
when "writer-dispatch-wrong-workflow"
  text.sub!("ci_workflow_id='344358206'", "ci_workflow_id='1'")
when "writer-dispatch-slashed-workflow-identifier"
  text.sub!('/actions/workflows/$ci_workflow_id/dispatches',
            '/actions/workflows/.github/workflows/ci.yml/dispatches')
when "writer-dispatch-wrong-ref"
  text.sub!("internal_ref='codex/internal-debug'", "internal_ref='main'")
when "writer-dispatch-wrong-api-version"
  text.sub!("X-GitHub-Api-Version: 2026-03-10", "X-GitHub-Api-Version: 2022-11-28")
when "writer-dispatch-deprecated-run-details"
  text.sub!('-f ref="$internal_ref")', "-f ref=\"$internal_ref\" \\\n            -F return_run_details=true)")
when "writer-dispatch-response-broad-run-id"
  text.sub!('.workflow_run_id == $run_id', '.workflow_run_id > 0')
when "writer-dispatch-response-broad-run-url"
  text.sub!('.run_url == $run_url', '.run_url != null')
when "writer-dispatch-response-broad-html-url"
  text.sub!('.html_url == $html_url', '.html_url != null')
when "writer-dispatch-unbounded-wait"
  text.sub!('if [ "$poll" -ge "$max_polls" ]; then', 'if false; then')
when "writer-dispatch-broad-aggregate"
  text.sub!('.name == "Internal post-promotion CI"', '.name != "Required CI"')
when "writer-dispatch-allows-required-ci"
  text.sub!('[ "$protected_aggregate_count" -ne 0 ]', '[ "$protected_aggregate_count" -lt 0 ]')
when "writer-post-ci-wrong-check-app"
  marker = '.app.id == 15368'
  index = text.rindex(marker)
  abort "post-promotion app marker not found" unless index
  text[index, marker.length] = '.app.id == 1'
  true
when "writer-post-ci-missing-suite-link"
  marker = '.check_suite.id == $suite_id'
  index = text.rindex(marker)
  abort "post-promotion suite marker not found" unless index
  text[index, marker.length] = '.check_suite.id > 0'
  true
when "writer-post-ci-missing-details-link"
  marker = '.details_url == $details'
  index = text.rindex(marker)
  abort "post-promotion details marker not found" unless index
  text[index, marker.length] = '.details_url != null'
  true
when "writer-post-ci-missing-check-id-link"
  text.sub!('[ "$(printf \'%s\' "$linked_aggregate_checks" | jq -r \'.[0].id\')" != "$aggregate_check_id" ]',
            '[ "$(printf \'%s\' "$linked_aggregate_checks" | jq -r \'.[0].id\')" = "" ]')
when "writer-post-ci-check-query-wrong-sha"
  text.sub!('/commits/$EXPECTED_SHA/check-runs?check_name=Internal%20post-promotion%20CI',
            '/commits/main/check-runs?check_name=Internal%20post-promotion%20CI')
when "writer-post-ci-missing-final-main"
  marker = '/git/ref/heads/main" --jq'
  index = text.rindex(marker)
  abort "final main marker not found" unless index
  text[index, marker.length] = '/git/ref/heads/develop" --jq'
  true
when "writer-post-ci-missing-final-internal"
  marker = '/git/ref/heads/codex/internal-debug" --jq'
  index = text.rindex(marker)
  abort "final internal marker not found" unless index
  text[index, marker.length] = '/git/ref/heads/main" --jq'
  true
when "writer-post-ci-broad-final-equality"
  text.sub!('[ "$EXPECTED_SHA" != "$final_internal_sha" ]', '[ "$EXPECTED_SHA" != "$final_main_sha" ]')
when "writer-post-ci-broad-run-attempt"
  marker = '.run_attempt == 1'
  index = text.rindex(marker)
  abort "post-promotion run-attempt marker not found" unless index
  text[index, marker.length] = '.run_attempt >= 1'
  true
when "writer-post-ci-broad-actor"
  marker = '.actor.login == $actor'
  index = text.rindex(marker)
  abort "post-promotion actor marker not found" unless index
  text[index, marker.length] = '.actor.login != null'
  true
when "writer-post-ci-broad-triggering-actor"
  marker = '.triggering_actor.login == $actor'
  index = text.rindex(marker)
  abort "post-promotion triggering-actor marker not found" unless index
  text[index, marker.length] = '.triggering_actor.login != null'
  true
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

    if "$checker" "$ci_fixture_path" "$promotion_fixture_path" "$writer_fixture_path" >"$log_path" 2>&1; then
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
expect_mutation_failure branch-policy-echo-only
expect_mutation_failure missing-ruleset-contract-fixtures
expect_mutation_failure ruleset-contract-echo-only
expect_mutation_failure workflow-dispatch-input
expect_mutation_failure missing-workflow-dispatch
expect_mutation_failure dispatch-aggregate-mints-required-ci
expect_mutation_failure dispatch-missing-ref-gate
expect_mutation_failure dispatch-broad-sha-gate
expect_mutation_failure dispatch-branch-policy-echo-only
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
expect_mutation_failure promotion-unpinned-checkout promotion
expect_mutation_failure promotion-wrong-check-app promotion
expect_mutation_failure authorization-wrong-owner promotion
expect_mutation_failure authorization-missing-triggering-actor promotion
expect_mutation_failure authorization-wrong-workflow-id promotion
expect_mutation_failure authorization-allows-rerun promotion
expect_mutation_failure authorization-missing-current-main-check promotion
expect_mutation_failure authorization-adds-push promotion
expect_mutation_failure authorization-missing-status-write promotion
expect_mutation_failure authorization-broad-status-write promotion
expect_mutation_failure authorization-status-echo-only promotion
expect_mutation_failure authorization-status-wrong-state promotion
expect_mutation_failure authorization-status-wrong-context promotion
expect_mutation_failure authorization-status-wrong-target promotion
expect_mutation_failure authorization-status-wrong-creator promotion
expect_mutation_failure authorization-status-wrong-creator-id promotion
expect_mutation_failure authorization-status-wrong-url promotion
expect_mutation_failure authorization-status-sha-url promotion
expect_mutation_failure authorization-job-condition promotion
expect_mutation_failure authorization-step-condition promotion
expect_mutation_failure authorization-extra-step promotion
expect_mutation_failure writer-manual-trigger writer
expect_mutation_failure writer-wrong-source-workflow writer
expect_mutation_failure writer-wrong-event-type writer
expect_mutation_failure writer-wrong-event-branch writer
expect_mutation_failure writer-verify-write writer
expect_mutation_failure writer-emits-authorization-name writer
expect_mutation_failure writer-wrong-workflow-id writer
expect_mutation_failure writer-wrong-owner writer
expect_mutation_failure writer-allows-rerun writer
expect_mutation_failure writer-missing-latest-authorization writer
expect_mutation_failure writer-wrong-check-app writer
expect_mutation_failure writer-missing-suite-link writer
expect_mutation_failure writer-missing-details-link writer
expect_mutation_failure writer-missing-latest-status writer
expect_mutation_failure writer-status-only-authorization writer
expect_mutation_failure writer-status-wrong-state writer
expect_mutation_failure writer-status-wrong-context writer
expect_mutation_failure writer-status-wrong-creator writer
expect_mutation_failure writer-status-wrong-creator-id writer
expect_mutation_failure writer-status-wrong-url writer
expect_mutation_failure writer-status-sha-url writer
expect_mutation_failure writer-status-missing-time-bound writer
expect_mutation_failure writer-does-not-repeat-trust writer
expect_mutation_failure writer-unvalidated-checkout writer
expect_mutation_failure writer-force-push writer
expect_mutation_failure writer-missing-fast-forward writer
expect_mutation_failure writer-push-before-precheck writer
expect_mutation_failure writer-missing-postcheck writer
expect_mutation_failure writer-job-condition writer
expect_mutation_failure writer-step-condition writer
expect_mutation_failure writer-step-custom-shell writer
expect_mutation_failure writer-step-continue-on-error writer
expect_mutation_failure writer-extra-step writer
expect_mutation_failure writer-post-ci-missing-dependency writer
expect_mutation_failure writer-post-ci-broad-permissions writer
expect_mutation_failure writer-dispatch-missing-fresh-main writer
expect_mutation_failure writer-dispatch-missing-fresh-internal writer
expect_mutation_failure writer-dispatch-broad-ref-equality writer
expect_mutation_failure writer-dispatch-waits-with-write-token writer
expect_mutation_failure writer-dispatch-adds-checkout writer
expect_mutation_failure writer-post-ci-verifier-missing-dependency writer
expect_mutation_failure writer-post-ci-verifier-write writer
expect_mutation_failure writer-post-ci-verifier-post writer
expect_mutation_failure writer-dispatch-echo-only writer
expect_mutation_failure writer-dispatch-wrong-workflow writer
expect_mutation_failure writer-dispatch-slashed-workflow-identifier writer
expect_mutation_failure writer-dispatch-wrong-ref writer
expect_mutation_failure writer-dispatch-wrong-api-version writer
expect_mutation_failure writer-dispatch-deprecated-run-details writer
expect_mutation_failure writer-dispatch-response-broad-run-id writer
expect_mutation_failure writer-dispatch-response-broad-run-url writer
expect_mutation_failure writer-dispatch-response-broad-html-url writer
expect_mutation_failure writer-dispatch-unbounded-wait writer
expect_mutation_failure writer-dispatch-broad-aggregate writer
expect_mutation_failure writer-dispatch-allows-required-ci writer
expect_mutation_failure writer-post-ci-wrong-check-app writer
expect_mutation_failure writer-post-ci-missing-suite-link writer
expect_mutation_failure writer-post-ci-missing-details-link writer
expect_mutation_failure writer-post-ci-missing-check-id-link writer
expect_mutation_failure writer-post-ci-check-query-wrong-sha writer
expect_mutation_failure writer-post-ci-missing-final-main writer
expect_mutation_failure writer-post-ci-missing-final-internal writer
expect_mutation_failure writer-post-ci-broad-final-equality writer
expect_mutation_failure writer-post-ci-broad-run-attempt writer
expect_mutation_failure writer-post-ci-broad-actor writer
expect_mutation_failure writer-post-ci-broad-triggering-actor writer
expect_mutation_failure extra-top-level-writer extra
expect_mutation_failure extra-job-level-writer extra
expect_mutation_failure extra-omitted-permissions extra

echo "CI workflow fixture tests passed: $mutation_count/$mutation_count mutations rejected"
