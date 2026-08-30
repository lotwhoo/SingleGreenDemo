#!/bin/sh
set -eu

workflow_path=${1:-.github/workflows/ci.yml}
promotion_workflow_path=${2:-$(dirname -- "$workflow_path")/promote-internal.yml}
writer_workflow_path=${3:-$(dirname -- "$workflow_path")/promote-authorized-internal.yml}

if [ ! -f "$workflow_path" ]; then
    echo "CI workflow check failed: file not found: $workflow_path" >&2
    exit 1
fi

if [ ! -f "$promotion_workflow_path" ]; then
    echo "CI workflow check failed: file not found: $promotion_workflow_path" >&2
    exit 1
fi

if [ ! -f "$writer_workflow_path" ]; then
    echo "CI workflow check failed: file not found: $writer_workflow_path" >&2
    exit 1
fi

ruby - "$workflow_path" "$promotion_workflow_path" "$writer_workflow_path" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
promotion_path = ARGV.fetch(1)
writer_path = ARGV.fetch(2)
source = File.read(path)
promotion_source = File.read(promotion_path)
writer_source = File.read(writer_path)

begin
  workflow = YAML.load(source)
  promotion_workflow = YAML.load(promotion_source)
  writer_workflow = YAML.load(writer_source)
rescue Psych::SyntaxError => error
  warn "Workflow check failed: YAML parse error: #{error.message}"
  exit 1
end

unless workflow.is_a?(Hash)
  warn "CI workflow check failed: workflow root must be a mapping"
  exit 1
end

unless promotion_workflow.is_a?(Hash)
  warn "CI workflow check failed: promotion workflow root must be a mapping"
  exit 1
end

unless writer_workflow.is_a?(Hash)
  warn "CI workflow check failed: writer workflow root must be a mapping"
  exit 1
end

errors = []
check = lambda do |condition, message|
  errors << message unless condition
end

def grants_write?(permissions)
  case permissions
  when String
    permissions == "write-all" || permissions == "write"
  when Hash
    permissions.values.any? { |access| access == "write" || access == "write-all" }
  else
    false
  end
end

def fail_closed?(entry)
  entry.is_a?(Hash) &&
    (!entry.key?("continue-on-error") || entry["continue-on-error"] == false)
end

def declares_run_shell?(entry)
  return false unless entry.is_a?(Hash)
  defaults = entry["defaults"]
  return false unless defaults.is_a?(Hash)
  run_defaults = defaults["run"]
  run_defaults.is_a?(Hash) && run_defaults.key?("shell")
end

workflow_directory = File.dirname(File.expand_path(path))
promotion_directory = File.dirname(File.expand_path(promotion_path))
writer_directory = File.dirname(File.expand_path(writer_path))
check.call(workflow_directory == promotion_directory,
           "CI and promotion workflows must be validated from the same workflow directory")
check.call(workflow_directory == writer_directory,
           "CI and writer workflows must be validated from the same workflow directory")
check.call(File.basename(promotion_path) == "promote-internal.yml",
           "the reviewed authorization workflow must be named promote-internal.yml")
check.call(File.basename(writer_path) == "promote-authorized-internal.yml",
           "the reviewed writer workflow must be named promote-authorized-internal.yml")

workflow_paths = Dir.glob(File.join(workflow_directory, "*.{yml,yaml}")).sort
check.call(workflow_paths.include?(File.expand_path(path)), "workflow inventory must include the CI workflow")
check.call(workflow_paths.include?(File.expand_path(promotion_path)), "workflow inventory must include promote-internal.yml")
check.call(workflow_paths.include?(File.expand_path(writer_path)), "workflow inventory must include promote-authorized-internal.yml")
write_locations = []
workflow_paths.each do |candidate_path|
  begin
    candidate = YAML.load_file(candidate_path)
  rescue Psych::SyntaxError => error
    errors << "workflow inventory YAML parse error for #{File.basename(candidate_path)}: #{error.message}"
    next
  end
  unless candidate.is_a?(Hash)
    errors << "workflow inventory entry must be a mapping: #{File.basename(candidate_path)}"
    next
  end

  check.call(candidate.key?("permissions") && !candidate["permissions"].nil?,
             "every workflow must explicitly declare top-level permissions: #{File.basename(candidate_path)}")

  if grants_write?(candidate["permissions"])
    write_locations << [File.expand_path(candidate_path), "top-level"]
  end
  candidate_jobs = candidate["jobs"]
  next unless candidate_jobs.is_a?(Hash)
  candidate_jobs.each do |candidate_job_name, candidate_job|
    next unless candidate_job.is_a?(Hash)
    check.call(!candidate_job.key?("uses"),
               "workflow inventory must not contain reusable-workflow jobs: #{File.basename(candidate_path)}:#{candidate_job_name}")
    if grants_write?(candidate_job["permissions"])
      write_locations << [File.expand_path(candidate_path), "job:#{candidate_job_name}"]
    end
    Array(candidate_job["steps"]).each do |candidate_step|
      next unless candidate_step.is_a?(Hash) && candidate_step.key?("uses")
      uses = candidate_step["uses"].to_s
      pinned = uses == "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" ||
        uses == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
      check.call(pinned,
                 "every inventoried action must use a reviewed full commit SHA: #{File.basename(candidate_path)}")
    end
  end
end

expected_write_locations = [
  [File.expand_path(writer_path), "job:promote"],
  [File.expand_path(writer_path), "job:dispatch-post-promotion-ci"],
  [File.expand_path(promotion_path), "job:authorize"]
]
check.call(write_locations == expected_write_locations,
           "only the reviewed authorization, promotion, and post-promotion jobs may request write permissions")

triggers = workflow["on"] || workflow[true]
check.call(triggers.is_a?(Hash), "on must define an event mapping")
triggers = {} unless triggers.is_a?(Hash)

check.call(triggers.keys.sort == %w[pull_request push workflow_dispatch].sort,
           "CI triggers must be exactly pull_request, push, and no-input workflow_dispatch")
dispatch = triggers["workflow_dispatch"]
check.call(dispatch.nil? || (dispatch.is_a?(Hash) && dispatch.empty?),
           "CI workflow_dispatch must not accept inputs")

%w[pull_request push].each do |event|
  contract = triggers[event]
  check.call(contract.is_a?(Hash), "#{event} trigger must be configured")
  next unless contract.is_a?(Hash)

  branches = Array(contract["branches"])
  check.call(branches.sort == ["codex/internal-debug", "main"],
             "#{event} branches must be exactly main and codex/internal-debug")
  check.call(!contract.key?("branches-ignore"), "#{event} must not use branches-ignore")
  check.call(!contract.key?("paths") && !contract.key?("paths-ignore"), "#{event} must not use path filters")
end

permissions = workflow["permissions"]
check.call(permissions.is_a?(Hash) && permissions["contents"] == "read", "permissions.contents must be read")
check.call(!declares_run_shell?(workflow), "CI workflow must not override defaults.run.shell")

concurrency = workflow["concurrency"]
check.call(concurrency.is_a?(Hash), "concurrency must be configured")
if concurrency.is_a?(Hash)
  check.call(concurrency["cancel-in-progress"] == true, "concurrency.cancel-in-progress must be true")
  check.call(concurrency["group"].to_s.include?("github.ref"), "concurrency group must be ref-scoped")
