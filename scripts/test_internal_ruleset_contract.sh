#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
checker="$script_dir/check_internal_ruleset_contract.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-internal-ruleset.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

stdout_file="$fixture_root/check.stdout"
stderr_file="$fixture_root/check.stderr"
steady_fixture="$fixture_root/steady.json"
bootstrap_fixture="$fixture_root/bootstrap.json"
api_metadata_fixture="$fixture_root/steady-with-api-metadata.json"
pass_count=0

if [ ! -x "$checker" ]; then
    echo "Internal ruleset contract tests failed: checker is not executable: $checker" >&2
    exit 1
fi

ruby -rjson - "$steady_fixture" "$bootstrap_fixture" "$api_metadata_fixture" <<'RUBY'
steady_path, bootstrap_path, api_metadata_path = ARGV

def ruleset(checks)
  {
    "id" => 21_848_414,
    "name" => "Internal delivery pointer integrity",
    "source_type" => "Repository",
    "source" => "lotwhoo/SingleGreenDemo",
    "target" => "branch",
    "enforcement" => "active",
    "bypass_actors" => [],
    "conditions" => {
      "ref_name" => {
        "exclude" => [],
        "include" => ["refs/heads/codex/internal-debug"]
      }
    },
    "rules" => [
      { "type" => "deletion" },
      { "type" => "non_fast_forward" },
      { "type" => "required_linear_history" },
      {
        "type" => "required_status_checks",
        "parameters" => {
          "do_not_enforce_on_create" => false,
          "required_status_checks" => checks,
          "strict_required_status_checks_policy" => false
        }
      }
    ]
  }
end

required_ci = { "context" => "Required CI", "integration_id" => 15_368 }
authorization = { "context" => "Internal promotion authorization", "integration_id" => 15_368 }
steady = ruleset([required_ci, authorization])
steady_with_api_metadata = steady.merge(
  "node_id" => "RRS_lACqUmVwb3NpdG9yec5QXuhvzgFNYV4",
  "created_at" => "2026-08-30T16:23:11.991+08:00",
  "updated_at" => "2026-08-30T18:22:53.657+08:00",
  "current_user_can_bypass" => "never",
  "_links" => {
    "html" => { "href" => "https://github.com/lotwhoo/SingleGreenDemo/rules/21848414" },
    "self" => { "href" => "https://api.github.com/repos/lotwhoo/SingleGreenDemo/rulesets/21848414" }
  }
)
File.write(steady_path, JSON.pretty_generate(steady))
File.write(bootstrap_path, JSON.pretty_generate(ruleset([required_ci])))
File.write(api_metadata_path, JSON.pretty_generate(steady_with_api_metadata))
RUBY

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

