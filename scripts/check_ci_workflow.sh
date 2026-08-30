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

expected_write_locations = [[File.expand_path(writer_path), "job:promote"]]
check.call(write_locations == expected_write_locations,
           "only the promote job in promote-authorized-internal.yml may request any write permission")

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

if false
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
end

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
check.call(authorization_job["permissions"] == {"actions"=>"read", "checks"=>"read", "contents"=>"read"},
           "authorization job must be read-only")
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
  'latest_required_check_id'
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

writer_jobs = writer_workflow["jobs"]
writer_jobs = {} unless writer_jobs.is_a?(Hash)
check.call(writer_jobs.keys.sort == %w[promote verify],
           "writer must contain exactly verify and promote jobs")
check.call(writer_jobs.values.none? { |job| job.is_a?(Hash) && job["name"] == "Internal promotion authorization" },
           "writer must not emit the authorization ruleset check name")
verify_job = writer_jobs["verify"]
promote_job = writer_jobs["promote"]
verify_job = {} unless verify_job.is_a?(Hash)
promote_job = {} unless promote_job.is_a?(Hash)
check.call(verify_job["permissions"] == {"actions"=>"read", "checks"=>"read", "contents"=>"read"},
           "writer verify job must be read-only")
check.call(promote_job["permissions"] == {"actions"=>"read", "checks"=>"read", "contents"=>"write"},
           "writer promote job must have only the reviewed read/read/write permissions")
check.call(Array(promote_job["needs"]) == ["verify"],
           "writer promote job must depend on read-only verification")
[verify_job, promote_job].each do |job|
  check.call(job["runs-on"] == "ubuntu-latest" && !job.key?("if") && fail_closed?(job) && !declares_run_shell?(job),
             "writer jobs must be unconditional ubuntu-latest default-shell fail-closed jobs")
end

verify_steps = Array(verify_job["steps"])
promote_steps = Array(promote_job["steps"])
check.call(verify_steps.length == 1 && promote_steps.length == 3,
           "writer topology must be one verification step then exactly three promote steps")
(verify_steps + promote_steps).each do |step|
  check.call(step.is_a?(Hash) && !step.key?("if") && !step.key?("shell") && fail_closed?(step),
             "writer steps must be unconditional, default-shell, and fail closed")
end
verify_step = verify_steps[0].is_a?(Hash) ? verify_steps[0] : {}
trust_step = promote_steps[0].is_a?(Hash) ? promote_steps[0] : {}
writer_checkout = promote_steps[1].is_a?(Hash) ? promote_steps[1] : {}
mutation_step = promote_steps[2].is_a?(Hash) ? promote_steps[2] : {}
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
             mutation_step["env"] == {"VALIDATED_SHA"=>"${{ steps.trust.outputs.validated_sha }}"},
           "writer mutation step must consume only the validated SHA")

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
