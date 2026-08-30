#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
Usage: scripts/collect_refactor_baseline.sh [--repo-root PATH] [--output PATH]

Writes a metadata-only Markdown refactor baseline. When --output is omitted, the
report is written to a temporary file outside the repository.
EOF
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
output_path=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo-root)
            [ "$#" -ge 2 ] || { echo "error: --repo-root requires a path" >&2; exit 2; }
            repository_root=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { echo "error: --output requires a path" >&2; exit 2; }
            output_path=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

repository_root=$(CDPATH= cd -- "$repository_root" && pwd)
if ! git -C "$repository_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: repository root is not a Git worktree: $repository_root" >&2
    exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/single-green-baseline.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

if [ -z "$output_path" ]; then
    output_path=$(mktemp "${TMPDIR:-/tmp}/single-green-refactor-baseline.XXXXXX")
else
    output_parent=$(dirname -- "$output_path")
    if [ ! -d "$output_parent" ]; then
        echo "error: output directory does not exist: $output_parent" >&2
        exit 1
    fi
fi

tracked_swift="$temporary_directory/tracked-swift.txt"
inventory="$temporary_directory/swift-inventory.txt"
packages="$temporary_directory/packages.txt"
configurations="$temporary_directory/configurations.txt"
schemes="$temporary_directory/schemes.txt"
relevant_files="$temporary_directory/relevant-files.txt"
: > "$inventory"
: > "$packages"
: > "$configurations"
: > "$schemes"
: > "$relevant_files"

git -C "$repository_root" -c core.quotepath=false ls-files '*.swift' \
    | LC_ALL=C sort \
    | awk '
        /(^|\/)(\.build|DerivedData|build|\.coverage)(\/|$)/ { next }
        /(^|\/)Package\.swift$/ { next }
        { print }
    ' > "$tracked_swift"