make_mutation() {
    mutation=$1
    source_path=${2:-$steady_fixture}
    destination_path="$fixture_root/$mutation.json"

    ruby -rjson - "$source_path" "$destination_path" "$mutation" <<'RUBY'
source_path, destination_path, mutation = ARGV
ruleset = JSON.parse(File.read(source_path))
status_rule = lambda do
  ruleset.fetch("rules").find { |rule| rule["type"] == "required_status_checks" }
end

case mutation
when "missing-id"
  ruleset.delete("id")
when "wrong-id"
  ruleset["id"] = 1
when "missing-name"
  ruleset.delete("name")
when "wrong-name"
  ruleset["name"] = "Unreviewed ruleset"
when "missing-source-type"
  ruleset.delete("source_type")
when "wrong-source-type"
  ruleset["source_type"] = "Organization"
when "missing-source"
  ruleset.delete("source")
when "wrong-source"
  ruleset["source"] = "attacker/fork"
when "missing-enforcement"
  ruleset.delete("enforcement")
when "passive-enforcement"
  ruleset["enforcement"] = "evaluate"
when "missing-bypass-actors"
  ruleset.delete("bypass_actors")
when "nonempty-bypass-actors"
  ruleset["bypass_actors"] = [{ "actor_id" => 1, "actor_type" => "RepositoryRole", "bypass_mode" => "always" }]
when "missing-target"
  ruleset.delete("target")
when "wrong-target"
  ruleset["target"] = "tag"
when "missing-conditions"
  ruleset.delete("conditions")
when "missing-ref-name"
  ruleset["conditions"].delete("ref_name")
when "extra-condition"
  ruleset["conditions"]["repository_name"] = { "exclude" => [], "include" => ["SingleGreenDemo"] }
when "missing-include"
  ruleset["conditions"]["ref_name"].delete("include")
when "wrong-include"
  ruleset["conditions"]["ref_name"]["include"] = ["refs/heads/main"]
when "extra-include"
  ruleset["conditions"]["ref_name"]["include"] << "refs/heads/main"
when "missing-exclude"
  ruleset["conditions"]["ref_name"].delete("exclude")
when "nonempty-exclude"
  ruleset["conditions"]["ref_name"]["exclude"] = ["refs/heads/escape"]
when "missing-rules"
  ruleset.delete("rules")
when "rules-not-array"
  ruleset["rules"] = {}
when "missing-deletion"
  ruleset["rules"].reject! { |rule| rule["type"] == "deletion" }
when "missing-non-fast-forward"
  ruleset["rules"].reject! { |rule| rule["type"] == "non_fast_forward" }
when "missing-linear-history"
  ruleset["rules"].reject! { |rule| rule["type"] == "required_linear_history" }
when "missing-status-rule"
  ruleset["rules"].reject! { |rule| rule["type"] == "required_status_checks" }
when "duplicate-rule"
  ruleset["rules"][-1] = { "type" => "deletion" }
when "extra-rule"
  ruleset["rules"] << { "type" => "creation" }
when "missing-rule-type"
  ruleset["rules"].first.delete("type")
when "non-object-rule"
  ruleset["rules"][0] = "deletion"
when "simple-rule-parameters"
  ruleset["rules"].find { |rule| rule["type"] == "deletion" }["parameters"] = {}
when "missing-status-parameters"
  status_rule.call.delete("parameters")
when "missing-strict-policy"
  status_rule.call["parameters"].delete("strict_required_status_checks_policy")
when "strict-policy-true"
  status_rule.call["parameters"]["strict_required_status_checks_policy"] = true
when "missing-create-policy"
  status_rule.call["parameters"].delete("do_not_enforce_on_create")
when "create-policy-true"
  status_rule.call["parameters"]["do_not_enforce_on_create"] = true
when "missing-required-checks"
  status_rule.call["parameters"].delete("required_status_checks")
when "extra-status-parameter"
  status_rule.call["parameters"]["unexpected"] = false
when "checks-not-array"
  status_rule.call["parameters"]["required_status_checks"] = {}
when "missing-required-ci"
  status_rule.call["parameters"]["required_status_checks"].reject! { |check| check["context"] == "Required CI" }
when "missing-authorization"
  status_rule.call["parameters"]["required_status_checks"].reject! { |check| check["context"] == "Internal promotion authorization" }
when "extra-check"
  status_rule.call["parameters"]["required_status_checks"] << { "context" => "Unreviewed", "integration_id" => 15_368 }
when "duplicate-check"
  status_rule.call["parameters"]["required_status_checks"][-1] = { "context" => "Required CI", "integration_id" => 15_368 }
when "wrong-required-ci-app"
  status_rule.call["parameters"]["required_status_checks"].find { |check| check["context"] == "Required CI" }["integration_id"] = 99_999
when "wrong-authorization-app"
  status_rule.call["parameters"]["required_status_checks"].find { |check| check["context"] == "Internal promotion authorization" }["integration_id"] = 99_999
when "missing-check-context"
  status_rule.call["parameters"]["required_status_checks"].first.delete("context")
when "missing-check-app"
  status_rule.call["parameters"]["required_status_checks"].first.delete("integration_id")
when "extra-check-field"
  status_rule.call["parameters"]["required_status_checks"].first["unexpected"] = true
when "non-object-check"
  status_rule.call["parameters"]["required_status_checks"][0] = "Required CI"
when "bootstrap-extra-authorization"
  status_rule.call["parameters"]["required_status_checks"] << {
    "context" => "Internal promotion authorization",
    "integration_id" => 15_368
  }
when "bootstrap-no-checks"
  status_rule.call["parameters"]["required_status_checks"] = []
when "reverse-check-order"
  status_rule.call["parameters"]["required_status_checks"].reverse!
else
  abort "unknown mutation: #{mutation}"
end

File.write(destination_path, JSON.pretty_generate(ruleset))
RUBY

    printf '%s\n' "$destination_path"
}

