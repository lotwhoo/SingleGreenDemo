#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=${BUILD_DOCUMENTATION_ROOT:-$(CDPATH= cd -- "$script_dir/.." && pwd)}
project_path=${BUILD_DOCUMENTATION_PROJECT_PATH:-$repository_root/SingleGreenDemo.xcodeproj}
project_list_fixture=${BUILD_DOCUMENTATION_XCODE_LIST_FIXTURE:-}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/single-green-build-docs.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

project_list_json=$temporary_root/project-list.json

if [ -n "$project_list_fixture" ]; then
    if [ ! -f "$project_list_fixture" ]; then
        printf '%s\n' "Build documentation check failed: Xcode list fixture not found: $project_list_fixture" >&2
        exit 1
    fi
    cp "$project_list_fixture" "$project_list_json"
else
    if [ ! -d "$project_path" ]; then
        printf '%s\n' "Build documentation check failed: Xcode project not found: $project_path" >&2
        exit 1
    fi
    if ! command -v xcodebuild >/dev/null 2>&1; then
        printf '%s\n' 'Build documentation check failed: xcodebuild is unavailable.' >&2
        exit 1
    fi
    if ! xcodebuild -project "$project_path" -list -json > "$project_list_json"; then
        printf '%s\n' 'Build documentation check failed: xcodebuild could not list the project.' >&2
        exit 1
    fi
fi

if command -v plutil >/dev/null 2>&1; then
    plutil_command=$(command -v plutil)
else
    printf '%s\n' 'Build documentation check failed: plutil is unavailable.' >&2
    exit 1
fi

schemes_xml=$temporary_root/schemes.plist
configurations_xml=$temporary_root/configurations.plist

if ! "$plutil_command" -extract project.schemes xml1 -o "$schemes_xml" "$project_list_json" >/dev/null 2>&1; then
    printf '%s\n' 'Build documentation check failed: Xcode project list has no scheme array.' >&2
    exit 1
fi
if ! "$plutil_command" -extract project.configurations xml1 -o "$configurations_xml" "$project_list_json" >/dev/null 2>&1; then
    printf '%s\n' 'Build documentation check failed: Xcode project list has no configuration array.' >&2
    exit 1
fi

check_xml_array_item() {
    array_file=$1
    expected_item=$2
    item_kind=$3

    if ! grep -F "<string>$expected_item</string>" "$array_file" >/dev/null 2>&1; then
        printf '%s\n' "Build documentation check failed: required $item_kind '$expected_item' is missing from the Xcode project list." >&2
        return 1
    fi
}

project_list_failed=0
check_xml_array_item "$schemes_xml" SingleGreenUser scheme || project_list_failed=1
check_xml_array_item "$schemes_xml" SingleGreenInternal scheme || project_list_failed=1

configuration_count=$("$plutil_command" -extract project.configurations raw -o - "$project_list_json" 2>/dev/null || printf '%s' invalid)
if [ "$configuration_count" != 4 ]; then
    printf '%s\n' "Build documentation check failed: expected exactly 4 Xcode configurations, found '$configuration_count'." >&2
    project_list_failed=1
fi

for configuration in User-Debug User-Release Internal-Debug Internal-Release; do
    check_xml_array_item "$configurations_xml" "$configuration" configuration || project_list_failed=1
done

if [ "$project_list_failed" -ne 0 ]; then
    exit 1
fi

documentation_files='AGENTS.md
README.md
docs/STREAMING_MODULES_UPGRADE_GUIDE.md
docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md'

documentation_failed=0
for relative_path in $documentation_files; do
    document_path=$repository_root/$relative_path
    if [ ! -f "$document_path" ]; then
        printf '%s\n' "Build documentation check failed: required document is missing: $relative_path" >&2
        documentation_failed=1
        continue
    fi

    if ! awk -v document_name="$relative_path" '
        /^[[:space:]]*```/ {
            if (inside_fence) {
                inside_fence = 0
                runnable_fence = 0
                next
            }

            fence_label = $0
            sub(/^[[:space:]]*```[[:space:]]*/, "", fence_label)
            sub(/[[:space:]].*$/, "", fence_label)
            inside_fence = 1
            runnable_fence = (fence_label == "" || fence_label == "bash" || fence_label == "sh" || fence_label == "shell" || fence_label == "zsh")
            next
        }

        inside_fence && runnable_fence {
            stale_scheme = ($0 ~ /(^|[[:space:]])-scheme[[:space:]]+["\047]?SingleGreenDemo["\047]?([[:space:]]|$)/)
            stale_configuration = ($0 ~ /(^|[[:space:]])-configuration[[:space:]]+["\047]?(Debug|Release)["\047]?([[:space:]]|$)/)

            if (stale_scheme) {
                printf "%s:%d: stale runnable command uses nonexistent scheme SingleGreenDemo\n", document_name, FNR > "/dev/stderr"
                failed = 1
            }
            if (stale_configuration) {
                printf "%s:%d: stale runnable command uses bare Debug/Release configuration\n", document_name, FNR > "/dev/stderr"
                failed = 1
            }
        }

        END {
            exit failed
        }
    ' "$document_path"; then
        documentation_failed=1
    fi
done

if [ "$documentation_failed" -ne 0 ]; then
    printf '%s\n' 'Build documentation check failed: replace current runnable commands with SingleGreenUser/SingleGreenInternal and the four named configurations.' >&2
    exit 1
fi

printf '%s\n' 'Build documentation check passed: Xcode variants and current runnable documentation agree.'
