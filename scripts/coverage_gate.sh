#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
output_directory=${1:-"$repository_root/.coverage"}
if [ "$#" -gt 0 ]; then
    shift
fi

# Thresholds are deliberately below the reviewed 2026-08-28 local baselines.
# They protect against large regressions without pretending that line coverage is
# a release-quality substitute for the deterministic streaming test matrix.
# Only package production files under Sources/ are aggregated. Tools/ASRCLI is
# intentionally excluded and is enforced by a separate strict build gate.
package_thresholds='StreamingTextKit:70 VoiceChatDomain:75 VoiceActivityDetectionKit:80 SingleGreenGlassesKit:65 SingleGreenConversationAdapters:70 LLMKit:60 VoiceChatCore:55'
packages=$package_thresholds

coverage_source_targets() {
    case "$1" in
        LLMKit)
            # M13 splits provider-neutral cores and provider adapters into
            # separate library targets while retaining LLMKit as a compatibility
            # product. Measure the complete reviewed library surface.
            printf '%s\n' 'LLMCore AgentCore OpenAICompatibleTransport BochaSearchAdapter LLMKit'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# Optional package arguments let pull-request CI measure only directly affected
# packages. With no package arguments the historical full-gate behavior is
# preserved. Validate the complete selection before starting expensive builds.
if [ "$#" -gt 0 ]; then
    packages=
    selected_names=' '
    for requested_package in "$@"; do
        case "$selected_names" in
            *" $requested_package "*)
                echo "error: duplicate coverage package: $requested_package" >&2
                exit 2
                ;;
        esac

        requested_entry=
        for candidate_entry in $package_thresholds; do
            candidate_package=${candidate_entry%%:*}
            if [ "$candidate_package" = "$requested_package" ]; then
                requested_entry=$candidate_entry
                break
            fi
        done
        if [ -z "$requested_entry" ]; then
            echo "error: unknown coverage package: $requested_package" >&2
            exit 2
        fi
        packages="$packages $requested_entry"
        selected_names="$selected_names$requested_package "
    done
fi

mkdir -p "$output_directory"
summary="$output_directory/summary.tsv"
printf 'package\tline_coverage_percent\tthreshold_percent\n' > "$summary"
printf '%s\n' 'Scope: package Sources/ only; Tools/ASRCLI is covered by a separate strict build gate.'

for entry in $packages; do
    package=${entry%%:*}
    threshold=${entry##*:}
    package_path="$repository_root/Packages/$package"
    build_path="$output_directory/$package-build"

    echo "==> Coverage: $package"
    swift test --package-path "$package_path" --build-path "$build_path" --enable-code-coverage
    export_path=$(swift test --package-path "$package_path" --build-path "$build_path" --show-codecov-path)
    if [ ! -f "$export_path" ]; then
        echo "error: unable to locate coverage export for $package" >&2
        exit 1
    fi

    report="$output_directory/$package.txt"
    source_targets=$(coverage_source_targets "$package")
    percent=$(python3 "$script_directory/summarize_package_coverage.py" \
        "$export_path" "$package_path" "$report" $source_targets)
    if [ -z "$percent" ]; then
        echo "error: unable to parse line coverage for $package" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\n' "$package" "$percent" "$threshold" >> "$summary"
    awk -v actual="$percent" -v minimum="$threshold" 'BEGIN { exit !(actual + 0 >= minimum + 0) }' || {
        echo "error: $package line coverage $percent% is below $threshold%" >&2
        exit 1
    }
done

cat "$summary"