expect_mutation_failure() {
    mutation=$1
    expected_reason=$2
    mode=${3:-steady}
    source_path=${4:-$steady_fixture}
    mutation_path=$(make_mutation "$mutation" "$source_path")
    expect_failure "$mutation" "$expected_reason" "$checker" "$mode" "$mutation_path"
}

usage_message="usage: $checker {steady|bootstrap} RULESET_JSON"
expect_failure "missing arguments" "$usage_message" "$checker"
expect_failure "extra argument" "$usage_message" "$checker" steady "$steady_fixture" unexpected
expect_failure "unknown mode" "Internal ruleset contract check failed: mode must be steady or bootstrap" "$checker" unexpected "$steady_fixture"
expect_failure "missing file" "Internal ruleset contract check failed: file not found: $fixture_root/missing.json" "$checker" steady "$fixture_root/missing.json"

printf '%s\n' '{invalid' >"$fixture_root/invalid.json"
set +e
"$checker" steady "$fixture_root/invalid.json" >"$stdout_file" 2>"$stderr_file"
invalid_status=$?
set -e
invalid_reason=$(sed -n '1p' "$stderr_file")
invalid_extra=$(sed -n '2p' "$stderr_file")
invalid_reason_matches=true
case "$invalid_reason" in
    "Internal ruleset contract check failed: invalid JSON: "*) ;;
    *) invalid_reason_matches=false ;;
esac
if [ "$invalid_status" -eq 0 ] || [ "${invalid_reason_matches:-true}" = false ] || [ -n "$invalid_extra" ]; then
    echo "FAIL: malformed JSON was not rejected deterministically" >&2
    cat "$stderr_file" >&2
    exit 1
fi
pass_count=$((pass_count + 1))

printf '%s\n' '[]' >"$fixture_root/array.json"
expect_failure "non-object root" "Internal ruleset contract check failed: ruleset root must be an object" "$checker" steady "$fixture_root/array.json"

expect_pass "reviewed steady contract" "$checker" steady "$steady_fixture"
expect_pass "reviewed bootstrap contract" "$checker" bootstrap "$bootstrap_fixture"
expect_pass "reviewed steady contract with GitHub API metadata" "$checker" steady "$api_metadata_fixture"
reverse_path=$(make_mutation reverse-check-order)
expect_pass "required checks may use either JSON array order" "$checker" steady "$reverse_path"

