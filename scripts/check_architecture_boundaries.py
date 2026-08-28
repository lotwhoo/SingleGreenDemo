#!/usr/bin/env python3
"""Validate reviewed SwiftPM, import, and App-link architecture boundaries."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


class ValidationError(Exception):
    pass


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"cannot read configuration {path}: {error}") from error


def product_type(value: object) -> str:
    if not isinstance(value, dict) or len(value) != 1:
        return "unknown"
    return next(iter(value))


def dependency_name(value: object) -> str:
    if not isinstance(value, dict) or len(value) != 1:
        return "<unknown>"
    payload = next(iter(value.values()))
    if isinstance(payload, list) and payload:
        return str(payload[0])
    return "<unknown>"


def dump_package(package_path: Path) -> dict:
    command = ["swift", "package", "--package-path", str(package_path), "dump-package"]
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ValidationError(f"swift package dump-package failed for {package_path}: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValidationError(f"invalid SwiftPM JSON for {package_path}: {error}") from error


def local_dependencies(manifest: dict) -> tuple[list[tuple[str, Path]], list[str]]:
    local: list[tuple[str, Path]] = []
    remote: list[str] = []
    for dependency in manifest.get("dependencies", []):
        if not isinstance(dependency, dict):
            remote.append("unknown dependency")
            continue
        if "fileSystem" in dependency:
            payload = dependency["fileSystem"]
            if isinstance(payload, list) and payload:
                path = payload[0].get("path", "")
                resolved = Path(path).resolve()
                local.append((resolved.name, resolved))
            else:
                remote.append("malformed fileSystem dependency")
        else:
            remote.append(next(iter(dependency), "unknown dependency"))
    return sorted(local, key=lambda item: (item[0], str(item[1]))), sorted(remote)


def normalized_products(manifest: dict) -> list[dict]:
    return sorted(
        (
            {
                "name": product.get("name"),
                "type": product_type(product.get("type")),
                "targets": sorted(product.get("targets", [])),
            }
            for product in manifest.get("products", [])
        ),
        key=lambda item: str(item["name"]),
    )


def normalized_targets(manifest: dict) -> list[dict]:
    return sorted(
        (
            {
                "name": target.get("name"),
                "type": target.get("type"),
                "dependencies": sorted(dependency_name(item) for item in target.get("dependencies", [])),
            }
            for target in manifest.get("targets", [])
        ),
        key=lambda item: str(item["name"]),
    )


def cycle_chain(graph: dict[str, list[str]]) -> list[str] | None:
    visited: set[str] = set()
    active: set[str] = set()
    stack: list[str] = []

    def visit(node: str) -> list[str] | None:
        if node in active:
            index = stack.index(node)
            return stack[index:] + [node]
        if node in visited:
            return None
        visited.add(node)
        active.add(node)
        stack.append(node)
        for neighbor in graph.get(node, []):
            if neighbor in graph:
                found = visit(neighbor)
                if found:
                    return found
        stack.pop()
        active.remove(node)
        return None

    for node in sorted(graph):
        found = visit(node)
        if found:
            return found
    return None


def validate_packages(root: Path, config: dict) -> list[str]:
    errors: list[str] = []
    configured = config.get("packages", [])
    configured_names = {item["name"] for item in configured}
    configured_paths = {
        item["name"]: (root / item["path"]).resolve()
        for item in configured
    }
    graph = {item["name"]: sorted(item.get("local_dependencies", [])) for item in configured}
    for name, dependencies in graph.items():
        unknown = sorted(set(dependencies) - configured_names)
        if unknown:
            errors.append(f"package rule: {name} references unconfigured local packages: {', '.join(unknown)}")
    found_cycle = cycle_chain(graph)
    if found_cycle:
        errors.append(f"package cycle rule: {' -> '.join(found_cycle)}")

    for expected in configured:
        package_path = root / expected["path"]
        manifest_path = package_path / "Package.swift"
        if not manifest_path.is_file():
            errors.append(f"package inventory rule: missing {manifest_path.relative_to(root)}")
            continue
        try:
            actual = dump_package(package_path)
        except ValidationError as error:
            errors.append(str(error))
            continue
        if actual.get("name") != expected["name"]:
            errors.append(
                f"package identity rule: {expected['path']} expected {expected['name']}, got {actual.get('name')}"
            )
        actual_local_entries, remote = local_dependencies(actual)
        actual_local = sorted(name for name, _ in actual_local_entries)
        expected_local = sorted(expected.get("local_dependencies", []))
        if remote:
            errors.append(f"remote dependency rule: {expected['name']} declares {', '.join(remote)}")
        if actual_local != expected_local:
            errors.append(
                f"local package edge rule: {expected['name']} expected {expected_local}, got {actual_local}"
            )
        for dependency_name_value, dependency_path in actual_local_entries:
            expected_path = configured_paths.get(dependency_name_value)
            if expected_path is not None and dependency_path != expected_path:
                errors.append(
                    "canonical local package path rule: "
                    f"{expected['name']} dependency {dependency_name_value} expected {expected_path}, "
                    f"got {dependency_path}"
                )
        expected_products = sorted(expected.get("products", []), key=lambda item: item["name"])
        actual_products = normalized_products(actual)
        if actual_products != expected_products:
            errors.append(
                f"product rule: {expected['name']} expected {expected_products}, got {actual_products}"
            )
        expected_targets = sorted(expected.get("targets", []), key=lambda item: item["name"])
        actual_targets = normalized_targets(actual)
        if actual_targets != expected_targets:
            errors.append(
                f"target dependency rule: {expected['name']} expected {expected_targets}, got {actual_targets}"
            )
    return errors


IMPORT_PATTERN = re.compile(
    r"^\s*(?:(?:@testable|@preconcurrency|@_exported|@_implementationOnly|"
    r"@_spi\s*\([^\r\n)]*\))\s+)*"
    r"(?:(?:public|internal|private|fileprivate|package)\s+)?import\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)


def validate_imports(root: Path, config: dict) -> list[str]:
    errors: list[str] = []
    project_modules: set[str] = set()
    for package in config.get("packages", []):
        project_modules.add(package["name"])
        project_modules.update(product["name"] for product in package.get("products", []))
        project_modules.update(target["name"] for target in package.get("targets", []))

    for rule in config.get("import_rules", []):
        forbidden = set(rule.get("forbidden", []))
        prefixes = tuple(rule.get("forbidden_prefixes", []))
        allowed_project = set(rule.get("allowed_project_modules", []))
        for relative_root in rule.get("roots", []):
            source_root = root / relative_root
            if not source_root.exists():
                errors.append(f"import rule {rule['id']}: missing source root {relative_root}")
                continue
            for source in sorted(source_root.rglob("*.swift")):
                for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
                    match = IMPORT_PATTERN.match(line)
                    if not match:
                        continue
                    module = match.group(1)
                    violation = module in forbidden or (prefixes and module.startswith(prefixes))
                    if allowed_project and module in project_modules and module not in allowed_project:
                        violation = True
                    if violation:
                        relative = source.relative_to(root)
                        errors.append(
                            f"{relative}:{line_number}: import rule {rule['id']} forbids module {module}"
                        )
    return errors


def section(text: str, name: str) -> str:
    begin = f"/* Begin {name} section */"
    end = f"/* End {name} section */"
    start = text.find(begin)
    finish = text.find(end)
    if start < 0 or finish < 0 or finish < start:
        raise ValidationError(f"project structure rule: missing {name} section")
    return text[start + len(begin):finish]


OBJECT_START = re.compile(r"^\s*([A-Za-z0-9]+) /\* (.*?) \*/ = \{", re.MULTILINE)


def objects(section_text: str) -> dict[str, tuple[str, str]]:
    result: dict[str, tuple[str, str]] = {}
    for match in OBJECT_START.finditer(section_text):
        depth = 0
        end = None
        for index in range(match.end() - 1, len(section_text)):
            character = section_text[index]
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is not None:
            result[match.group(1)] = (match.group(2), section_text[match.start():end])
    return result


def list_ids(block: str, key: str) -> list[str]:
    match = re.search(rf"\b{re.escape(key)}\s*=\s*\((.*?)\);", block, re.DOTALL)
    if not match:
        return []
    return re.findall(r"^\s*([A-Za-z0-9]+)\s+/\*", match.group(1), re.MULTILINE)


def scalar(block: str, key: str) -> str | None:
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*([^;]+);", block, re.MULTILINE)
    return match.group(1).strip().strip('"') if match else None


def reference_id(block: str, key: str) -> str | None:
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*([A-Za-z0-9]+)\b", block, re.MULTILINE)
    return match.group(1) if match else None


def validate_project(root: Path, config: dict) -> list[str]:
    app = config.get("app")
    if not app:
        return []
    project_path = root / app["project"]
    try:
        text = project_path.read_text(encoding="utf-8")
        native_targets = objects(section(text, "PBXNativeTarget"))
        product_objects = objects(section(text, "XCSwiftPackageProductDependency"))
        package_objects = objects(section(text, "XCLocalSwiftPackageReference"))
    except (OSError, ValidationError) as error:
        return [str(error)]

    errors: list[str] = []
    remote_marker = "/* Begin XCRemoteSwiftPackageReference section */"
    if remote_marker in text:
        try:
            remote_objects = objects(section(text, "XCRemoteSwiftPackageReference"))
        except ValidationError as error:
            errors.append(str(error))
        else:
            if remote_objects:
                names = sorted(name for name, _ in remote_objects.values())
                errors.append(f"App remote package rule: XCRemoteSwiftPackageReference is forbidden: {names}")

    product_names = {identifier: scalar(block, "productName") for identifier, (_, block) in product_objects.items()}
    product_package_ids = {
        identifier: reference_id(block, "package")
        for identifier, (_, block) in product_objects.items()
    }
    local_package_paths = {
        identifier: scalar(block, "relativePath")
        for identifier, (_, block) in package_objects.items()
    }
    configured_owners: dict[str, set[str]] = {}
    for package in config.get("packages", []):
        for product in package.get("products", []):
            configured_owners.setdefault(product["name"], set()).add(package["path"])
    target_by_name: dict[str, str] = {}
    for _, (_, block) in native_targets.items():
        name = scalar(block, "name")
        if name:
            target_by_name[name] = block
    for target_name, block in sorted(target_by_name.items()):
        for product_identifier in list_ids(block, "packageProductDependencies"):
            product_name = product_names.get(product_identifier)
            package_identifier = product_package_ids.get(product_identifier)
            actual_owner = local_package_paths.get(package_identifier or "")
            expected_owners = configured_owners.get(product_name or "", set())
            if actual_owner not in expected_owners:
                errors.append(
                    "App product ownership rule: "
                    f"{target_name} product {product_name or product_identifier} expected local owner "
                    f"{sorted(expected_owners)}, got {actual_owner or package_identifier or '<missing>'}"
                )
    for expected in app.get("targets", []):
        block = target_by_name.get(expected["name"])
        if block is None:
            errors.append(f"App link rule: missing PBXNativeTarget {expected['name']}")
            continue
        actual = sorted(
            product_names.get(identifier) or f"<unknown:{identifier}>"
            for identifier in list_ids(block, "packageProductDependencies")
        )
        wanted = sorted(expected.get("package_products", []))
        if actual != wanted:
            errors.append(f"App link rule: {expected['name']} expected products {wanted}, got {actual}")

    actual_paths = sorted(
        path
        for _, block in package_objects.values()
        if (path := scalar(block, "relativePath")) is not None
    )
    expected_paths = sorted(app.get("local_package_paths", []))
    if actual_paths != expected_paths:
        errors.append(f"App local package rule: expected {expected_paths}, got {actual_paths}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", type=Path)
    parser.add_argument("--config", type=Path)
    arguments = parser.parse_args()
    script_root = Path(__file__).resolve().parent.parent
    root = (arguments.repository_root or script_root).resolve()
    config_path = (arguments.config or root / "config/architecture-boundaries.json").resolve()
    try:
        config = load_json(config_path)
        errors = validate_packages(root, config)
        errors.extend(validate_imports(root, config))
        errors.extend(validate_project(root, config))
    except ValidationError as error:
        errors = [str(error)]
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        print(f"Architecture boundary check failed ({len(errors)} violation(s)).", file=sys.stderr)
        return 1
    print(f"Architecture boundary check passed ({len(config.get('packages', []))} packages).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