end

jobs = workflow["jobs"]
check.call(jobs.is_a?(Hash), "jobs must be a mapping")
jobs = {} unless jobs.is_a?(Hash)
expected_ci_job_ids = %w[
  branch-contract
  package-matrix
  app-simulator
  release-build
  coverage-and-hygiene
  public-api
  required-ci
]
check.call(jobs.keys.sort == expected_ci_job_ids.sort,
           "CI must contain exactly the seven reviewed job ids")

checkout_sha = "3d3c42e5aac5ba805825da76410c181273ba90b1"
upload_artifact_sha = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"

ci_steps = jobs.values.flat_map do |job|
  Array(job.is_a?(Hash) ? job["steps"] : []).select { |step| step.is_a?(Hash) }
end
checkout_uses = ci_steps.map { |step| step["uses"] if step["uses"].to_s.start_with?("actions/checkout@") }.compact
upload_uses = ci_steps.map { |step| step["uses"] if step["uses"].to_s.start_with?("actions/upload-artifact@") }.compact
all_ci_uses = ci_steps.map { |step| step["uses"] unless step["uses"].to_s.empty? }.compact
check.call(!checkout_uses.empty? && checkout_uses.all? { |uses| uses == "actions/checkout@#{checkout_sha}" },
           "every checkout action must be pinned to the reviewed v7.0.1 commit SHA")
check.call(!upload_uses.empty? && upload_uses.all? { |uses| uses == "actions/upload-artifact@#{upload_artifact_sha}" },
           "every upload-artifact action must be pinned to the reviewed v7.0.1 commit SHA")
allowed_ci_uses = ["actions/checkout@#{checkout_sha}", "actions/upload-artifact@#{upload_artifact_sha}"]
check.call(all_ci_uses.all? { |uses| allowed_ci_uses.include?(uses) },
           "CI steps may use only the two reviewed pinned actions")

jobs.each do |job_name, job|
  next unless job.is_a?(Hash)
  check.call(!job.key?("uses"), "CI job #{job_name} must not call a reusable workflow")
  check.call(!declares_run_shell?(job), "CI job #{job_name} must not override defaults.run.shell")
  check.call(fail_closed?(job),
             "CI job #{job_name} must fail closed and must not continue on error")
  Array(job["steps"]).each do |step|
    check.call(fail_closed?(step),
               "every step in CI job #{job_name} must fail closed and must not continue on error")
    check.call(step.is_a?(Hash) && !step.key?("shell"),
               "CI steps must not override their shell")
  end
  job_permissions = job["permissions"]
  if job_permissions.is_a?(Hash)
    job_permissions.each do |permission, access|
      check.call(access != "write", "CI job #{job_name} must not grant #{permission}: write")
    end
  end
end

branch_job = jobs["branch-contract"]
check.call(branch_job.is_a?(Hash), "branch-contract job is required")
branch_steps = branch_job.is_a?(Hash) ? Array(branch_job["steps"]) : []

