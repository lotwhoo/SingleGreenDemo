#!/bin/sh
set -eu

workflow_path=${1:-.github/workflows/ci.yml}
promotion_workflow_path=${2:-$(dirname -- "$workflow_path")/promote-internal.yml}

if [ ! -f "$workflow_path" ]; then
    echo "CI workflow check failed: file not found: $workflow_path" >&2
    exit 1
fi

if [ ! -f "$promotion_workflow_path" ]; then
    echo "CI workflow check failed: file not found: $promotion_workflow_path" >&2
    exit 1
fi

ruby - "$workflow_path" "$promotion_workflow_path" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
promotion_path = ARGV.fetch(1)
source = File.read(path)
promotion_source = File.read(promotion_path)

begin
  workflow = YAML.load(source)
  promotion_workflow = YAML.load(promotion_source)
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
check.call(workflow_directory == promotion_directory,
           "CI and promotion workflows must be validated from the same workflow directory")
check.call(File.basename(promotion_path) == "promote-internal.yml",
           "the reviewed write workflow must be named promote-internal.yml")

workflow_paths = Dir.glob(File.join(workflow_directory, "*.{yml,yaml}")).sort
check.call(workflow_paths.include?(File.expand_path(path)), "workflow inventory must include the CI workflow")
check.call(workflow_paths.include?(File.expand_path(promotion_path)), "workflow inventory must include promote-internal.yml")
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
    if grants_write?(candidate_job["permissions"])
      write_locations << [File.expand_path(candidate_path), "job:#{candidate_job_name}"]
    end
  end
end

expected_write_locations = [[File.expand_path(promotion_path), "job:promote"]]
check.call(write_locations == expected_write_locations,
           "only the promote job in promote-internal.yml may request any write permission")

triggers = workflow["on"] || workflow[true]
check.call(triggers.is_a?(Hash), "on must define an event mapping")
triggers = {} unless triggers.is_a?(Hash)

check.call(!triggers.key?("workflow_dispatch"), "workflow_dispatch and its inputs are not allowed")

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

branch_runs = branch_steps.map { |step| step.is_a?(Hash) ? step["run"] : nil }.compact.join("\n")

check.call(branch_runs.scan(%r{scripts/test_internal_branch_policy\.sh}).length == 1,
           "branch-contract must run test_internal_branch_policy.sh exactly once")
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
  check.call(required_ci["name"] == "Required CI", "required-ci display name must be stable: Required CI")
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
check.call(all_conditional_steps.length == 11 &&
             all_conditional_steps.map(&:object_id).sort == approved_conditional_step_ids.sort,
           "CI step conditions must match exactly the eleven reviewed conditional steps; every other step must be unconditional")

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
check.call(all_runs.scan(%r{scripts/test_internal_branch_policy\.sh}).length == 1,
           "branch-policy fixtures must not be duplicated across jobs")
check.call(all_runs.scan(%r{scripts/check_internal_branch_policy\.sh}).length == 1,
           "live branch-policy validation must appear exactly once")

promotion_triggers = promotion_workflow["on"] || promotion_workflow[true]
check.call(promotion_triggers.is_a?(Hash), "promotion on must define an event mapping")
promotion_triggers = {} unless promotion_triggers.is_a?(Hash)
check.call(promotion_triggers.keys == ["workflow_dispatch"],
           "promotion must be manual workflow_dispatch only")
dispatch_contract = promotion_triggers["workflow_dispatch"]
check.call(dispatch_contract.nil? || (dispatch_contract.is_a?(Hash) && dispatch_contract.empty?),
           "promotion workflow_dispatch must not accept inputs")
check.call(promotion_workflow["permissions"] == {},
           "promotion top-level permissions must be empty")
check.call(!declares_run_shell?(promotion_workflow),
           "promotion workflow must not override defaults.run.shell")