expect_mutation_failure missing-id "Internal ruleset contract check failed: id must be 21848414"
expect_mutation_failure wrong-id "Internal ruleset contract check failed: id must be 21848414"
expect_mutation_failure missing-name "Internal ruleset contract check failed: name must be Internal delivery pointer integrity"
expect_mutation_failure wrong-name "Internal ruleset contract check failed: name must be Internal delivery pointer integrity"
expect_mutation_failure missing-source-type "Internal ruleset contract check failed: source_type must be Repository"
expect_mutation_failure wrong-source-type "Internal ruleset contract check failed: source_type must be Repository"
expect_mutation_failure missing-source "Internal ruleset contract check failed: source must be lotwhoo/SingleGreenDemo"
expect_mutation_failure wrong-source "Internal ruleset contract check failed: source must be lotwhoo/SingleGreenDemo"
expect_mutation_failure missing-enforcement "Internal ruleset contract check failed: enforcement must be active"
expect_mutation_failure passive-enforcement "Internal ruleset contract check failed: enforcement must be active"
expect_mutation_failure missing-bypass-actors "Internal ruleset contract check failed: bypass_actors must be an empty array"
expect_mutation_failure nonempty-bypass-actors "Internal ruleset contract check failed: bypass_actors must be an empty array"
expect_mutation_failure missing-target "Internal ruleset contract check failed: target must be branch"
expect_mutation_failure wrong-target "Internal ruleset contract check failed: target must be branch"
expect_mutation_failure missing-conditions "Internal ruleset contract check failed: conditions must be present"
expect_mutation_failure missing-ref-name "Internal ruleset contract check failed: conditions keys must be exactly ref_name"
expect_mutation_failure extra-condition "Internal ruleset contract check failed: conditions keys must be exactly ref_name"
expect_mutation_failure missing-include "Internal ruleset contract check failed: conditions.ref_name keys must be exactly exclude, include"
expect_mutation_failure wrong-include "Internal ruleset contract check failed: conditions.ref_name.include must target only refs/heads/codex/internal-debug"
expect_mutation_failure extra-include "Internal ruleset contract check failed: conditions.ref_name.include must target only refs/heads/codex/internal-debug"
expect_mutation_failure missing-exclude "Internal ruleset contract check failed: conditions.ref_name keys must be exactly exclude, include"
expect_mutation_failure nonempty-exclude "Internal ruleset contract check failed: conditions.ref_name.exclude must be an empty array"
expect_mutation_failure missing-rules "Internal ruleset contract check failed: rules must be present"
expect_mutation_failure rules-not-array "Internal ruleset contract check failed: rules must be an array"
expect_mutation_failure missing-deletion "Internal ruleset contract check failed: rules must contain exactly four reviewed rule objects"
expect_mutation_failure missing-non-fast-forward "Internal ruleset contract check failed: rules must contain exactly four reviewed rule objects"
expect_mutation_failure missing-linear-history "Internal ruleset contract check failed: rules must contain exactly four reviewed rule objects"
expect_mutation_failure missing-status-rule "Internal ruleset contract check failed: rules must contain exactly four reviewed rule objects"
expect_mutation_failure duplicate-rule "Internal ruleset contract check failed: rule types must be exactly deletion, non_fast_forward, required_linear_history, required_status_checks"
expect_mutation_failure extra-rule "Internal ruleset contract check failed: rules must contain exactly four reviewed rule objects"
expect_mutation_failure missing-rule-type "Internal ruleset contract check failed: rule types must be exactly deletion, non_fast_forward, required_linear_history, required_status_checks"
expect_mutation_failure non-object-rule "Internal ruleset contract check failed: rules must contain exactly four reviewed rule objects"
expect_mutation_failure simple-rule-parameters "Internal ruleset contract check failed: deletion rule keys must be exactly type"
expect_mutation_failure missing-status-parameters "Internal ruleset contract check failed: required_status_checks rule keys must be exactly parameters, type"
expect_mutation_failure missing-strict-policy "Internal ruleset contract check failed: required_status_checks.parameters keys must be exactly do_not_enforce_on_create, required_status_checks, strict_required_status_checks_policy"
expect_mutation_failure strict-policy-true "Internal ruleset contract check failed: strict_required_status_checks_policy must be false"
expect_mutation_failure missing-create-policy "Internal ruleset contract check failed: required_status_checks.parameters keys must be exactly do_not_enforce_on_create, required_status_checks, strict_required_status_checks_policy"
expect_mutation_failure create-policy-true "Internal ruleset contract check failed: do_not_enforce_on_create must be false"
expect_mutation_failure missing-required-checks "Internal ruleset contract check failed: required_status_checks.parameters keys must be exactly do_not_enforce_on_create, required_status_checks, strict_required_status_checks_policy"
expect_mutation_failure extra-status-parameter "Internal ruleset contract check failed: required_status_checks.parameters keys must be exactly do_not_enforce_on_create, required_status_checks, strict_required_status_checks_policy"
expect_mutation_failure checks-not-array "Internal ruleset contract check failed: required_status_checks must be an array"
expect_mutation_failure missing-required-ci "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed steady checks for app 15368"
expect_mutation_failure missing-authorization "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed steady checks for app 15368"
expect_mutation_failure extra-check "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed steady checks for app 15368"
expect_mutation_failure duplicate-check "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed steady checks for app 15368"
expect_mutation_failure wrong-required-ci-app "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed steady checks for app 15368"
expect_mutation_failure wrong-authorization-app "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed steady checks for app 15368"
expect_mutation_failure missing-check-context "Internal ruleset contract check failed: required_status_checks[0] keys must be exactly context, integration_id"
expect_mutation_failure missing-check-app "Internal ruleset contract check failed: required_status_checks[0] keys must be exactly context, integration_id"
expect_mutation_failure extra-check-field "Internal ruleset contract check failed: required_status_checks[0] keys must be exactly context, integration_id"
expect_mutation_failure non-object-check "Internal ruleset contract check failed: required_status_checks[0] must be an object"
expect_mutation_failure bootstrap-extra-authorization "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed bootstrap checks for app 15368" bootstrap "$bootstrap_fixture"
expect_mutation_failure bootstrap-no-checks "Internal ruleset contract check failed: required_status_checks must be exactly the reviewed bootstrap checks for app 15368" bootstrap "$bootstrap_fixture"

echo "Internal ruleset contract tests passed: $pass_count cases."