checkout = branch_steps.find { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/checkout@") }
check.call(!checkout.nil?, "branch-contract must check out the repository")
if checkout
  checkout_with = checkout["with"]
  check.call(checkout_with.is_a?(Hash) && checkout_with["fetch-depth"] == 0, "branch-contract checkout must use fetch-depth: 0")
end

branch_policy_fixture_steps = branch_steps.select do |step|
  step.is_a?(Hash) && step["run"].to_s.strip == "scripts/test_internal_branch_policy.sh"
end
check.call(branch_policy_fixture_steps.length == 1,
           "branch-contract must have exactly one exact branch-policy fixture step")
check.call(branch_policy_fixture_steps.length == 1 && !branch_policy_fixture_steps.first.key?("if"),
           "branch-policy fixture step must be unconditional")

ruleset_contract_fixture_steps = branch_steps.select do |step|
  step.is_a?(Hash) && step["run"].to_s.strip == "scripts/test_internal_ruleset_contract.sh"
end
check.call(ruleset_contract_fixture_steps.length == 1,
           "branch-contract must have exactly one exact ruleset-contract fixture step")
check.call(ruleset_contract_fixture_steps.length == 1 && !ruleset_contract_fixture_steps.first.key?("if"),
           "ruleset-contract fixture step must be unconditional")
reject_step = branch_steps.find do |step|
  condition = step.is_a?(Hash) ? step["if"].to_s : ""
  condition.include?("github.event_name == 'pull_request'") &&
    condition.include?("github.base_ref == 'codex/internal-debug'")
end
check.call(!reject_step.nil? && reject_step["run"].to_s.match?(%r{(?:^|\n)\s*exit 1(?:\n|$)}),
           "branch-contract must fail pull requests based on codex/internal-debug")

verify_step = branch_steps.find do |step|
  condition = step.is_a?(Hash) ? step["if"].to_s : ""
  condition.include?("github.event_name == 'push'") &&
    condition.include?("github.ref == 'refs/heads/codex/internal-debug'")
end
check.call(!verify_step.nil?, "internal pointer verification must run only on an internal-branch push")
verify_run = verify_step.is_a?(Hash) ? verify_step["run"].to_s : ""
check.call(verify_run.include?("git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'"),
           "internal pointer verification must explicitly fetch origin/main")
check.call(verify_run.include?("reviewed_main_sha='${{ github.event.after }}'"),
           "reviewed SHA must come from github.event.after")
check.call(verify_run.include?('internal_sha="$GITHUB_SHA"'),
           "internal SHA must come from GITHUB_SHA")
check.call(verify_run.include?('if [ "$internal_sha" != "$reviewed_main_sha" ]'),
           "workflow must assert GITHUB_SHA equals github.event.after")
check.call(verify_run.include?("main_sha=$(git rev-parse 'refs/remotes/origin/main^{commit}')"),
           "main SHA must resolve the explicitly fetched origin/main commit")
check.call(!verify_run.include?("github.event.before"),
           "github.event.before must not be trusted as the reviewed SHA")
check.call(verify_run.match?(%r{scripts/check_internal_branch_policy\.sh\s+"\$reviewed_main_sha"\s+"\$main_sha"\s+"\$internal_sha"}),
           "branch policy checker must receive reviewed, main, and internal full SHAs in order")

dispatch_verify_step = branch_steps.find do |step|
  condition = step.is_a?(Hash) ? step["if"].to_s : ""
  condition == "github.event_name == 'workflow_dispatch'"
end
check.call(!dispatch_verify_step.nil?,
           "branch-contract must contain the exact post-promotion workflow_dispatch verifier")
dispatch_verify_run = dispatch_verify_step.is_a?(Hash) ? dispatch_verify_step["run"].to_s : ""
dispatch_verify_markers = [
  %q{[ "$GITHUB_REF" != 'refs/heads/codex/internal-debug' ]},
  "'+refs/heads/main:refs/remotes/origin/main'",
  "'+refs/heads/codex/internal-debug:refs/remotes/origin/codex/internal-debug'",
  "main_sha=$(git rev-parse 'refs/remotes/origin/main^{commit}')",
  "internal_sha=$(git rev-parse 'refs/remotes/origin/codex/internal-debug^{commit}')",
  '[ "$GITHUB_SHA" != "$main_sha" ]',
  '[ "$GITHUB_SHA" != "$internal_sha" ]',
  'scripts/check_internal_branch_policy.sh "$main_sha" "$main_sha" "$internal_sha"'
]
dispatch_verify_markers.each do |marker|
  check.call(dispatch_verify_run.include?(marker),
             "post-promotion dispatch verification missing: #{marker}")
end
dispatch_policy_command = 'scripts/check_internal_branch_policy.sh "$main_sha" "$main_sha" "$internal_sha"'
check.call(dispatch_verify_run.lines.map(&:strip).count(dispatch_policy_command) == 1,
           "post-promotion dispatch must execute the exact branch-policy command once")

expensive_jobs = %w[package-matrix app-simulator release-build coverage-and-hygiene public-api]
expensive_jobs.each do |job_name|
  job = jobs[job_name]
  check.call(job.is_a?(Hash), "#{job_name} job is required")
  next unless job.is_a?(Hash)
  needs = Array(job["needs"])
  check.call(needs.include?("branch-contract"), "#{job_name} must need branch-contract")
end

required_ci = jobs["required-ci"]
check.call(required_ci.is_a?(Hash), "required-ci aggregate job is required")
if required_ci.is_a?(Hash)
  expected_aggregate_name = "${{ github.event_name == 'workflow_dispatch' && 'Internal post-promotion CI' || 'Required CI' }}"
  check.call(required_ci["name"] == expected_aggregate_name,
             "required-ci must use the exact event-split protected/post-promotion display name")
  check.call(required_ci["if"].to_s == "always()", "required-ci must run with always()")
  check.call(required_ci["runs-on"] == "ubuntu-latest", "required-ci must use the reviewed ubuntu-latest runner")
  check.call(fail_closed?(required_ci),
             "required-ci job must fail closed and must not continue on error")
  required_needs = %w[branch-contract package-matrix app-simulator release-build coverage-and-hygiene public-api]
  check.call(Array(required_ci["needs"]).sort == required_needs.sort,
             "required-ci must need exactly all six CI job ids")
  aggregate_steps = Array(required_ci["steps"])
  check.call(aggregate_steps.length == 1, "required-ci must contain one deterministic aggregation step")
  aggregate_step = aggregate_steps.first
  aggregate_env = aggregate_step.is_a?(Hash) ? aggregate_step["env"] : nil
  aggregate_run = aggregate_step.is_a?(Hash) ? aggregate_step["run"].to_s : ""
  check.call(fail_closed?(aggregate_step),
             "required-ci aggregation step must fail closed and must not continue on error")
  check.call(aggregate_step.is_a?(Hash) && !aggregate_step.key?("if"),
             "required-ci aggregation step must be unconditional")
  expected_results = {
    "BRANCH_CONTRACT_RESULT" => "${{ needs.branch-contract.result }}",
    "PACKAGE_MATRIX_RESULT" => "${{ needs.package-matrix.result }}",
    "APP_SIMULATOR_RESULT" => "${{ needs.app-simulator.result }}",
    "RELEASE_BUILD_RESULT" => "${{ needs.release-build.result }}",
    "COVERAGE_AND_HYGIENE_RESULT" => "${{ needs.coverage-and-hygiene.result }}",
    "PUBLIC_API_RESULT" => "${{ needs.public-api.result }}"
  }
  check.call(aggregate_env == expected_results,
             "required-ci must expose every dependency result and no unreviewed inputs")
  expected_results.keys.each do |variable|
    check.call(aggregate_run.include?(%Q{"$#{variable}"}),
               "required-ci must inspect #{variable}")
  end
  check.call(aggregate_run.include?('[ "$result" != "success" ]') &&
               aggregate_run.match?(%r{(?:^|\n)\s*exit 1(?:\n|$)}),
             "required-ci must fail unless every dependency result is success")
end

jobs.each do |job_name, job|
  next unless job.is_a?(Hash)
  if job_name == "required-ci"
    check.call(job.key?("if") && job["if"].to_s == "always()",
               "required-ci must be the only conditional CI job and must use always()")
  else
    check.call(!job.key?("if"),
               "CI job #{job_name} must be unconditional")
  end
end

approved_conditional_step_ids = []
approve_named_condition = lambda do |job_name, step_name, condition|
  matches = Array(jobs.dig(job_name, "steps")).select do |step|
    step.is_a?(Hash) && step["name"] == step_name
  end
  check.call(matches.length == 1,
             "#{job_name} must contain exactly one reviewed conditional step named #{step_name}")
  step = matches.first
  if step
    check.call(step.key?("if") && step["if"].to_s == condition,
               "#{job_name} step #{step_name} must keep its exact reviewed condition")
    approved_conditional_step_ids << step.object_id
  end
end
approve_uses_condition = lambda do |job_name, uses, condition|
  matches = Array(jobs.dig(job_name, "steps")).select do |step|
    step.is_a?(Hash) && step["uses"] == uses
  end
  check.call(matches.length == 1,
             "#{job_name} must contain exactly one reviewed conditional action #{uses}")
  step = matches.first
  if step
    check.call(step.key?("if") && step["if"].to_s == condition,
               "#{job_name} action #{uses} must keep its exact reviewed condition")
    approved_conditional_step_ids << step.object_id
  end
end

approve_named_condition.call(
  "branch-contract",
  "Reject pull requests targeting the delivery pointer",
  "github.event_name == 'pull_request' && github.base_ref == 'codex/internal-debug'"
)
approve_named_condition.call(
  "branch-contract",
  "Verify internal delivery pointer",
  "github.event_name == 'push' && github.ref == 'refs/heads/codex/internal-debug'"
)
approve_named_condition.call(
  "branch-contract",
  "Verify post-promotion dispatch pointer",
  "github.event_name == 'workflow_dispatch'"
)
approve_named_condition.call(
  "package-matrix",
  "Build aggregate-only VAD benchmark",
  "matrix.package == 'VoiceActivityDetectionKit'"
)
approve_named_condition.call(
  "package-matrix",
  "Build privacy-safe ASRCLI",
  "matrix.package == 'VoiceChatCore'"
)
approve_named_condition.call("app-simulator", "Scan User Debug App", "matrix.variant == 'user'")
approve_named_condition.call("app-simulator", "Scan Internal Debug App", "matrix.variant == 'internal'")
approve_uses_condition.call("app-simulator", "actions/upload-artifact@#{upload_artifact_sha}", "always()")
approve_named_condition.call("release-build", "Scan User Release App", "matrix.variant == 'user'")
approve_named_condition.call("release-build", "Scan Internal Release App", "matrix.variant == 'internal'")
approve_uses_condition.call("release-build", "actions/upload-artifact@#{upload_artifact_sha}", "always()")
approve_uses_condition.call("coverage-and-hygiene", "actions/upload-artifact@#{upload_artifact_sha}", "always()")

all_conditional_steps = jobs.values.flat_map do |job|
  Array(job.is_a?(Hash) ? job["steps"] : []).select do |step|
    step.is_a?(Hash) && step.key?("if")
  end
end
check.call(all_conditional_steps.length == 12 &&
             all_conditional_steps.map(&:object_id).sort == approved_conditional_step_ids.sort,
           "CI step conditions must match exactly the twelve reviewed conditional steps; every other step must be unconditional")

def matrix_rows(job)
  return [] unless job.is_a?(Hash)
  strategy = job["strategy"]
  return [] unless strategy.is_a?(Hash)
  matrix = strategy["matrix"]
  return [] unless matrix.is_a?(Hash)
  Array(matrix["include"])
end

def expected_rows?(rows, expected)
  return false unless rows.length == expected.length
  normalized = rows.map do |row|
    next {} unless row.is_a?(Hash)
    row.transform_keys(&:to_s)
  end
  normalized == expected
end

debug_rows = matrix_rows(jobs["app-simulator"])
expected_debug_rows = [
  {"variant"=>"user", "scheme"=>"SingleGreenUser", "configuration"=>"User-Debug", "artifact_suffix"=>"user-debug"},
  {"variant"=>"internal", "scheme"=>"SingleGreenInternal", "configuration"=>"Internal-Debug", "artifact_suffix"=>"internal-debug"}
]
check.call(expected_rows?(debug_rows, expected_debug_rows),
           "app-simulator must have exactly the reviewed User-Debug and Internal-Debug rows")
debug_steps = Array(jobs.dig("app-simulator", "steps"))
debug_test_step = debug_steps.find do |step|
  step.is_a?(Hash) && step["run"].to_s.include?("test -only-testing:SingleGreenDemoTests")
end
debug_test_run = debug_test_step.is_a?(Hash) ? debug_test_step["run"].to_s : ""
check.call(debug_test_run.include?('-scheme "${{ matrix.scheme }}"') &&
             debug_test_run.include?('-configuration "${{ matrix.configuration }}"') &&
             debug_test_run.include?('-derivedDataPath "$RUNNER_TEMP/SingleGreenDemo-${{ matrix.artifact_suffix }}"') &&
             debug_test_run.include?('-resultBundlePath "$RUNNER_TEMP/SingleGreenDemo-${{ matrix.artifact_suffix }}.xcresult"'),
           "app-simulator must execute each Debug scheme/configuration test row")

debug_artifact_step = debug_steps.find do |step|
  run = step.is_a?(Hash) ? step["run"].to_s : ""
  run.include?("-destination 'generic/platform=iOS Simulator'") &&
    run.include?('-derivedDataPath "$RUNNER_TEMP/SingleGreenDemo-${{ matrix.artifact_suffix }}-artifact"') &&
    run.match?(%r{(?:^|\s)build(?:\s|$)})
end
debug_artifact_run = debug_artifact_step.is_a?(Hash) ? debug_artifact_step["run"].to_s : ""
check.call(debug_artifact_run.include?('-scheme "${{ matrix.scheme }}"') &&
             debug_artifact_run.include?('-configuration "${{ matrix.configuration }}"') &&
             debug_artifact_run.include?("CODE_SIGNING_ALLOWED=NO"),
           "app-simulator must separately build a generic Simulator App-only Debug artifact")

release_rows = matrix_rows(jobs["release-build"])
expected_release_rows = [
  {"variant"=>"user", "scheme"=>"SingleGreenUser", "configuration"=>"User-Release", "artifact_suffix"=>"user-release"},
  {"variant"=>"internal", "scheme"=>"SingleGreenInternal", "configuration"=>"Internal-Release", "artifact_suffix"=>"internal-release"}
]
check.call(expected_rows?(release_rows, expected_release_rows),
           "release-build must have exactly the reviewed User-Release and Internal-Release rows")

allowed_matrix_keys = %w[variant scheme configuration artifact_suffix].sort
(debug_rows + release_rows).each do |row|
  next unless row.is_a?(Hash)
  check.call(row.keys.map(&:to_s).sort == allowed_matrix_keys,
             "App matrices must not contain command-valued fields")
end

def scanner_step(job, script, variant)
  steps = job.is_a?(Hash) ? Array(job["steps"]) : []
  steps.find do |step|
    step.is_a?(Hash) && step["run"].to_s.include?(script) &&
      step["if"].to_s.include?("matrix.variant == '#{variant}'")
  end
end

{
  "app-simulator" => jobs["app-simulator"],
  "release-build" => jobs["release-build"]
}.each do |job_name, job|
  user_scanner = scanner_step(job, "scripts/check_user_artifact_isolation.sh", "user")
  internal_scanner = scanner_step(job, "scripts/check_internal_artifact_capabilities.sh", "internal")
  check.call(!user_scanner.nil?,
             "#{job_name} must explicitly run the User scanner only for the user row")
  check.call(!internal_scanner.nil?,
             "#{job_name} must explicitly run the Internal scanner only for the internal row")

  if job_name == "app-simulator"
    clean_artifact_path = 'SingleGreenDemo-${{ matrix.artifact_suffix }}-artifact/Build/Products/${{ matrix.configuration }}-iphonesimulator/SingleGreenDemo.app'
    check.call(user_scanner.is_a?(Hash) && user_scanner["run"].to_s.include?(clean_artifact_path),
               "app-simulator User scanner must inspect the separate App-only Debug artifact")
    check.call(internal_scanner.is_a?(Hash) && internal_scanner["run"].to_s.include?(clean_artifact_path),
               "app-simulator Internal scanner must inspect the separate App-only Debug artifact")
  end

  steps = job.is_a?(Hash) ? Array(job["steps"]) : []
  combined_runs = steps.map { |step| step.is_a?(Hash) ? step["run"] : nil }.compact.join("\n")
  check.call(combined_runs.include?('-derivedDataPath "$RUNNER_TEMP/SingleGreenDemo-${{ matrix.artifact_suffix }}"'),
             "#{job_name} must use a matrix-unique DerivedData path")
  check.call(combined_runs.include?('-resultBundlePath "$RUNNER_TEMP/SingleGreenDemo-${{ matrix.artifact_suffix }}.xcresult"'),
             "#{job_name} must create a matrix-unique result bundle")

  upload = steps.find { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/upload-artifact@") }
  check.call(!upload.nil?, "#{job_name} must upload its result bundle")
  if upload
    upload_with = upload["with"]
    check.call(upload["if"].to_s == "always()", "#{job_name} result upload must run always")
    check.call(upload_with.is_a?(Hash) && upload_with["name"].to_s.include?("matrix.artifact_suffix"),
               "#{job_name} upload name must be matrix-unique")
    check.call(upload_with.is_a?(Hash) && upload_with["path"].to_s.include?("matrix.artifact_suffix"),
               "#{job_name} upload path must be matrix-unique")
  end
end

release_runs = Array(jobs.dig("release-build", "steps")).map { |step| step.is_a?(Hash) ? step["run"] : nil }.compact.join("\n")
check.call(release_runs.include?('-scheme "${{ matrix.scheme }}"') &&
             release_runs.include?('-configuration "${{ matrix.configuration }}"') &&
             release_runs.include?("-destination 'generic/platform=iOS Simulator'") &&
             release_runs.include?("ONLY_ACTIVE_ARCH=NO") &&
             release_runs.include?("'ARCHS=arm64 x86_64'"),
           "release-build must build a universal arm64/x86_64 Simulator App")

%w[package-matrix coverage-and-hygiene public-api].each do |job_name|
  job_text = jobs[job_name].to_s
  check.call(!job_text.include?("SingleGreenUser") && !job_text.include?("SingleGreenInternal") && !job_text.include?("matrix.variant"),
             "#{job_name} must remain flavor-neutral and run once")
end

all_runs = jobs.values.flat_map do |job|
  Array(job.is_a?(Hash) ? job["steps"] : []).map { |step| step.is_a?(Hash) ? step["run"] : nil }.compact
end.join("\n")
all_steps = jobs.values.flat_map do |job|
  Array(job.is_a?(Hash) ? job["steps"] : []).select { |step| step.is_a?(Hash) }
end
check.call(all_steps.count { |step| step["run"].to_s.strip == "scripts/test_internal_branch_policy.sh" } == 1,
           "branch-policy fixtures must not be duplicated across jobs")
check.call(all_steps.count { |step| step["run"].to_s.strip == "scripts/test_internal_ruleset_contract.sh" } == 1,
           "ruleset-contract fixtures must not be duplicated across jobs")
check.call(all_runs.scan(%r{scripts/check_internal_branch_policy\.sh}).length == 2,
           "push and workflow_dispatch branch-policy validations must each appear exactly once")


# The split delivery contract deliberately keeps the ruleset-producing authorization
# check in a completed read-only workflow suite before a separate workflow_run writer.
authorization_triggers = promotion_workflow["on"] || promotion_workflow[true]
check.call(promotion_workflow["name"] == "Authorize Internal Delivery Pointer",
           "authorization workflow name must remain stable")
check.call(authorization_triggers.is_a?(Hash) && authorization_triggers.keys == ["workflow_dispatch"],
           "authorization must be manual workflow_dispatch only")
authorization_dispatch = authorization_triggers.is_a?(Hash) ? authorization_triggers["workflow_dispatch"] : nil
check.call(authorization_dispatch.nil? || (authorization_dispatch.is_a?(Hash) && authorization_dispatch.empty?),
           "authorization workflow_dispatch must not accept inputs")
check.call(promotion_workflow["permissions"] == {}, "authorization top-level permissions must be empty")
check.call(!declares_run_shell?(promotion_workflow), "authorization must not override defaults.run.shell")

writer_triggers = writer_workflow["on"] || writer_workflow[true]
check.call(writer_workflow["name"] == "Promote Authorized Internal Pointer",
           "writer workflow name must remain stable")
check.call(writer_triggers.is_a?(Hash) && writer_triggers.keys == ["workflow_run"],
           "writer must be triggered only by workflow_run")
writer_run_trigger = writer_triggers.is_a?(Hash) ? writer_triggers["workflow_run"] : nil
if writer_run_trigger.is_a?(Hash)
  check.call(Array(writer_run_trigger["workflows"]) == ["Authorize Internal Delivery Pointer"],
             "writer must accept only the exact authorization workflow")
  check.call(Array(writer_run_trigger["types"]) == ["completed"],
             "writer must accept only completed authorization runs")
  check.call(Array(writer_run_trigger["branches"]) == ["main"],
             "writer workflow_run must be limited to main")
else
  check.call(false, "writer workflow_run trigger must be a mapping")
end
check.call(writer_workflow["permissions"] == {}, "writer top-level permissions must be empty")
check.call(!declares_run_shell?(writer_workflow), "writer must not override defaults.run.shell")

{"authorization"=>promotion_workflow, "writer"=>writer_workflow}.each do |label, delivery_workflow|
  delivery_concurrency = delivery_workflow["concurrency"]
  check.call(delivery_concurrency.is_a?(Hash) &&
               delivery_concurrency["group"] == "promote-internal" &&
               delivery_concurrency["cancel-in-progress"] == false,
             "#{label} must use the fixed non-cancelling promote-internal concurrency group")
end

authorization_jobs = promotion_workflow["jobs"]
authorization_jobs = {} unless authorization_jobs.is_a?(Hash)
check.call(authorization_jobs.keys == ["authorize"],
           "authorization workflow must contain exactly one authorize job")
authorization_job = authorization_jobs["authorize"]
authorization_job = {} unless authorization_job.is_a?(Hash)
check.call(authorization_job["name"] == "Internal promotion authorization",
           "authorization job/check name must remain stable")
check.call(authorization_job["runs-on"] == "ubuntu-latest",
           "authorization job must use ubuntu-latest")
check.call(authorization_job["permissions"] == {
               "actions"=>"read", "checks"=>"read", "contents"=>"read", "statuses"=>"write"
             },
           "authorization job must have only reviewed reads plus commit-status write")
check.call(!authorization_job.key?("if") && fail_closed?(authorization_job) && !declares_run_shell?(authorization_job),
           "authorization job must be unconditional, fail closed, and use the default shell")
authorization_steps = Array(authorization_job["steps"])
check.call(authorization_steps.length == 2, "authorization job must contain exactly two reviewed steps")
authorization_checkout = authorization_steps[0].is_a?(Hash) ? authorization_steps[0] : {}
authorization_step = authorization_steps[1].is_a?(Hash) ? authorization_steps[1] : {}
check.call(authorization_checkout["uses"] == "actions/checkout@#{checkout_sha}" &&
             authorization_checkout["with"] == {"ref"=>"refs/heads/main", "fetch-depth"=>0, "persist-credentials"=>false},
           "authorization must check out exact main with pinned checkout and no credentials")
check.call(authorization_step["name"] == "Authorize current main for internal delivery" &&
             authorization_step["env"] == {"GH_TOKEN"=>"${{ github.token }}"},
           "authorization trust step topology and token must remain exact")
authorization_steps.each do |step|
  check.call(step.is_a?(Hash) && !step.key?("if") && !step.key?("shell") && fail_closed?(step),
             "authorization steps must be unconditional, default-shell, and fail closed")
end
authorization_run = authorization_step["run"].to_s

authorization_markers = [
  "canonical_repository='lotwhoo/SingleGreenDemo'",
  "canonical_workflow_path='.github/workflows/promote-internal.yml'",
  "canonical_workflow_id='345772544'",
  "canonical_actor='lotwhoo'",
  '[ "$GITHUB_ACTOR" != "$canonical_actor" ]',
  '[ "$GITHUB_TRIGGERING_ACTOR" != "$canonical_actor" ]',
  '[ "$GITHUB_RUN_ATTEMPT" != \'1\' ]',
  '"/repos/$canonical_repository/actions/runs/$GITHUB_RUN_ID"',
  '.workflow_id == $workflow_id',
  '.event == "workflow_dispatch"',
  '.status == "in_progress"',
  '.conclusion == null',
  '.head_repository.full_name == $repository',
  '.actor.login == $actor',
  '.triggering_actor.login == $actor',
  "git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'",
  'scripts/check_internal_branch_policy.sh "$main_sha" "$main_sha" "$main_sha"',
  '/actions/workflows/ci.yml/runs?branch=main&event=push&status=completed&head_sha=$main_sha',
  '/actions/runs/$ci_run_id/attempts/$ci_attempt/jobs',
  '.name == "Required CI"',
  '.app.id == 15368',
  '.check_suite.id == $suite_id',
  '.details_url == $details',
  'latest_required_check_id',
  '/attempts/1/jobs?per_page=100',
  '.status == "in_progress"',
  '.conclusion == null',
  'authorization_target_url="https://github.com/$canonical_repository/actions/runs/$GITHUB_RUN_ID/job/$authorization_job_id"',
  'authorization_status_id=$(printf \'%s\' "$authorization_status" | jq -er',
  'authorization_status_url="https://api.github.com/repos/$canonical_repository/statuses/$main_sha"',
  "authorization_description='Owner-authorized current main for internal delivery'",
  '/statuses/$main_sha',
  "X-GitHub-Api-Version: 2026-03-10",
  "-f state='success'",
  "-f context='Internal promotion authorization'",
  '-f description="$authorization_description"',
  '-f target_url="$authorization_target_url"',
  '.id == $status_id',
  '.url == $status_url',
  '.description == $description',
  '.target_url == $target',
  '.creator.login == "github-actions[bot]"',
  '.creator.id == 41898282',
  '.creator.type == "Bot"'
]
authorization_markers.each do |marker|
  check.call(authorization_run.include?(marker), "authorization trust check missing: #{marker}")
end
check.call(authorization_run.scan(/\.app\.id == \d+/) == [".app.id == 15368", ".app.id == 15368"],
           "authorization must bind every accepted check to GitHub Actions app 15368")
check.call(authorization_run.scan(/\.check_suite\.id == \$suite_id/).length == 1 &&
             authorization_run.scan(/\.details_url == \$details/).length == 1,
           "authorization must bind Required CI to its exact suite and job details URL")
check.call(!authorization_run.match?(%r{(?:^|\n)\s*git\s+push\b}),
           "authorization workflow must not push refs")
status_post_marker = 'authorization_status=$(gh api --method POST'
check.call(authorization_run.include?(status_post_marker) &&
             authorization_run.index('latest_required_check_id') < authorization_run.index(status_post_marker) &&
             authorization_run.index(status_post_marker) < authorization_run.index('authorization_status_id=') &&
             authorization_run.index('authorization_status_id=') < authorization_run.index('.url == $status_url'),
           "authorization must post and validate one commit status only after Required CI validation")

writer_jobs = writer_workflow["jobs"]
writer_jobs = {} unless writer_jobs.is_a?(Hash)
check.call(writer_jobs.keys.sort == %w[dispatch-post-promotion-ci promote verify verify-post-promotion-ci],
           "writer must contain exactly verify, promote, dispatch, and post-promotion verification jobs")
check.call(writer_jobs.values.none? { |job| job.is_a?(Hash) && job["name"] == "Internal promotion authorization" },
           "writer must not emit the authorization ruleset check name")
verify_job = writer_jobs["verify"]
promote_job = writer_jobs["promote"]
dispatch_job = writer_jobs["dispatch-post-promotion-ci"]
post_promotion_job = writer_jobs["verify-post-promotion-ci"]
verify_job = {} unless verify_job.is_a?(Hash)
promote_job = {} unless promote_job.is_a?(Hash)
dispatch_job = {} unless dispatch_job.is_a?(Hash)
post_promotion_job = {} unless post_promotion_job.is_a?(Hash)
check.call(verify_job["permissions"] == {"actions"=>"read", "checks"=>"read", "contents"=>"read"},
           "writer verify job must be read-only")
check.call(promote_job["permissions"] == {"actions"=>"read", "checks"=>"read", "contents"=>"write"},
           "writer promote job must have only the reviewed read/read/write permissions")
check.call(dispatch_job["permissions"] == {"actions"=>"write", "contents"=>"read"},
           "post-promotion dispatch job must have only actions: write and contents: read")
check.call(post_promotion_job["permissions"] == {
               "actions"=>"read", "checks"=>"read", "contents"=>"read"
             },
           "post-promotion verification job must have only actions/checks/contents read")
check.call(Array(promote_job["needs"]) == ["verify"],
           "writer promote job must depend on read-only verification")
check.call(Array(dispatch_job["needs"]) == ["promote"],
           "post-promotion dispatch job must depend exactly on successful promotion")
check.call(Array(post_promotion_job["needs"]) == ["dispatch-post-promotion-ci"],
           "post-promotion verification must depend exactly on successful dispatch")
check.call(dispatch_job["timeout-minutes"] == 5,
           "post-promotion dispatch job must retain the short five-minute bound")
check.call(post_promotion_job["timeout-minutes"] == 45,
           "post-promotion verification job must retain the reviewed 45-minute outer bound")
[verify_job, promote_job, dispatch_job, post_promotion_job].each do |job|
  check.call(job["runs-on"] == "ubuntu-latest" && !job.key?("if") && fail_closed?(job) && !declares_run_shell?(job),
             "writer jobs must be unconditional ubuntu-latest default-shell fail-closed jobs")
end

verify_steps = Array(verify_job["steps"])
promote_steps = Array(promote_job["steps"])
dispatch_steps = Array(dispatch_job["steps"])
post_promotion_steps = Array(post_promotion_job["steps"])
check.call(verify_steps.length == 1 && promote_steps.length == 3,
           "writer topology must be one verification step then exactly three promote steps")
check.call(dispatch_steps.length == 1 && post_promotion_steps.length == 1,
           "post-promotion CI must have one bounded dispatch step and one separate verification step")
(verify_steps + promote_steps + dispatch_steps + post_promotion_steps).each do |step|
  check.call(step.is_a?(Hash) && !step.key?("if") && !step.key?("shell") && fail_closed?(step),
             "writer steps must be unconditional, default-shell, and fail closed")
end
verify_step = verify_steps[0].is_a?(Hash) ? verify_steps[0] : {}
trust_step = promote_steps[0].is_a?(Hash) ? promote_steps[0] : {}
writer_checkout = promote_steps[1].is_a?(Hash) ? promote_steps[1] : {}
mutation_step = promote_steps[2].is_a?(Hash) ? promote_steps[2] : {}
dispatch_step = dispatch_steps[0].is_a?(Hash) ? dispatch_steps[0] : {}
post_promotion_step = post_promotion_steps[0].is_a?(Hash) ? post_promotion_steps[0] : {}
expected_event_env = {
  "AUTHORIZATION_RUN_ID"=>"${{ github.event.workflow_run.id }}",
  "GH_TOKEN"=>"${{ github.token }}"
}
check.call(verify_step["name"] == "Verify authorization and current main" && verify_step["env"] == expected_event_env,
           "writer verify step must consume only the event run id and github.token")
check.call(trust_step["name"] == "Repeat authorization and CI trust checks" &&
             trust_step["id"] == "trust" && trust_step["env"] == expected_event_env,
           "writer write-token trust step must repeat the exact event-based verification")
check.call(writer_checkout["uses"] == "actions/checkout@#{checkout_sha}" &&
             writer_checkout["with"] == {
               "ref"=>"${{ steps.trust.outputs.validated_sha }}",
               "fetch-depth"=>0,
               "persist-credentials"=>true
             },
           "writer must check out only the SHA validated under write-token trust checks")
check.call(mutation_step["name"] == "Fast-forward the authorized internal pointer" &&
             mutation_step["id"] == "promotion" &&
             mutation_step["env"] == {"VALIDATED_SHA"=>"${{ steps.trust.outputs.validated_sha }}"},
           "writer mutation step must consume only the validated SHA")
check.call(promote_job["outputs"] == {"promoted_sha"=>"${{ steps.promotion.outputs.promoted_sha }}"},
           "promote job must expose only the postchecked internal SHA")
check.call(dispatch_job["outputs"] == {
               "dispatched_run_id"=>"${{ steps.dispatch.outputs.dispatched_run_id }}",
               "expected_sha"=>"${{ steps.dispatch.outputs.expected_sha }}"
             },
           "dispatch job must expose only its exact returned run id and freshly revalidated SHA")
check.call(dispatch_step["name"] == "Revalidate pointers and dispatch exact internal CI" &&
             dispatch_step["id"] == "dispatch" &&
             dispatch_step["env"] == {
               "EXPECTED_SHA"=>"${{ needs.promote.outputs.promoted_sha }}",
               "GH_TOKEN"=>"${{ github.token }}"
             },
           "dispatch step must consume only promoted SHA and github.token")
check.call(post_promotion_step["name"] == "Require exact internal CI success" &&
             post_promotion_step["env"] == {
               "EXPECTED_RUN_ID"=>"${{ needs.dispatch-post-promotion-ci.outputs.dispatched_run_id }}",
               "EXPECTED_SHA"=>"${{ needs.dispatch-post-promotion-ci.outputs.expected_sha }}",
               "GH_TOKEN"=>"${{ github.token }}"
             },
           "post-promotion verification must consume only dispatch outputs and github.token")

writer_trust_markers = [
  "repository='lotwhoo/SingleGreenDemo'",
  "authorization_path='.github/workflows/promote-internal.yml'",
  "authorization_workflow_id='345772544'",
  "owner_actor='lotwhoo'",
  '"/repos/$repository/actions/runs/$AUTHORIZATION_RUN_ID"',
  '.workflow_id == $workflow_id',
  '.event == "workflow_dispatch"',
  '.status == "completed"',
  '.conclusion == "success"',
  '.head_branch == "main"',
  '.head_sha == $sha',
  '.run_attempt == 1',
  '.repository.full_name == $repository',
  '.head_repository.full_name == $repository',
  '.actor.login == $actor',
  '.triggering_actor.login == $actor',
  '/git/ref/heads/main',
  '/attempts/1/jobs',
  '.name == "Internal promotion authorization"',
  'check_name=Internal%20promotion%20authorization',
  '.app.id == 15368',
  '.check_suite.id == $suite_id',
  '.details_url == $details',
  'latest_authorization_check_id',
  '/commits/$main_sha/statuses?per_page=100',
  'latest_authorization_status',
  'authorization_status_id=$(printf \'%s\' "$latest_authorization_status" | jq -er',
  'authorization_status_url="https://api.github.com/repos/$repository/statuses/$main_sha"',
  "authorization_description='Owner-authorized current main for internal delivery'",
  '.id == $status_id',
  '.url == $status_url',
  '.state == "success"',
  '.context == "Internal promotion authorization"',
  '.description == $description',
  '.target_url == $target',
  '.creator.login == "github-actions[bot]"',
  '.creator.id == 41898282',
  '.creator.type == "Bot"',
  '.created_at >= $job_started',
  '.updated_at <= $job_completed',
  '/actions/workflows/ci.yml/runs?branch=main&event=push&status=completed&head_sha=$main_sha',
  '.name == "Required CI"',
  'check_name=Required%20CI',
  'latest_required_check_id',
  '.conclusion == "success"'
]
[verify_step["run"].to_s, trust_step["run"].to_s].each do |trust_run|
  writer_trust_markers.each do |marker|
    check.call(trust_run.include?(marker), "writer repeated trust check missing: #{marker}")
  end
  check.call(trust_run.scan(/\.app\.id == \d+/) == [".app.id == 15368", ".app.id == 15368", ".app.id == 15368", ".app.id == 15368"],
             "writer must bind every accepted authorization and CI check to app 15368")
  check.call(trust_run.scan(/\.check_suite\.id == \$suite_id/).length == 2 &&
               trust_run.scan(/\.details_url == \$details/).length == 2,
             "writer must bind authorization and Required CI to exact suites and job details URLs")
end
check.call(trust_step["run"].to_s.include?('echo "validated_sha=$main_sha" >> "$GITHUB_OUTPUT"'),
           "writer trust step must emit only the revalidated current main SHA")

mutation_run = mutation_step["run"].to_s
precheck = 'scripts/check_internal_branch_policy.sh "$VALIDATED_SHA" "$main_sha" "$checkout_sha"'
push = 'git push origin "$main_sha:refs/heads/codex/internal-debug"'
postcheck = 'scripts/check_internal_branch_policy.sh "$VALIDATED_SHA" "$post_main_sha" "$internal_sha"'
check.call(mutation_run.include?(precheck) && mutation_run.include?(push) && mutation_run.include?(postcheck) &&
             mutation_run.index(precheck) < mutation_run.index(push) && mutation_run.index(push) < mutation_run.index(postcheck),
           "writer must order precheck, exact pointer push, and postcheck")
check.call(mutation_run.include?('git merge-base --is-ancestor "$previous_internal_sha" "$main_sha"') &&
             mutation_run.index('git merge-base --is-ancestor') < mutation_run.index(push),
           "writer must prove fast-forward ancestry before mutation")
writer_push_lines = mutation_run.lines.map(&:strip).select { |line| line.match?(%r{^git\s+push\b}) }
check.call(writer_push_lines == [push] &&
             writer_push_lines.none? { |line| line.include?("--force") || line.match?(%r{^git\s+push\s+-f\b}) },
           "writer must contain one exact non-force pointer push")
check.call(mutation_run.include?("'+refs/heads/codex/internal-debug:refs/remotes/origin/codex/internal-debug'") &&
             mutation_run.include?("post_main_sha=$(git rev-parse 'refs/remotes/origin/main^{commit}')"),
           "writer must freshly refetch main and the internal pointer before postcheck")
check.call(mutation_run.include?('echo "promoted_sha=$internal_sha" >> "$GITHUB_OUTPUT"') &&
             mutation_run.index(postcheck) < mutation_run.index('echo "promoted_sha=$internal_sha"'),
           "writer must expose the promoted SHA only after the exact postcheck")

dispatch_run = dispatch_step["run"].to_s
dispatch_markers = [
  "ci_workflow_id='344358206'",
  "internal_ref='codex/internal-debug'",
  'X-GitHub-Api-Version: 2026-03-10',
  '/git/ref/heads/main',
  '/git/ref/heads/codex/internal-debug',
  '[ "$EXPECTED_SHA" != "$main_sha" ]',
  '[ "$EXPECTED_SHA" != "$internal_sha" ]',
  '/actions/workflows/$ci_workflow_id/dispatches',
  '-f ref="$internal_ref"',
  '.workflow_run_id',
  '.workflow_run_id == $run_id',
  '.run_url == $run_url',
  '.html_url == $html_url',
  'echo "dispatched_run_id=$dispatch_run_id" >> "$GITHUB_OUTPUT"',
  'echo "expected_sha=$EXPECTED_SHA" >> "$GITHUB_OUTPUT"'
]
dispatch_markers.each do |marker|
  check.call(dispatch_run.include?(marker),
             "post-promotion dispatch missing: #{marker}")
end
dispatch_post_marker = 'dispatch_response=$(gh api --method POST'
check.call(dispatch_run.scan(%r{gh api --method POST}).length == 1 &&
             dispatch_run.include?(dispatch_post_marker) &&
             dispatch_run.index('/git/ref/heads/main') < dispatch_run.index(dispatch_post_marker) &&
             dispatch_run.index('/git/ref/heads/codex/internal-debug') < dispatch_run.index(dispatch_post_marker) &&
             dispatch_run.index('[ "$EXPECTED_SHA" != "$main_sha" ]') < dispatch_run.index(dispatch_post_marker) &&
             dispatch_run.index(dispatch_post_marker) < dispatch_run.index('echo "dispatched_run_id='),
           "dispatch job must freshly verify both refs before exactly one dispatch and only then expose outputs")
check.call(dispatch_run.scan(/X-GitHub-Api-Version: [0-9-]+/) ==
             Array.new(3, "X-GitHub-Api-Version: 2026-03-10"),
           "every dispatch-job API call must use the exact reviewed API version")
check.call(!dispatch_run.include?("return_run_details") &&
             !dispatch_run.include?("ci_workflow_path=") &&
             dispatch_run.scan('/actions/workflows/$ci_workflow_id/dispatches').length == 1,
           "dispatch must use the numeric workflow id once and no deprecated run-details field or slashed workflow path")
check.call(!dispatch_run.include?("sleep ") &&
             !dispatch_run.include?('dispatched_run=$(gh api --method GET') &&
             !dispatch_run.include?("while :"),
           "actions-write dispatch job must not wait for or inspect the dispatched run")

post_promotion_run = post_promotion_step["run"].to_s
post_promotion_markers = [
  "ci_workflow_id='344358206'",
  "ci_workflow_path='.github/workflows/ci.yml'",
  "internal_branch='codex/internal-debug'",
  "expected_actor='github-actions[bot]'",
  'max_polls=180',
  'poll_interval_seconds=10',
  'X-GitHub-Api-Version: 2026-03-10',
  '/actions/runs/$dispatch_run_id',
  '.workflow_id == $workflow_id',
  '.event == "workflow_dispatch"',
  '.head_branch == $branch',
  '.head_sha == $sha',
  '.run_attempt == 1',
  '.repository.full_name == $repository',
  '.head_repository.full_name == $repository',
  '.actor.login == $actor',
  '.triggering_actor.login == $actor',
  'if [ "$poll" -ge "$max_polls" ]',
  'sleep "$poll_interval_seconds"',
  '/attempts/1/jobs?per_page=100',
  '.name == "Internal post-promotion CI"',
  '.name == "Required CI"',
  '[ "$protected_aggregate_count" -ne 0 ]',
  'dispatched_suite_id=',
  'aggregate_check_id=',
  'aggregate_details_url="https://github.com/$repository/actions/runs/$dispatch_run_id/job/$aggregate_job_id"',
  '/commits/$EXPECTED_SHA/check-runs?check_name=Internal%20post-promotion%20CI&filter=latest&per_page=100',
  '.app.id == 15368',
  '.check_suite.id == $suite_id',
  '.details_url == $details',
  '[ "$(printf \'%s\' "$linked_aggregate_checks" | jq -r \'.[0].id\')" != "$aggregate_check_id" ]',
  'final_main_sha=$(gh api --method GET',
  'final_internal_sha=$(gh api --method GET',
  '/git/ref/heads/main',
  '/git/ref/heads/codex/internal-debug',
  '[ "$EXPECTED_SHA" != "$final_main_sha" ]',
  '[ "$EXPECTED_SHA" != "$final_internal_sha" ]'
]
post_promotion_markers.each do |marker|
  check.call(post_promotion_run.include?(marker),
             "post-promotion dispatch verification missing: #{marker}")
end
check.call(post_promotion_run.scan(/X-GitHub-Api-Version: [0-9-]+/) ==
             Array.new(5, "X-GitHub-Api-Version: 2026-03-10"),
           "every post-promotion verification API call must use the exact reviewed API version")
metadata_marker = 'dispatched_run=$(gh api --method GET'
aggregate_marker = 'dispatched_jobs=$(gh api --method GET'
aggregate_check_marker = 'aggregate_checks=$(gh api --method GET'
check.call(post_promotion_run.scan(%r{gh api --method POST}).empty? &&
             post_promotion_run.include?(metadata_marker) &&
             post_promotion_run.include?(aggregate_marker) &&
             post_promotion_run.include?(aggregate_check_marker) &&
             post_promotion_run.index(metadata_marker) < post_promotion_run.index(aggregate_marker) &&
             post_promotion_run.index(aggregate_marker) < post_promotion_run.index(aggregate_check_marker),
           "read-only post-promotion job must bind bounded exact-run metadata, aggregate job, and aggregate check without writes")
check.call(post_promotion_run.scan(/\.app\.id == \d+/) == [".app.id == 15368"] &&
             post_promotion_run.scan(/\.name == "Internal post-promotion CI"/).length == 2 &&
             post_promotion_run.scan(/\.check_suite\.id == \$suite_id/).length == 1 &&
             post_promotion_run.scan(/\.details_url == \$details/).length == 1,
           "post-promotion aggregate must bind its exact job/check name, Actions app, suite, and canonical job URL")
aggregate_link_marker = '[ "$(printf \'%s\' "$linked_aggregate_checks" | jq -r \'.[0].id\')" != "$aggregate_check_id" ]'
final_main_marker = 'final_main_sha=$(gh api --method GET'
final_internal_marker = 'final_internal_sha=$(gh api --method GET'
success_marker = 'echo "Verified internal post-promotion CI run $dispatch_run_id for $EXPECTED_SHA."'
ordered_final_markers = [aggregate_link_marker, final_main_marker, final_internal_marker, success_marker]
ordered_final_positions = ordered_final_markers.map { |marker| post_promotion_run.index(marker) }
check.call(ordered_final_positions.none?(&:nil?) &&
             ordered_final_positions.each_cons(2).all? { |left, right| left < right },
           "post-promotion verification must freshly recheck main and internal only after aggregate linkage and before success")

allowed_delivery_action = "actions/checkout@#{checkout_sha}"
[promotion_workflow, writer_workflow].each do |delivery_workflow|
  Array(delivery_workflow["jobs"]&.values).each do |job|
    next unless job.is_a?(Hash)
    check.call(!job.key?("uses"), "delivery jobs must not call reusable workflows")
    Array(job["steps"]).each do |step|
      next unless step.is_a?(Hash) && step.key?("uses")
      check.call(step["uses"] == allowed_delivery_action,
                 "delivery workflows may use only the reviewed pinned checkout action")
    end
  end
end
check.call(!promotion_source.include?("secrets.") && !writer_source.include?("secrets.") &&
             !promotion_source.match?(/\bPAT\b/i) && !writer_source.match?(/\bPAT\b/i) &&
             !writer_source.include?("github.event.inputs") && !writer_source.include?("${{ inputs."),
           "delivery workflows must not use secrets, PATs, manual writer input, or user SHA input")

if errors.empty?
  puts "CI workflow contract passed: #{path}"
  puts "Authorization workflow contract passed: #{promotion_path}"
  puts "Authorized writer workflow contract passed: #{writer_path}"
else
  errors.each { |message| warn "CI workflow check failed: #{message}" }
  exit 1
end
RUBY
