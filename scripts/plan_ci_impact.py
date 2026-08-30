#!/usr/bin/env python3
"""Produce a deterministic, fail-closed CI plan from the reviewed package graph.

Pull requests are planned from the exact synthetic merge commit that CI tests.
Pushes to main and manually requested certification use full mode.  The script
has no GitHub API dependency; all routing inputs are explicit and reviewable.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Sequence


SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
SAFE_NAME_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
SAFE_REASON_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]+$")
SOURCE_DIRECTORIES = {"Sources", "Tools", "Plugins", "Resources", "ThirdParty"}
DOCUMENT_EXTENSIONS = {
    ".md",
    ".markdown",
    ".txt",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".svg",
    ".pdf",
}
CONTROL_EXTENSIONS = {".json", ".yaml", ".yml", ".toml", ".sh", ".py"}
HIGH_RISK_PATH_MARKERS = (
    "VoiceActivatedASRSession",
    "AudioCapture",
    "LLMChatClient",
    "LLMAgent",
    "ContextTransaction",
    "ConversationPorts",
    "VoiceConversationController",
    "ConversationReplyPipeline",
    "ConversationDisplayScheduler",
    "ConversationLiveAdapters",
    "ConversationPreparationResolver",
    "VoiceConversationComposition",
    "ConversationDependencies",
)


class PlannerInputError(Exception):
    """The requested comparison cannot be trusted."""


class PlannerConfigError(Exception):
    """The architecture configuration is malformed or internally inconsistent."""


class PlannerWriteError(Exception):
    """A requested output could not be written."""


@dataclass(frozen=True)
class Package:
    name: str
    path: str
    dependencies: tuple[str, ...]
    products: tuple[str, ...]


@dataclass(frozen=True)
class Architecture:
    packages: dict[str, Package]
    modules_by_name: dict[str, str]
    modules_by_package: dict[str, tuple[str, ...]]
    reverse_dependencies: dict[str, tuple[str, ...]]
    app_dependency_packages: frozenset[str]

    @property
    def package_names(self) -> tuple[str, ...]:
        return tuple(sorted(self.packages))

    @property
    def public_api_modules(self) -> tuple[tuple[str, str], ...]:
        return tuple(sorted(self.modules_by_name.items()))


def _require_string(record: dict[str, Any], key: str, context: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value:
        raise PlannerConfigError(f"{context}.{key} must be a non-empty string")
    return value


def _require_string_list(record: dict[str, Any], key: str, context: str) -> list[str]:
    value = record.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise PlannerConfigError(f"{context}.{key} must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise PlannerConfigError(f"{context}.{key} contains duplicates")
    return value


def load_architecture(config_path: Path) -> Architecture:
    try:
        document = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PlannerConfigError(f"unable to read architecture config: {error}") from error
    if not isinstance(document, dict):
        raise PlannerConfigError("architecture config must be a JSON object")

    package_records = document.get("packages")
    if not isinstance(package_records, list) or not package_records:
        raise PlannerConfigError("packages must be a non-empty list")

    packages: dict[str, Package] = {}
    product_owners: dict[str, str] = {}
    for index, record in enumerate(package_records):
        context = f"packages[{index}]"
        if not isinstance(record, dict):
            raise PlannerConfigError(f"{context} must be an object")
        name = _require_string(record, "name", context)
        path = _require_string(record, "path", context)
        dependencies = _require_string_list(record, "local_dependencies", context)
        if not SAFE_NAME_PATTERN.fullmatch(name):
            raise PlannerConfigError(f"unsafe package name: {name!r}")
        if name in packages:
            raise PlannerConfigError(f"duplicate package: {name}")
        if path != f"Packages/{name}":
            raise PlannerConfigError(f"unexpected package path for {name}: {path}")
        products_value = record.get("products")
        if not isinstance(products_value, list) or not products_value:
            raise PlannerConfigError(f"{context}.products must be a non-empty list")
        products: list[str] = []
        for product_index, product in enumerate(products_value):
            if not isinstance(product, dict):
                raise PlannerConfigError(f"{context}.products[{product_index}] must be an object")
            product_name = _require_string(product, "name", f"{context}.products[{product_index}]")
            if product_name in product_owners:
                raise PlannerConfigError(f"duplicate product: {product_name}")
            product_owners[product_name] = name
            products.append(product_name)
        packages[name] = Package(name, path, tuple(sorted(dependencies)), tuple(sorted(products)))

    for package in packages.values():
        for dependency in package.dependencies:
            if dependency not in packages:
                raise PlannerConfigError(
                    f"package {package.name} has unknown local dependency {dependency}"
                )

    visit_state: dict[str, int] = {}

    def visit(name: str, stack: tuple[str, ...]) -> None:
        state = visit_state.get(name, 0)
        if state == 1:
            raise PlannerConfigError("package dependency cycle: " + " -> ".join((*stack, name)))
        if state == 2:
            return
        visit_state[name] = 1
        for dependency in packages[name].dependencies:
            visit(dependency, (*stack, name))
        visit_state[name] = 2

    for package_name in sorted(packages):
        visit(package_name, ())

    reverse: dict[str, set[str]] = {name: set() for name in packages}
    for package in packages.values():
        for dependency in package.dependencies:
            reverse[dependency].add(package.name)

    module_records = document.get("public_api_modules")
    if not isinstance(module_records, list) or not module_records:
        raise PlannerConfigError("public_api_modules must be a non-empty list")
    modules_by_name: dict[str, str] = {}
    modules_by_package_mutable: dict[str, list[str]] = {name: [] for name in packages}
    for index, record in enumerate(module_records):
        context = f"public_api_modules[{index}]"
        if not isinstance(record, dict):
            raise PlannerConfigError(f"{context} must be an object")
        module = _require_string(record, "module", context)
        package_name = _require_string(record, "package", context)
        if module in modules_by_name:
            raise PlannerConfigError(f"duplicate public API module: {module}")
        if package_name not in packages:
            raise PlannerConfigError(f"public API module {module} has unknown package {package_name}")
        modules_by_name[module] = package_name
        modules_by_package_mutable[package_name].append(module)

    app = document.get("app")
    if not isinstance(app, dict):
        raise PlannerConfigError("app must be an object")
    targets = app.get("targets")
    if not isinstance(targets, list) or not targets:
        raise PlannerConfigError("app.targets must be a non-empty list")
    directly_consumed: set[str] = set()
    for index, target in enumerate(targets):
        context = f"app.targets[{index}]"
        if not isinstance(target, dict):
            raise PlannerConfigError(f"{context} must be an object")
        for product_name in _require_string_list(target, "package_products", context):
            owner = product_owners.get(product_name)
            if owner is None:
                raise PlannerConfigError(f"{context} references unknown product {product_name}")
            directly_consumed.add(owner)

    app_dependency_packages = set(directly_consumed)
    pending = list(directly_consumed)
    while pending:
        package_name = pending.pop()
        for dependency in packages[package_name].dependencies:
            if dependency not in app_dependency_packages:
                app_dependency_packages.add(dependency)
                pending.append(dependency)

    return Architecture(
        packages=packages,
        modules_by_name=modules_by_name,
        modules_by_package={
            name: tuple(sorted(modules)) for name, modules in modules_by_package_mutable.items()
        },
        reverse_dependencies={
            name: tuple(sorted(dependants)) for name, dependants in reverse.items()
        },
        app_dependency_packages=frozenset(app_dependency_packages),
    )


def run_git(repository_root: Path, arguments: Sequence[str]) -> bytes:
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=repository_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise PlannerInputError(f"unable to execute git: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise PlannerInputError(f"git {' '.join(arguments[:2])} failed: {detail}")
    return result.stdout


def validate_commit(repository_root: Path, sha: str, label: str) -> str:
    if not SHA_PATTERN.fullmatch(sha):
        raise PlannerInputError(f"{label} must be a full 40-character commit SHA")
    resolved = run_git(repository_root, ["rev-parse", "--verify", f"{sha}^{{commit}}"])
    resolved_sha = resolved.decode("ascii", errors="strict").strip().lower()
    if resolved_sha != sha.lower():
        raise PlannerInputError(f"{label} did not resolve to the requested commit")
    return resolved_sha


def parse_name_status(raw: bytes) -> tuple[list[dict[str, Any]], bool]:
    """Parse `git diff --name-status -z`; return records and ambiguity flag."""

    if not raw:
        return [], False
    tokens = raw.split(b"\0")
    if tokens[-1] != b"":
        return [{"status": "malformed", "paths": []}], True
    tokens.pop()
    index = 0
    records: list[dict[str, Any]] = []
    ambiguous = False
    while index < len(tokens):
        try:
            status = tokens[index].decode("ascii", errors="strict")
        except UnicodeError:
            status = "malformed"
        index += 1
        path_count = 2 if re.fullmatch(r"[RC][0-9]{1,3}", status) else 1
        if index + path_count > len(tokens):
            records.append({"status": status, "paths": []})
            return records, True
        paths = [os.fsdecode(token) for token in tokens[index : index + path_count]]
        index += path_count
        valid = bool(
            re.fullmatch(r"[AMD]", status)
            or re.fullmatch(r"[RC][0-9]{1,3}", status)
        )
        if not valid:
            ambiguous = True
        records.append({"status": status, "raw_paths": paths})
    return records, ambiguous


def _is_safe_repository_path(path: str) -> bool:
    if not path or path.startswith("/") or "\0" in path:
        return False
    parts = PurePosixPath(path).parts
    return bool(parts) and all(part not in {"", ".", ".."} for part in parts)


def _is_high_risk_source(path: str) -> bool:
    if path.startswith("Packages/StreamingTextKit/Sources/"):
        return True
    return any(marker in path for marker in HIGH_RISK_PATH_MARKERS)


def classify_path(path: str, architecture: Architecture) -> dict[str, Any]:
    result: dict[str, Any] = {"path": path}
    if not _is_safe_repository_path(path):
        result["category"] = "unknown"
        return result

    components = path.split("/")
    basename = components[-1]
    suffix = PurePosixPath(path).suffix.lower()

    if basename in {"Package.swift", "Package.resolved"}:
        result["category"] = "config"
        return result
    if path.startswith(".github/"):
        result["category"] = "workflow"
        return result
    if path.startswith("scripts/") or path.startswith("config/") or path.startswith("Configurations/"):
        result["category"] = "config"
        return result
    if path.startswith("SingleGreenDemo.xcodeproj/"):
        result["category"] = "config"
        return result

    if path.startswith("api-baselines/"):
        if basename.lower() == "readme.md":
            result["category"] = "docs"
            return result
        if suffix == ".json":
            module = basename[:-5]
            package_name = architecture.modules_by_name.get(module)
            if package_name is not None:
                result.update(category="api_baseline", module=module, package=package_name)
                return result
        result["category"] = "unknown"
        return result

    if path.startswith("SingleGreenDemo/") or path.startswith("SingleGreenDemoTests/"):
        result["category"] = "app"
        return result

    if path == "Packages/README.md":
        result["category"] = "docs"
        return result
    if len(components) >= 2 and components[0] == "Packages":
        package_name = components[1]
        package = architecture.packages.get(package_name)
        if package is None:
            result["category"] = "unknown"
            return result
        if len(components) >= 3 and components[2] == "Tests":
            result.update(category="package_test", package=package_name)
            return result
        if len(components) >= 3 and components[2] in SOURCE_DIRECTORIES:
            result.update(category="package_source", package=package_name)
            if _is_high_risk_source(path):
                result["high_risk"] = True
            return result
        if len(components) == 3 and (
            basename.lower().startswith("readme") or suffix in {".md", ".markdown"}
        ):
            result["category"] = "docs"
            return result
        result["category"] = "unknown"
        return result

    if path.startswith("docs/"):
        result["category"] = "config" if suffix in CONTROL_EXTENSIONS else "docs"
        return result
    if path.startswith(".codex/"):
        result["category"] = "docs"
        return result
    if len(components) == 1 and (
        basename in {"AGENTS.md", "NOTICE.md"} or suffix in {".md", ".markdown"}
    ):
        result["category"] = "docs"
        return result
    if basename == "AGENTS.md" or suffix in DOCUMENT_EXTENSIONS and path.startswith("docs/"):
        result["category"] = "docs"
        return result

    result["category"] = "unknown"
    return result


def downstream_closure(package_names: Iterable[str], architecture: Architecture) -> set[str]:
    selected = set(package_names)
    pending = list(selected)
    while pending:
        package_name = pending.pop()
        for dependant in architecture.reverse_dependencies[package_name]:
            if dependant not in selected:
                selected.add(dependant)
                pending.append(dependant)
    return selected


def full_plan(
    architecture: Architecture,
    mode: str,
    comparison: dict[str, str],
    reasons: Iterable[str],
    changed_files: list[dict[str, Any]] | None = None,
    categories: Iterable[str] = (),
) -> dict[str, Any]:
    packages = list(architecture.package_names)
    modules = [
        {"module": module, "package": package}
        for module, package in architecture.public_api_modules
    ]
    reason_codes = sorted(set(reasons)) or ["explicit_full"]
    return {
        "schema_version": 1,
        "mode": mode,
        "comparison": comparison,
        "full": True,
        "full_reasons": reason_codes,
        "changed_files": changed_files or [],
        "categories": sorted(set(categories)),
        "direct_packages": {"source": [], "test": []},
        "selected": {
            "package_tests": packages,
            "coverage_packages": packages,
            "public_api_modules": modules,
        },
        "run": {
            "package_tests": True,
            "app_debug": True,
            "release": True,
            "coverage": True,
            "public_api": True,
        },
        "reason_codes": reason_codes,
    }


def selective_plan(
    architecture: Architecture,
    mode: str,
    comparison: dict[str, str],
    raw_diff: bytes,
) -> dict[str, Any]:
    raw_records, ambiguous = parse_name_status(raw_diff)
    changed_files: list[dict[str, Any]] = []
    categories: set[str] = set()
    source_packages: set[str] = set()
    test_packages: set[str] = set()
    baseline_modules: set[str] = set()
    full_reasons: set[str] = set()

    if ambiguous:
        full_reasons.add("ambiguous_diff_status")

    for raw_record in raw_records:
        status = raw_record["status"]
        raw_paths = raw_record.get("raw_paths", [])
        path_records: list[dict[str, Any]] = []
        if re.fullmatch(r"R[0-9]{1,3}", status):
            role_paths = (("old", raw_paths[0]), ("new", raw_paths[1]))
        elif re.fullmatch(r"C[0-9]{1,3}", status):
            role_paths = (("new", raw_paths[1]),)
        elif len(raw_paths) == 1:
            role_paths = (("path", raw_paths[0]),)
        else:
            role_paths = ()

        for role, path in role_paths:
            classified = classify_path(path, architecture)
            classified["role"] = role
            path_records.append(classified)
            category = classified["category"]
            categories.add(category)
            package_name = classified.get("package")
            if category == "package_source" and package_name:
                source_packages.add(package_name)
                if classified.get("high_risk"):
                    full_reasons.add("high_risk_source_changed")
            elif category == "package_test" and package_name:
                test_packages.add(package_name)
            elif category == "api_baseline":
                baseline_modules.add(classified["module"])
            elif category in {"config", "workflow", "unknown"}:
                full_reasons.add(f"{category}_changed")

        changed_files.append({"status": status, "paths": path_records})

    changed_files.sort(
        key=lambda record: (
            record["status"],
            tuple(path["path"] for path in record["paths"]),
        )
    )
    if full_reasons:
        return full_plan(
            architecture,
            mode,
            comparison,
            full_reasons,
            changed_files=changed_files,
            categories=categories,
        )

    selected_package_tests = downstream_closure(source_packages, architecture) | test_packages
    coverage_packages = source_packages | test_packages
    api_modules = set(baseline_modules)
    for package_name in source_packages:
        api_modules.update(architecture.modules_by_package[package_name])
    app_debug = bool(source_packages & architecture.app_dependency_packages) or "app" in categories

    reason_codes: set[str] = set()
    if not changed_files:
        reason_codes.add("empty_diff")
    if "docs" in categories:
        reason_codes.add("docs_changed")
    if source_packages:
        reason_codes.add("package_source_changed")
        if selected_package_tests != source_packages:
            reason_codes.add("downstream_packages_selected")
    if test_packages:
        reason_codes.add("package_tests_changed")
    if "app" in categories:
        reason_codes.add("app_changed")
    elif app_debug:
        reason_codes.add("app_dependency_affected")
    if baseline_modules:
        reason_codes.add("api_baseline_changed")

    selected_modules = [
        {"module": module, "package": architecture.modules_by_name[module]}
        for module in sorted(api_modules)
    ]
    return {
        "schema_version": 1,
        "mode": mode,
        "comparison": comparison,
        "full": False,
        "full_reasons": [],
        "changed_files": changed_files,
        "categories": sorted(categories),
        "direct_packages": {
            "source": sorted(source_packages),
            "test": sorted(test_packages),
        },
        "selected": {
            "package_tests": sorted(selected_package_tests),
            "coverage_packages": sorted(coverage_packages),
            "public_api_modules": selected_modules,
        },
        "run": {
            "package_tests": bool(selected_package_tests),
            "app_debug": app_debug,
            # Production source and App changes must compile both Release
            # variants so PRs cannot hide failures behind `#if !DEBUG`.
            "release": bool(source_packages) or "app" in categories,
            "coverage": bool(coverage_packages),
            "public_api": bool(selected_modules),
        },
        "reason_codes": sorted(reason_codes),
    }


def build_plan(arguments: argparse.Namespace) -> tuple[Architecture, dict[str, Any]]:
    repository_root = arguments.repository_root.resolve()
    config_path = arguments.config
    if not config_path.is_absolute():
        config_path = repository_root / config_path
    architecture = load_architecture(config_path)

    mode = arguments.mode
    if arguments.event_name:
        event_modes = {
            "pull_request": "pull-request",
            "push": "full",
            "workflow_dispatch": "full",
        }
        event_mode = event_modes.get(arguments.event_name)
        if event_mode is None:
            raise PlannerInputError(f"unsupported event: {arguments.event_name}")
        if mode and mode != event_mode:
            raise PlannerInputError("--mode conflicts with --event-name")
        mode = event_mode
    if mode is None:
        raise PlannerInputError("one of --mode or --event-name is required")

    if mode == "pull-request":
        base_sha = validate_commit(repository_root, arguments.base_sha or "", "base SHA")
        head_sha = validate_commit(repository_root, arguments.head_sha or "", "head SHA")
        checkout_sha = validate_commit(
            repository_root, arguments.checkout_sha or "", "checkout SHA"
        )
        parent_line = run_git(
            repository_root, ["rev-list", "--parents", "-n", "1", checkout_sha]
        ).decode("ascii", errors="strict").strip().split()
        if len(parent_line) != 3:
            raise PlannerInputError("pull-request checkout must be a two-parent synthetic merge")
        if parent_line[1].lower() != base_sha or parent_line[2].lower() != head_sha:
            raise PlannerInputError(
                "pull-request checkout parents do not match event base/head in order"
            )
        raw_diff = run_git(
            repository_root,
            ["diff", "--name-status", "-z", "--find-renames=50%", base_sha, checkout_sha, "--"],
        )
        comparison = {
            "base_sha": base_sha,
            "head_sha": head_sha,
            "checkout_sha": checkout_sha,
            "diff_from_sha": base_sha,
            "diff_to_sha": checkout_sha,
        }
        return architecture, selective_plan(architecture, mode, comparison, raw_diff)

    if mode == "range":
        base_sha = validate_commit(repository_root, arguments.base_sha or "", "base SHA")
        head_sha = validate_commit(repository_root, arguments.head_sha or "", "head SHA")
        merge_bases = run_git(repository_root, ["merge-base", "--all", base_sha, head_sha])
        merge_base_values = [line for line in merge_bases.decode("ascii").splitlines() if line]
        if len(merge_base_values) != 1:
            raise PlannerInputError("range mode requires exactly one merge base")
        merge_base = validate_commit(repository_root, merge_base_values[0], "merge base")
        raw_diff = run_git(
            repository_root,
            ["diff", "--name-status", "-z", "--find-renames=50%", merge_base, head_sha, "--"],
        )
        comparison = {
            "base_sha": base_sha,
            "head_sha": head_sha,
            "checkout_sha": "",
            "diff_from_sha": merge_base,
            "diff_to_sha": head_sha,
        }
        return architecture, selective_plan(architecture, mode, comparison, raw_diff)

    if mode == "full":
        checkout_sha = validate_commit(
            repository_root, arguments.checkout_sha or arguments.head_sha or "", "checkout SHA"
        )
        reason = arguments.full_reason
        if arguments.event_name and not reason:
            reason = f"{arguments.event_name}_full_certification"
        if not reason:
            raise PlannerInputError("full mode requires --full-reason")
        if not SAFE_REASON_PATTERN.fullmatch(reason):
            raise PlannerInputError(
                "full reason may contain only letters, digits, dot, colon, underscore, or hyphen"
            )
        comparison = {
            "base_sha": "",
            "head_sha": "",
            "checkout_sha": checkout_sha,
            "diff_from_sha": "",
            "diff_to_sha": checkout_sha,
        }
        return architecture, full_plan(architecture, mode, comparison, [reason])

    raise PlannerInputError(f"unsupported mode: {mode}")


def github_outputs(architecture: Architecture, plan: dict[str, Any]) -> dict[str, str]:
    run = plan["run"]
    all_packages = list(architecture.package_names)
    package_names = plan["selected"]["package_tests"] if run["package_tests"] else all_packages
    coverage_names = plan["selected"]["coverage_packages"] if run["coverage"] else all_packages
    package_matrix = [
        {"package": name, "path": architecture.packages[name].path}
        for name in package_names
    ]
    public_api_matrix = (
        plan["selected"]["public_api_modules"]
        if run["public_api"]
        else [
            {"module": module, "package": package}
            for module, package in architecture.public_api_modules
        ]
    )
    compact = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"))
    reason = ",".join(plan["reason_codes"])
    outputs = {
        "full": str(plan["full"]).lower(),
        "run_packages": str(run["package_tests"]).lower(),
        "package_matrix": compact(package_matrix),
        "run_app_simulator": str(run["app_debug"]).lower(),
        "run_release_build": str(run["release"]).lower(),
        "run_coverage": str(run["coverage"]).lower(),
        "coverage_packages": compact(coverage_names),
        "run_public_api": str(run["public_api"]).lower(),
        "reason": reason,
        "changed_count": str(len(plan["changed_files"])),
        # Descriptive aliases keep the standalone contract useful outside ci.yml.
        "run_package_tests": str(run["package_tests"]).lower(),
        "run_app_debug": str(run["app_debug"]).lower(),
        "run_release": str(run["release"]).lower(),
        "coverage_matrix": compact([{"package": name} for name in coverage_names]),
        "public_api_matrix": compact(public_api_matrix),
    }
    return outputs


def _write_text(path: Path, content: str, append: bool = False) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a" if append else "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
    except (OSError, UnicodeError) as error:
        raise PlannerWriteError(f"unable to write {path}: {error}") from error


def emit_outputs(
    architecture: Architecture, plan: dict[str, Any], arguments: argparse.Namespace
) -> None:
    rendered_json = json.dumps(plan, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    if arguments.json_output:
        _write_text(arguments.json_output, rendered_json)
    if arguments.github_output:
        lines = "".join(f"{key}={value}\n" for key, value in github_outputs(architecture, plan).items())
        _write_text(arguments.github_output, lines, append=True)
    if arguments.summary_file:
        run = plan["run"]
        summary = (
            "### CI impact plan\n\n"
            f"- Mode: `{plan['mode']}`\n"
            f"- Full fallback: `{str(plan['full']).lower()}`\n"
            f"- Changed entries: `{len(plan['changed_files'])}`\n"
            f"- Package tests: `{', '.join(plan['selected']['package_tests']) or 'none'}`\n"
            f"- App Debug: `{str(run['app_debug']).lower()}`\n"
            f"- Release: `{str(run['release']).lower()}`\n"
            f"- Coverage: `{', '.join(plan['selected']['coverage_packages']) or 'none'}`\n"
            f"- Public API: `{str(run['public_api']).lower()}`\n"
            f"- Reason: `{', '.join(plan['reason_codes']) or 'none'}`\n"
        )
        _write_text(arguments.summary_file, summary, append=True)
    if not arguments.json_output:
        sys.stdout.write(rendered_json)


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("pull-request", "range", "full"))
    parser.add_argument("--event-name")
    parser.add_argument("--repository-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--config",
        "--config-path",
        dest="config",
        type=Path,
        default=Path("config/architecture-boundaries.json"),
        help="architecture config; relative paths are resolved from --repository-root",
    )
    parser.add_argument("--base-sha")
    parser.add_argument("--head-sha")
    parser.add_argument("--checkout-sha")
    parser.add_argument("--full-reason")
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary-file", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv if argv is not None else sys.argv[1:])
    try:
        architecture, plan = build_plan(arguments)
        emit_outputs(architecture, plan, arguments)
    except PlannerInputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 3
    except PlannerConfigError as error:
        print(f"error: {error}", file=sys.stderr)
        return 4
    except PlannerWriteError as error:
        print(f"error: {error}", file=sys.stderr)
        return 5
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