promotion_concurrency = promotion_workflow["concurrency"]
check.call(promotion_concurrency.is_a?(Hash), "promotion concurrency must be configured")
if promotion_concurrency.is_a?(Hash)
  check.call(promotion_concurrency["group"] == "promote-internal",
             "promotion concurrency group must be the stable promote-internal key")
  check.call(promotion_concurrency["cancel-in-progress"] == false,
             "promotion concurrency must not cancel an in-flight promotion")
end

promotion_jobs = promotion_workflow["jobs"]
check.call(promotion_jobs.is_a?(Hash), "promotion jobs must be a mapping")
promotion_jobs = {} unless promotion_jobs.is_a?(Hash)
check.call(promotion_jobs.keys.sort == %w[authorize promote],
           "promotion must contain exactly separate authorize and promote jobs")
authorize_job = promotion_jobs["authorize"]
promote_job = promotion_jobs["promote"]
check.call(authorize_job.is_a?(Hash), "promotion authorize job is required")
check.call(promote_job.is_a?(Hash), "promotion promote job is required")

if authorize_job.is_a?(Hash)
  check.call(!declares_run_shell?(authorize_job),
             "promotion authorize job must not override defaults.run.shell")
  check.call(fail_closed?(authorize_job),
             "promotion authorize job must fail closed and must not continue on error")
  check.call(!authorize_job.key?("if"), "promotion authorize job must be unconditional")
  check.call(authorize_job["name"] == "Internal promotion authorization",
             "authorize display name must be stable for the promotion ruleset")
  check.call(authorize_job["permissions"] == {"actions"=>"read", "checks"=>"read", "contents"=>"read"},
             "authorize permissions must be job-scoped actions/checks/contents read")
  check.call(authorize_job["outputs"] == {"approved_sha"=>"${{ steps.authorize.outputs.approved_sha }}"},
             "authorize must expose only its reviewed approved SHA")
end
if promote_job.is_a?(Hash)
  check.call(!declares_run_shell?(promote_job),
             "promotion promote job must not override defaults.run.shell")
  check.call(fail_closed?(promote_job),
             "promotion promote job must fail closed and must not continue on error")
  check.call(!promote_job.key?("if"), "promotion promote job must be unconditional")
  check.call(promote_job["permissions"] == {"contents"=>"write"},
             "promote must have only job-scoped contents write")
  check.call(Array(promote_job["needs"]) == ["authorize"],
             "promote must depend only on successful authorization")
end

promotion_steps = promotion_jobs.values.flat_map do |job|
  Array(job.is_a?(Hash) ? job["steps"] : []).select { |step| step.is_a?(Hash) }
end
promotion_checkouts = promotion_steps.map do |step|
  step["uses"] if step["uses"].to_s.start_with?("actions/checkout@")
end.compact
check.call(promotion_checkouts.length == 2 &&
             promotion_checkouts.all? { |uses| uses == "actions/checkout@#{checkout_sha}" },
           "both promotion checkouts must be pinned to the reviewed v7.0.1 commit SHA")
promotion_steps.each do |step|
  uses = step["uses"].to_s
  next if uses.empty?
  check.call(uses == "actions/checkout@#{checkout_sha}",
             "promotion may use only the reviewed pinned checkout action")
end

authorize_steps = authorize_job.is_a?(Hash) ? Array(authorize_job["steps"]) : []
promote_steps = promote_job.is_a?(Hash) ? Array(promote_job["steps"]) : []
[authorize_steps, promote_steps].flatten.each do |step|
  check.call(fail_closed?(step),
             "every promotion step must fail closed and must not continue on error")
  check.call(step.is_a?(Hash) && !step.key?("if"),
             "every promotion step must be unconditional")
  check.call(step.is_a?(Hash) && !step.key?("shell"),
             "promotion steps must not override their shell")
