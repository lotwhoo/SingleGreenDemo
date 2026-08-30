#!/bin/sh
set -eu

workflow_path=${1:-.github/workflows/ci.yml}

if [ ! -f "$workflow_path" ]; then
    echo "CI workflow check failed: file not found: $workflow_path" >&2
    exit 1
fi

ruby - "$workflow_path" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
source = File.read(path)

begin
  workflow = YAML.load(source)
rescue Psych::SyntaxError => error
  warn "CI workflow check failed: YAML parse error: #{error.message}"
  exit 1
end

unless workflow.is_a?(Hash)
  warn "CI workflow check failed: workflow root must be a mapping"
  exit 1
end

errors = []
check = lambda do |condition, message|
  errors << message unless condition
end

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

concurrency = workflow["concurrency"]
check.call(concurrency.is_a?(Hash), "concurrency must be configured")
if concurrency.is_a?(Hash)
  check.call(concurrency["cancel-in-progress"] == true, "concurrency.cancel-in-progress must be true")
  check.call(concurrency["group"].to_s.include?("github.ref"), "concurrency group must be ref-scoped")
end

jobs = workflow["jobs"]
check.call(jobs.is_a?(Hash), "jobs must be a mapping")
jobs = {} unless jobs.is_a?(Hash)

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

if errors.empty?
  puts "CI workflow contract passed: #{path}"
else
  errors.each { |message| warn "CI workflow check failed: #{message}" }
  exit 1
end
RUBY
