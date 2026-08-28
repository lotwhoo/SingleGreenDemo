#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
output_directory=${1:-"$repository_root/.coverage"}
mkdir -p "$output_directory"

# Thresholds are deliberately below the reviewed 2026-08-28 local baselines.
# They protect against large regressions without pretending that line coverage is
# a release-quality substitute for the deterministic streaming test matrix.
# Only package production files under Sources/ are aggregated. Tools/ASRCLI is
# intentionally excluded and is enforced by a separate strict build gate.
packages='StreamingTextKit:70 VoiceChatDomain:75 VoiceActivityDetectionKit:80 SingleGreenGlassesKit:65 LLMKit:60 VoiceChatCore:55'
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
    percent=$(python3 "$script_directory/summarize_package_coverage.py" \
        "$export_path" "$package_path" "$report")
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