end
authorize_checkout = authorize_steps.find { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/checkout@") }
promote_checkout = promote_steps.find { |step| step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/checkout@") }
check.call(authorize_checkout.is_a?(Hash) &&
             authorize_checkout["with"].is_a?(Hash) &&
             authorize_checkout["with"]["ref"] == "refs/heads/main" &&
             authorize_checkout["with"]["fetch-depth"] == 0 &&
             authorize_checkout["with"]["persist-credentials"] == false,
           "authorize must deeply check out main without persisted credentials")
check.call(promote_checkout.is_a?(Hash) &&
             promote_checkout["with"].is_a?(Hash) &&
             promote_checkout["with"]["ref"] == "refs/heads/main" &&
             promote_checkout["with"]["fetch-depth"] == 0 &&
             promote_checkout["with"]["persist-credentials"] == true,
           "promote must deeply check out main with only the job-scoped GitHub token")

authorize_step = authorize_steps.find { |step| step.is_a?(Hash) && step["id"] == "authorize" }
check.call(authorize_steps.length == 2 &&
             authorize_steps[0] == authorize_checkout &&
             authorize_steps[1] == authorize_step,
           "authorize must contain exactly the pinned checkout followed by the reviewed authorization step")
check.call(authorize_step.is_a?(Hash) && authorize_step["name"] == "Authorize the exact current main commit",
           "authorize step name and topology must remain stable")
authorize_run = authorize_step.is_a?(Hash) ? authorize_step["run"].to_s : ""
authorize_env = authorize_step.is_a?(Hash) ? authorize_step["env"] : nil
check.call(authorize_env == {"GH_TOKEN"=>"${{ github.token }}"},
           "authorize API access must use only github.token")
check.call(authorize_run.include?('[ "$GITHUB_REF" != "refs/heads/main" ]'),
           "authorize must reject dispatches not sourced from refs/heads/main")
check.call(authorize_run.include?("git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'") &&
             authorize_run.include?('event_sha="$GITHUB_SHA"') &&
             authorize_run.include?("main_sha=$(git rev-parse 'refs/remotes/origin/main^{commit}')") &&
             authorize_run.include?('[ "$event_sha" != "$main_sha" ]') &&
             authorize_run.include?('[ "$checkout_sha" != "$main_sha" ]'),
           "authorize must freshly resolve origin/main and match event and checkout SHAs")
check.call(authorize_run.include?('scripts/check_internal_branch_policy.sh "$main_sha" "$main_sha" "$main_sha"'),
           "authorize must precheck the current main SHA in all three checker positions")
check.call(authorize_run.include?('/actions/workflows/ci.yml/runs?branch=main&event=push&status=completed&head_sha=$main_sha&per_page=100') &&
             authorize_run.include?('.head_sha == $sha') &&
             authorize_run.include?('.head_branch == "main"') &&
             authorize_run.include?('.event == "push"') &&
             authorize_run.include?('.conclusion == "success"') &&
             authorize_run.include?('.path == ".github/workflows/ci.yml"') &&
             authorize_run.include?('sort_by(.updated_at, .run_attempt, .id)') &&
             authorize_run.include?("workflow_run_id=$(printf '%s' \"$successful_workflow_runs\" | jq -r '.[-1].id')"),
           "authorize must select the latest exact successful current-main push CI run")
check.call(authorize_run.include?('/commits/$main_sha/check-runs?check_name=Required%20CI&filter=latest&per_page=100') &&
             authorize_run.include?('.name == "Required CI"') &&
             authorize_run.include?('.app.id == 15368') &&
             authorize_run.include?('.head_sha == $sha') &&
             authorize_run.include?('(.details_url | contains($run_fragment))') &&
             authorize_run.include?('sort_by(.completed_at, .id)') &&
             authorize_run.include?("trusted_check_id=$(printf '%s' \"$trusted_checks\" | jq -r '.[-1].id')"),
           "authorize must select the latest Required CI check bound to the exact SHA, trusted Actions app, and push run")
check.call(authorize_run.scan(/-lt 1/).length == 2 && !authorize_run.include?("-ne 1"),
           "authorize must reject zero trusted results without rejecting safe reruns")
check.call(authorize_run.include?('echo "approved_sha=$main_sha" >> "$GITHUB_OUTPUT"'),
           "authorize must emit only the freshly authorized main SHA")
check.call(!authorize_run.match?(%r{(?:^|\n)\s*git\s+push\b}),
           "authorize must not mutate repository refs")

promote_step = promote_steps.find do |step|
  step.is_a?(Hash) && step["run"].to_s.match?(%r{(?:^|\n)\s*git\s+push\b})
end
check.call(promote_steps.length == 2 &&
             promote_steps[0] == promote_checkout &&
             promote_steps[1] == promote_step,
           "promote must contain exactly the pinned checkout followed by the reviewed mutation step")
check.call(promote_step.is_a?(Hash) && promote_step["name"] == "Fast-forward the internal delivery pointer",
           "promote mutation step name and topology must remain stable")
promote_run = promote_step.is_a?(Hash) ? promote_step["run"].to_s : ""
promote_env = promote_step.is_a?(Hash) ? promote_step["env"] : nil
check.call(promote_env == {"APPROVED_SHA"=>"${{ needs.authorize.outputs.approved_sha }}"},
           "promote must consume only the authorize job approved SHA")
check.call(promote_run.include?('[ "$GITHUB_REF" != "refs/heads/main" ]'),
           "promote must independently gate refs/heads/main")
check.call(promote_run.include?("git fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main'") &&
             promote_run.include?('event_sha="$GITHUB_SHA"') &&
             promote_run.include?('[ "$APPROVED_SHA" != "$main_sha" ]') &&
             promote_run.include?('[ "$event_sha" != "$main_sha" ]') &&
             promote_run.include?('[ "$checkout_sha" != "$main_sha" ]'),
           "promote must reject stale authorization and non-current main SHAs")
check.call(promote_run.scan(%r{scripts/check_internal_branch_policy\.sh}).length == 2,
           "promote must run exactly one pre-push and one post-push three-SHA check")
precheck = 'scripts/check_internal_branch_policy.sh "$APPROVED_SHA" "$main_sha" "$checkout_sha"'
push = 'git push origin "$main_sha:refs/heads/codex/internal-debug"'
postcheck = 'scripts/check_internal_branch_policy.sh "$APPROVED_SHA" "$post_main_sha" "$internal_sha"'
check.call(promote_run.include?(precheck) && promote_run.include?(push) && promote_run.include?(postcheck) &&
             promote_run.index(precheck) < promote_run.index(push) &&
             promote_run.index(push) < promote_run.index(postcheck),
           "promote must order the reviewed precheck, exact pointer push, and postcheck")
check.call(promote_run.include?('git merge-base --is-ancestor "$previous_internal_sha" "$main_sha"') &&
             promote_run.index('git merge-base --is-ancestor') < promote_run.index(push),
           "promote must prove an existing internal pointer can fast-forward before push")
push_lines = promote_run.lines.select { |line| line.match?(%r{^\s*git\s+push\b}) }
check.call(push_lines == ["          #{push}\n"] || push_lines.map(&:strip) == [push],
           "promotion must contain exactly one reviewed pointer push")
check.call(push_lines.none? { |line| line.match?(%r{(?:^|\s)(?:--force(?:-with-lease)?|-f)(?:\s|$)}) || line.include?("+:refs/") },
           "promotion must never force-push")
check.call(promote_run.include?("'+refs/heads/codex/internal-debug:refs/remotes/origin/codex/internal-debug'") &&
             promote_run.include?("post_main_sha=$(git rev-parse 'refs/remotes/origin/main^{commit}')") &&
             promote_run.include?("internal_sha=$(git rev-parse 'refs/remotes/origin/codex/internal-debug^{commit}')"),
           "promote must freshly fetch and verify both refs after mutation")

check.call(!promotion_source.include?("secrets.") &&
             !promotion_source.match?(/\bPAT\b/i) &&
             !promotion_source.include?("github.event.inputs") &&
             !promotion_source.include?("${{ inputs."),
           "promotion must not accept user SHAs, PATs, or repository secrets")

if errors.empty?
  puts "CI workflow contract passed: #{path}"
  puts "Promotion workflow contract passed: #{promotion_path}"
else
  errors.each { |message| warn "CI workflow check failed: #{message}" }
  exit 1
end
RUBY
