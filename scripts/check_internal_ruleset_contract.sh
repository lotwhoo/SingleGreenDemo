#!/bin/sh

set -eu

usage() {
    echo "usage: $0 {steady|bootstrap} RULESET_JSON" >&2
    exit 2
}

if [ "$#" -ne 2 ]; then
    usage
fi

mode=$1
ruleset_path=$2

case "$mode" in
    steady|bootstrap) ;;
    *)
        echo "Internal ruleset contract check failed: mode must be steady or bootstrap" >&2
        exit 2
        ;;
esac

if [ ! -f "$ruleset_path" ]; then
    echo "Internal ruleset contract check failed: file not found: $ruleset_path" >&2
    exit 1
fi

ruby -rjson - "$mode" "$ruleset_path" <<'RUBY'
mode = ARGV.fetch(0)
path = ARGV.fetch(1)

class ContractFailure < StandardError
end

def reject(reason)
  raise ContractFailure, reason
end

def require_exact_keys(value, expected, location)
  reject("#{location} must be an object") unless value.is_a?(Hash)

  actual = value.keys.sort
  wanted = expected.sort
  reject("#{location} keys must be exactly #{wanted.join(', ')}") unless actual == wanted
end

begin
  ruleset = JSON.parse(File.read(path))
rescue Errno::ENOENT
  warn "Internal ruleset contract check failed: file not found: #{path}"
  exit 1
rescue Errno::EACCES
  warn "Internal ruleset contract check failed: file is not readable: #{path}"
  exit 1
rescue JSON::ParserError => error
  warn "Internal ruleset contract check failed: invalid JSON: #{error.message.lines.first.to_s.strip}"
  exit 1
end

begin
  reject("ruleset root must be an object") unless ruleset.is_a?(Hash)

  reject("id must be 21848414") unless ruleset.key?("id") && ruleset["id"] == 21_848_414
  reject("name must be Internal delivery pointer integrity") unless
    ruleset.key?("name") && ruleset["name"] == "Internal delivery pointer integrity"
  reject("source_type must be Repository") unless
    ruleset.key?("source_type") && ruleset["source_type"] == "Repository"
  reject("source must be lotwhoo/SingleGreenDemo") unless
    ruleset.key?("source") && ruleset["source"] == "lotwhoo/SingleGreenDemo"
  reject("enforcement must be active") unless ruleset.key?("enforcement") && ruleset["enforcement"] == "active"
  reject("bypass_actors must be an empty array") unless ruleset.key?("bypass_actors") && ruleset["bypass_actors"] == []
  reject("target must be branch") unless ruleset.key?("target") && ruleset["target"] == "branch"

  reject("conditions must be present") unless ruleset.key?("conditions")
  conditions = ruleset["conditions"]
  require_exact_keys(conditions, ["ref_name"], "conditions")

  ref_name = conditions["ref_name"]
  require_exact_keys(ref_name, %w[exclude include], "conditions.ref_name")
  reject("conditions.ref_name.include must target only refs/heads/codex/internal-debug") unless
    ref_name["include"] == ["refs/heads/codex/internal-debug"]
  reject("conditions.ref_name.exclude must be an empty array") unless ref_name["exclude"] == []

  reject("rules must be present") unless ruleset.key?("rules")
  rules = ruleset["rules"]
  reject("rules must be an array") unless rules.is_a?(Array)
  reject("rules must contain exactly four reviewed rule objects") unless rules.length == 4 && rules.all? { |rule| rule.is_a?(Hash) }

  expected_types = %w[deletion non_fast_forward required_linear_history required_status_checks]
  actual_types = rules.map { |rule| rule["type"] }
  reject("rule types must be exactly #{expected_types.join(', ')}") unless
    actual_types.sort_by { |type| type.to_s } == expected_types.sort

  simple_types = %w[deletion non_fast_forward required_linear_history]
  simple_types.each do |type|
    rule = rules.find { |candidate| candidate["type"] == type }
    require_exact_keys(rule, ["type"], "#{type} rule")
  end

  status_rule = rules.find { |candidate| candidate["type"] == "required_status_checks" }
  require_exact_keys(status_rule, %w[parameters type], "required_status_checks rule")

  parameters = status_rule["parameters"]
  require_exact_keys(
    parameters,
    %w[do_not_enforce_on_create required_status_checks strict_required_status_checks_policy],
    "required_status_checks.parameters"
  )
  reject("strict_required_status_checks_policy must be false") unless
    parameters["strict_required_status_checks_policy"] == false
  reject("do_not_enforce_on_create must be false") unless
    parameters["do_not_enforce_on_create"] == false

  checks = parameters["required_status_checks"]
  reject("required_status_checks must be an array") unless checks.is_a?(Array)
  checks.each_with_index do |check, index|
    require_exact_keys(check, %w[context integration_id], "required_status_checks[#{index}]")
  end

  expected_checks = [["Required CI", 15_368]]
  expected_checks << ["Internal promotion authorization", 15_368] if mode == "steady"
  actual_checks = checks.map { |check| [check["context"], check["integration_id"]] }
  reject("required_status_checks must be exactly the reviewed #{mode} checks for app 15368") unless
    actual_checks.sort_by { |context, integration_id| [context.to_s, integration_id.to_s] } ==
      expected_checks.sort_by { |context, integration_id| [context, integration_id.to_s] }
rescue ContractFailure => error
  warn "Internal ruleset contract check failed: #{error.message}"
  exit 1
end

puts "Internal ruleset contract check passed: #{mode} mode."
RUBY