while IFS= read -r relative_path; do
    [ -n "$relative_path" ] || continue
    absolute_path="$repository_root/$relative_path"
    [ -f "$absolute_path" ] || continue
    line_count=$(wc -l < "$absolute_path" | tr -d ' ')
    case "/$relative_path" in
        */Tests/*|*/SingleGreenDemoTests/*|*Tests.swift)
            classification=test
            ;;
        *)
            classification=production
            ;;
    esac
    printf '%s|%s|%s\n' "$classification" "$line_count" "$relative_path" >> "$inventory"
done < "$tracked_swift"

if [ -d "$repository_root/Packages" ]; then
    find "$repository_root/Packages" -mindepth 2 -maxdepth 2 -type f -name Package.swift \
        | while IFS= read -r manifest; do basename "$(dirname "$manifest")"; done \
        | LC_ALL=C sort -u > "$packages"
fi

project_path=$(find "$repository_root" -maxdepth 2 -type d -name '*.xcodeproj' \
    ! -path '*/.build/*' ! -path '*/DerivedData/*' | LC_ALL=C sort | sed -n '1p')
configuration_source="project file"
scheme_source="tracked shared schemes"

if [ -n "$project_path" ] && command -v xcodebuild >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    xcodebuild_json="$temporary_directory/xcodebuild-list.json"
    if xcodebuild -project "$project_path" -list -json > "$xcodebuild_json" 2>/dev/null; then
        parsed_configurations="$temporary_directory/parsed-configurations.txt"
        parsed_schemes="$temporary_directory/parsed-schemes.txt"
        if python3 - "$xcodebuild_json" "$parsed_configurations" "$parsed_schemes" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
project = payload.get("project", {})
if not isinstance(project, dict):
    raise ValueError("project metadata must be an object")
configurations = project.get("configurations", [])
schemes = project.get("schemes", [])
if not isinstance(configurations, list) or not all(isinstance(value, str) for value in configurations):
    raise ValueError("configurations metadata must be a string list")
if not isinstance(schemes, list) or not all(isinstance(value, str) for value in schemes):
    raise ValueError("schemes metadata must be a string list")
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    for value in sorted(set(configurations)):
        stream.write(f"{value}\n")
with open(sys.argv[3], "w", encoding="utf-8") as stream:
    for value in sorted(set(schemes)):
        stream.write(f"{value}\n")
PY
        then
            if [ -s "$parsed_configurations" ]; then
                cp "$parsed_configurations" "$configurations"
                configuration_source="xcodebuild -list"
            fi
            if [ -s "$parsed_schemes" ]; then
                cp "$parsed_schemes" "$schemes"
                scheme_source="xcodebuild -list"
            fi
        fi
    fi
fi

if [ ! -s "$configurations" ] && [ -n "$project_path" ] && [ -f "$project_path/project.pbxproj" ]; then
    awk '
        /\/\* Begin XCBuildConfiguration section \*\// { in_section = 1; next }
        /\/\* End XCBuildConfiguration section \*\// { in_section = 0 }
        in_section && /^[[:space:]]*name = / {
            value = $0
            sub(/^[[:space:]]*name = /, "", value)
            sub(/;[[:space:]]*$/, "", value)
            gsub(/^"|"$/, "", value)
            print value
        }
    ' "$project_path/project.pbxproj" | LC_ALL=C sort -u > "$configurations"
fi

if [ ! -s "$schemes" ]; then
    git -C "$repository_root" -c core.quotepath=false ls-files '*.xcscheme' \
        | while IFS= read -r scheme; do basename "$scheme" .xcscheme; done \
        | LC_ALL=C sort -u > "$schemes"
fi

git -C "$repository_root" -c core.quotepath=false ls-files \
    | awk '
        /(^|\/)Package\.swift$/ ||
        /(^|\/)Package\.resolved$/ ||
        /\.xcodeproj\/project\.pbxproj$/ ||
        /\.xcworkspace\/contents\.xcworkspacedata$/ ||
        /\.xcscheme$/ ||
        /\.xcconfig$/ ||
        /^config\/.*\.json$/ ||
        /^\.github\/workflows\/.*\.ya?ml$/ { print }
    ' | LC_ALL=C sort > "$relevant_files"

revision=$(git -C "$repository_root" rev-parse HEAD)
branch=$(git -C "$repository_root" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s' detached)
change_count=$(git -C "$repository_root" status --porcelain=v1 | wc -l | tr -d ' ')
if [ "$change_count" -eq 0 ]; then
    cleanliness=clean
else
    cleanliness="dirty ($change_count change entries)"
fi
timestamp=${BASELINE_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}

production_files=$(awk -F '|' '$1 == "production" { count += 1 } END { print count + 0 }' "$inventory")
production_lines=$(awk -F '|' '$1 == "production" { count += $2 } END { print count + 0 }' "$inventory")
test_files=$(awk -F '|' '$1 == "test" { count += 1 } END { print count + 0 }' "$inventory")
test_lines=$(awk -F '|' '$1 == "test" { count += $2 } END { print count + 0 }' "$inventory")
package_count=$(wc -l < "$packages" | tr -d ' ')

{
    echo "# Refactor Baseline Snapshot"
    echo
    echo "Generated at: \`$timestamp\`"
    echo
    echo "This report structurally inspects tracked source files for line counts and project.pbxproj for configuration names. It emits repository metadata, file names, counts, configuration names, and scheme names only. It does not inspect or emit environment variables, credential stores, credential/configuration values, or provider and user payloads."
    echo
    echo "## Repository"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Revision | \`$revision\` |"
    echo "| Branch | \`$branch\` |"
    echo "| Working tree | $cleanliness |"
    echo
    echo "## Tracked Swift inventory"
    echo
    echo "Generated/build directories and package manifests are excluded. Test files are classified by test directory or \`Tests.swift\` suffix."
    echo
    echo "| Classification | Files | Lines |"
    echo "|---|---:|---:|"
    echo "| Production | $production_files | $production_lines |"
    echo "| Test | $test_files | $test_lines |"
    echo
    echo "### Largest production Swift files"
    echo
    echo "| Lines | Path |"
    echo "|---:|---|"
    awk -F '|' '$1 == "production" { print }' "$inventory" \
        | LC_ALL=C sort -t '|' -k2,2nr -k3,3 \
        | sed -n '1,15p' \
        | awk -F '|' '{ printf "| %s | `%s` |\n", $2, $3 }'
    echo
    echo "## Local package inventory ($package_count)"
    echo
    if [ -s "$packages" ]; then
        sed 's/^/- `Packages\//; s/$/`/' "$packages"
    else
        echo "- None discovered."
    fi
    echo
    echo "## Xcode build configurations"
    echo
    echo "Discovery: $configuration_source."
    echo
    if [ -s "$configurations" ]; then
        sed 's/^/- `/; s/$/`/' "$configurations"
    else
        echo "- None discovered."
    fi
    echo
    echo "## Xcode schemes"
    echo
    echo "Discovery: $scheme_source."
    echo
    if [ -s "$schemes" ]; then
        sed 's/^/- `/; s/$/`/' "$schemes"
    else
        echo "- None discovered."
    fi
    echo
    echo "## Relevant tracked project and configuration files"
    echo
    if [ -s "$relevant_files" ]; then
        sed 's/^/- `/; s/$/`/' "$relevant_files"
    else
        echo "- None discovered."
    fi
} > "$output_path"

echo "Baseline report written to: $output_path"
