#!/bin/sh

set -eu
export PYTHONDONTWRITEBYTECODE=1

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)

python3 - "$script_directory/plan_ci_impact.py" "$repository_root/config/architecture-boundaries.json" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PLANNER_PATH = Path(sys.argv[1]).resolve()
CONFIG_PATH = Path(sys.argv[2]).resolve()
spec = importlib.util.spec_from_file_location("ci_impact_planner", PLANNER_PATH)
planner_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = planner_module
spec.loader.exec_module(planner_module)


class RepositoryFixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ci-impact-")
        self.root = Path(self.temporary.name)
        self.commit_index = 0
        self.git("init", "-q")
        self.git("config", "user.name", "CI Planner Tests")
        self.git("config", "user.email", "ci-planner@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        destination = self.root / "config/architecture-boundaries.json"
        destination.parent.mkdir(parents=True)
        shutil.copyfile(CONFIG_PATH, destination)
        self.write("README.md", "fixture\n")
        self.base = self.commit("base")
        self.default_branch = self.text("symbolic-ref", "--short", "HEAD")

    def close(self):
        self.temporary.cleanup()

    def git(self, *arguments, check=True, env=None):
        result = subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=env,
        )
        if check and result.returncode != 0:
            raise AssertionError(
                f"git {' '.join(arguments)} failed: "
                + result.stderr.decode("utf-8", errors="replace")
            )
        return result

    def text(self, *arguments):
        return self.git(*arguments).stdout.decode("ascii").strip()

    def write(self, relative, content="change\n"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, message, allow_empty=False):
        self.git("add", "-A")
        self.commit_index += 1
        timestamp = f"2001-01-{self.commit_index:02d}T00:00:00+0000"
        env = dict(os.environ, GIT_AUTHOR_DATE=timestamp, GIT_COMMITTER_DATE=timestamp)
        arguments = ["commit", "-q", "-m", message]
        if allow_empty:
            arguments.insert(1, "--allow-empty")
        self.git(*arguments, env=env)
        return self.text("rev-parse", "HEAD")

    def prepare_pr(self, change=None, initial=None, base_change=None, empty_feature=False):
        if initial:
            for path, content in initial.items():
                self.write(path, content)
            self.base = self.commit("fixture initial content")
        self.git("checkout", "-q", "-b", "feature")
        if change:
            change(self)
        self.head = self.commit("feature", allow_empty=empty_feature)
        self.git("checkout", "-q", self.default_branch)
        if base_change:
            base_change(self)
            self.base = self.commit("base advanced")
        self.commit_index += 1
        timestamp = f"2001-02-{self.commit_index:02d}T00:00:00+0000"
        env = dict(os.environ, GIT_AUTHOR_DATE=timestamp, GIT_COMMITTER_DATE=timestamp)
        self.git("merge", "-q", "--no-ff", "--no-edit", "feature", env=env)
        self.checkout = self.text("rev-parse", "HEAD")
        return self.base, self.head, self.checkout


class ImpactPlannerTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.fixture = RepositoryFixture()

    def tearDown(self):
        self.fixture.close()

    def invoke(self, mode="pull-request", base=None, head=None, checkout=None, extra=()):
        output = self.fixture.root / "plan.json"
        github_output = self.fixture.root / "github-output.txt"
        arguments = [
            sys.executable,
            str(PLANNER_PATH),
            "--mode",
            mode,
            "--repository-root",
            str(self.fixture.root),
            "--json-output",
            str(output),
            "--github-output",
            str(github_output),
        ]
        if base is not None:
            arguments += ["--base-sha", base]
        if head is not None:
            arguments += ["--head-sha", head]
        if checkout is not None:
            arguments += ["--checkout-sha", checkout]
        arguments += list(extra)
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        plan = json.loads(output.read_text()) if output.exists() else None
        parsed_outputs = {}
        if github_output.exists():
            for line in github_output.read_text().splitlines():
                key, value = line.split("=", 1)
                parsed_outputs[key] = value
        return result, plan, parsed_outputs, output

    def make_simple_pr(self, path, content="feature\n"):
        return self.fixture.prepare_pr(change=lambda repo: repo.write(path, content))

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_docs_only_is_minimal_and_disabled_matrices_fail_safe_full(self):
        base, head, checkout = self.make_simple_pr("docs/guide with spaces.md")
        result, plan, outputs, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertFalse(plan["full"])
        self.assertEqual(plan["categories"], ["docs"])
        self.assertTrue(all(not value for value in plan["run"].values()))
        self.assertEqual(outputs["run_packages"], "false")
        self.assertEqual(
            [row["package"] for row in json.loads(outputs["package_matrix"])],
            sorted(planner_module.load_architecture(CONFIG_PATH).packages),
        )
        self.assertEqual(
            json.loads(outputs["coverage_packages"]),
            sorted(planner_module.load_architecture(CONFIG_PATH).packages),
        )

    def test_empty_diff_is_minimal(self):
        base, head, checkout = self.fixture.prepare_pr(empty_feature=True)
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertEqual(plan["changed_files"], [])
        self.assertEqual(plan["reason_codes"], ["empty_diff"])
        self.assertFalse(any(plan["run"].values()))

    def test_test_only_change_selects_owner_without_downstream_or_app(self):
        base, head, checkout = self.make_simple_pr(
            "Packages/LLMKit/Tests/LLMKitTests/OnlyTests.swift"
        )
        result, plan, outputs, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertEqual(plan["selected"]["package_tests"], ["LLMKit"])
        self.assertEqual(plan["selected"]["coverage_packages"], ["LLMKit"])
        self.assertEqual(plan["selected"]["public_api_modules"], [])
        self.assertFalse(plan["run"]["app_debug"])
        self.assertFalse(plan["run"]["release"])
        self.assertEqual(json.loads(outputs["coverage_packages"]), ["LLMKit"])

    def test_source_changes_use_exact_reverse_dependency_closure(self):
        cases = {
            "LLMKit": ["LLMKit", "SingleGreenConversationAdapters", "VoiceChatCore"],
            "SingleGreenConversationAdapters": ["SingleGreenConversationAdapters"],
            "SingleGreenGlassesKit": ["SingleGreenConversationAdapters", "SingleGreenGlassesKit"],
            "StreamingTextKit": ["SingleGreenConversationAdapters", "SingleGreenGlassesKit", "StreamingTextKit"],
            "VoiceActivityDetectionKit": ["SingleGreenConversationAdapters", "VoiceActivityDetectionKit", "VoiceChatCore"],
            "VoiceChatCore": ["SingleGreenConversationAdapters", "VoiceChatCore"],
            "VoiceChatDomain": ["SingleGreenConversationAdapters", "SingleGreenGlassesKit", "VoiceChatDomain"],
        }
        for package, expected in cases.items():
            with self.subTest(package=package):
                self.fixture.close()
                self.fixture = RepositoryFixture()
                directory = "Resources" if package == "StreamingTextKit" else "Sources"
                path = f"Packages/{package}/{directory}/Fixture/OrdinaryFeature.swift"
                base, head, checkout = self.make_simple_pr(path)
                result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
                self.assert_success(result)
                self.assertFalse(plan["full"])
                self.assertEqual(plan["selected"]["package_tests"], expected)
                self.assertEqual(plan["selected"]["coverage_packages"], [package])
                self.assertTrue(plan["run"]["app_debug"])
                self.assertTrue(plan["run"]["release"])

    def test_vad_source_selects_both_public_api_modules(self):
        base, head, checkout = self.make_simple_pr(
            "Packages/VoiceActivityDetectionKit/Sources/VoiceActivityDetectionKit/Ordinary.swift"
        )
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        modules = [row["module"] for row in plan["selected"]["public_api_modules"]]
        self.assertEqual(modules, ["VoiceActivityDetectionKit", "WebRTCVoiceActivityDetection"])

    def test_app_change_selects_debug_and_release(self):
        base, head, checkout = self.make_simple_pr("SingleGreenDemo/App/Feature.swift")
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertTrue(plan["run"]["app_debug"])
        self.assertTrue(plan["run"]["release"])
        self.assertFalse(plan["run"]["package_tests"])

    def test_release_only_package_source_cannot_skip_release_builds(self):
        base, head, checkout = self.make_simple_pr(
            "Packages/LLMKit/Sources/LLMKit/ReleaseOnly.swift",
            "#if !DEBUG\nlet releaseOnlyValue = missingReleaseSymbol\n#endif\n",
        )
        result, plan, outputs, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertFalse(plan["full"])
        self.assertTrue(plan["run"]["release"])
        self.assertEqual(outputs["run_release_build"], "true")

    def test_known_api_baseline_selects_api_only(self):
        path = "api-baselines/toolchain/macos-arm64/VoiceChatCore.json"
        base, head, checkout = self.make_simple_pr(path, "{}\n")
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertFalse(plan["full"])
        self.assertEqual(
            plan["selected"]["public_api_modules"],
            [{"module": "VoiceChatCore", "package": "VoiceChatCore"}],
        )
        self.assertTrue(plan["run"]["public_api"])
        self.assertFalse(plan["run"]["package_tests"])
        self.assertFalse(plan["run"]["release"])

    def test_control_unknown_and_unknown_api_paths_fail_closed(self):
        paths = [
            "Configurations/User.xcconfig",
            ".github/workflows/new.yml",
            "Packages/LLMKit/Package.swift",
            "SingleGreenDemo.xcodeproj/project.pbxproj",
            "scripts/new_gate.sh",
            "docs/executable-schema.json",
            "api-baselines/toolchain/macos-arm64/UnknownModule.json",
            "Packages/Unknown/Sources/Unknown.swift",
            "unexpected-root.data",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.fixture.close()
                self.fixture = RepositoryFixture()
                base, head, checkout = self.make_simple_pr(path)
                result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
                self.assert_success(result)
                self.assertTrue(plan["full"])
                self.assertTrue(all(plan["run"].values()))

    def test_high_risk_streaming_or_concurrency_source_fails_closed(self):
        paths = [
            "Packages/StreamingTextKit/Sources/StreamingTextKit/Buffer.swift",
            "Packages/VoiceChatCore/Sources/VoiceChatCore/VoiceActivatedASRSession.swift",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.fixture.close()
                self.fixture = RepositoryFixture()
                base, head, checkout = self.make_simple_pr(path)
                result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
                self.assert_success(result)
                self.assertTrue(plan["full"])
                self.assertIn("high_risk_source_changed", plan["full_reasons"])

    def test_third_party_readme_is_source_not_docs(self):
        base, head, checkout = self.make_simple_pr(
            "Packages/VoiceActivityDetectionKit/ThirdParty/WebRTC/README.md"
        )
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertEqual(plan["categories"], ["package_source"])
        self.assertEqual(plan["selected"]["coverage_packages"], ["VoiceActivityDetectionKit"])

    def test_delete_retains_old_package_ownership(self):
        path = "Packages/VoiceChatDomain/Sources/VoiceChatDomain/Deleted.swift"

        def delete(repo):
            (repo.root / path).unlink()

        base, head, checkout = self.fixture.prepare_pr(
            initial={path: "old\n"}, change=delete
        )
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertEqual(
            plan["selected"]["package_tests"],
            ["SingleGreenConversationAdapters", "SingleGreenGlassesKit", "VoiceChatDomain"],
        )

    def test_rename_classifies_both_endpoints_and_deduplicates(self):
        old = "Packages/VoiceChatCore/Tests/VoiceChatCoreTests/Old.swift"
        new = "Packages/VoiceChatCore/Sources/VoiceChatCore/New.swift"

        def rename(repo):
            destination = repo.root / new
            destination.parent.mkdir(parents=True, exist_ok=True)
            repo.git("mv", old, new)

        base, head, checkout = self.fixture.prepare_pr(
            initial={old: "same content\n"}, change=rename
        )
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertEqual(plan["direct_packages"]["test"], ["VoiceChatCore"])
        self.assertEqual(plan["direct_packages"]["source"], ["VoiceChatCore"])
        self.assertEqual(
            plan["selected"]["package_tests"],
            ["SingleGreenConversationAdapters", "VoiceChatCore"],
        )

    def test_rename_to_unknown_path_fails_closed(self):
        old = "Packages/LLMKit/Tests/LLMKitTests/Old.swift"
        new = "mystery/New.swift"

        def rename(repo):
            (repo.root / new).parent.mkdir(parents=True)
            repo.git("mv", old, new)

        base, head, checkout = self.fixture.prepare_pr(initial={old: "same\n"}, change=rename)
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertTrue(plan["full"])
        self.assertIn("unknown_changed", plan["full_reasons"])

    def test_spaces_and_newlines_in_filename_are_nul_safe(self):
        path = "Packages/VoiceChatDomain/Tests/VoiceChatDomainTests/name with space\nand newline.swift"
        base, head, checkout = self.make_simple_pr(path)
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        self.assertEqual(plan["selected"]["package_tests"], ["VoiceChatDomain"])
        self.assertEqual(plan["changed_files"][0]["paths"][0]["path"], path)

    def test_base_advance_is_not_misclassified_as_pr_change(self):
        base, head, checkout = self.fixture.prepare_pr(
            change=lambda repo: repo.write(
                "Packages/LLMKit/Tests/LLMKitTests/Feature.swift"
            ),
            base_change=lambda repo: repo.write("docs/base-only.md"),
        )
        result, plan, _, _ = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(result)
        paths = [
            path["path"]
            for record in plan["changed_files"]
            for path in record["paths"]
        ]
        self.assertEqual(paths, ["Packages/LLMKit/Tests/LLMKitTests/Feature.swift"])

    def test_pr_checkout_and_parent_mismatches_are_blocking_errors(self):
        base, head, checkout = self.make_simple_pr(
            "Packages/LLMKit/Tests/LLMKitTests/Feature.swift"
        )
        cases = [
            (base, head, head),
            (head, base, checkout),
            ("0" * 40, head, checkout),
        ]
        for bad_base, bad_head, bad_checkout in cases:
            with self.subTest(values=(bad_base, bad_head, bad_checkout)):
                result, plan, _, _ = self.invoke(
                    base=bad_base, head=bad_head, checkout=bad_checkout
                )
                self.assertEqual(result.returncode, 3)
                self.assertIsNone(plan)

    def test_non_pr_event_and_full_mode_select_every_gate(self):
        checkout = self.fixture.base
        result, plan, outputs, _ = self.invoke(
            mode="full",
            checkout=checkout,
            extra=("--full-reason", "main_push"),
        )
        self.assert_success(result)
        self.assertTrue(plan["full"])
        self.assertTrue(all(plan["run"].values()))
        self.assertEqual(len(plan["selected"]["package_tests"]), 7)
        self.assertEqual(len(plan["selected"]["coverage_packages"]), 7)
        self.assertEqual(len(plan["selected"]["public_api_modules"]), 8)
        self.assertEqual(outputs["run_release_build"], "true")

        event_output = self.fixture.root / "event-plan.json"
        event = subprocess.run(
            [
                sys.executable,
                str(PLANNER_PATH),
                "--event-name",
                "push",
                "--repository-root",
                str(self.fixture.root),
                "--checkout-sha",
                checkout,
                "--json-output",
                str(event_output),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(event.returncode, 0, event.stderr.decode())
        self.assertTrue(json.loads(event_output.read_text())["full"])

    def test_explicit_trusted_config_path_is_supported(self):
        base, head, checkout = self.make_simple_pr("docs/trusted-config.md")
        trusted_config = self.fixture.root / "trusted/base-architecture.json"
        trusted_config.parent.mkdir(parents=True)
        shutil.copyfile(CONFIG_PATH, trusted_config)
        result, plan, _, _ = self.invoke(
            base=base,
            head=head,
            checkout=checkout,
            extra=("--config-path", str(trusted_config)),
        )
        self.assert_success(result)
        self.assertFalse(plan["full"])

    def test_full_reason_cannot_inject_github_outputs(self):
        result, plan, _, _ = self.invoke(
            mode="full",
            checkout=self.fixture.base,
            extra=("--full-reason", "trusted\nrun_packages=false"),
        )
        self.assertEqual(result.returncode, 3)
        self.assertIsNone(plan)

    def test_repeated_invocation_is_byte_identical(self):
        base, head, checkout = self.make_simple_pr(
            "Packages/VoiceChatDomain/Tests/VoiceChatDomainTests/Stable.swift"
        )
        first, _, first_outputs, output = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(first)
        first_bytes = output.read_bytes()
        second, _, second_outputs, output = self.invoke(base=base, head=head, checkout=checkout)
        self.assert_success(second)
        self.assertEqual(first_bytes, output.read_bytes())
        self.assertEqual(first_outputs, second_outputs)

    def test_invalid_diff_status_is_ambiguous(self):
        records, ambiguous = planner_module.parse_name_status(b"T\0path with space\0")
        self.assertTrue(ambiguous)
        architecture = planner_module.load_architecture(CONFIG_PATH)
        plan = planner_module.selective_plan(architecture, "range", {}, b"T\0mystery\0")
        self.assertTrue(plan["full"])
        self.assertIn("ambiguous_diff_status", plan["full_reasons"])

    def test_invalid_architecture_graph_blocks_planning(self):
        config_path = self.fixture.root / "config/architecture-boundaries.json"
        original = json.loads(config_path.read_text())
        variants = []

        duplicate = json.loads(json.dumps(original))
        duplicate["packages"].append(duplicate["packages"][0])
        variants.append(duplicate)

        cycle = json.loads(json.dumps(original))
        by_name = {row["name"]: row for row in cycle["packages"]}
        by_name["LLMKit"]["local_dependencies"] = ["VoiceChatCore"]
        variants.append(cycle)

        unknown_product = json.loads(json.dumps(original))
        unknown_product["app"]["targets"][0]["package_products"].append("UnknownProduct")
        variants.append(unknown_product)

        for variant in variants:
            with self.subTest(kind=len(variant.get("packages", []))):
                config_path.write_text(json.dumps(variant))
                result, plan, _, _ = self.invoke(
                    mode="full",
                    checkout=self.fixture.base,
                    extra=("--full-reason", "test"),
                )
                self.assertEqual(result.returncode, 4)
                self.assertIsNone(plan)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
