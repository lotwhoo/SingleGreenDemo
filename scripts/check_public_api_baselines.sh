#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
architecture_config="$repository_root/config/architecture-boundaries.json"
toolchain_config="$repository_root/config/toolchain.json"

"$script_directory/check_toolchain.sh" "$toolchain_config"

baseline_version=$(python3 - "$toolchain_config" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream).get("api_baseline_version")
if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) or value in {".", ".."}:
    raise SystemExit("error: api_baseline_version must be one safe non-dot slug")
print(value)
PY
)
baseline_root="$repository_root/api-baselines/$baseline_version"
emit_root=
inventory_only=0
validate_snapshot_inventory=1
if [ "${1:-}" = "--emit-current" ]; then
    if [ "$#" -ne 2 ]; then
        echo "usage: $0 --emit-current OUTPUT_DIRECTORY" >&2
        exit 2
    fi
    emit_root=$2
    validate_snapshot_inventory=0
elif [ "${1:-}" = "--validate-inventory-only" ]; then
    if [ "$#" -ne 1 ]; then
        echo "usage: $0 --validate-inventory-only" >&2
        exit 2
    fi
    inventory_only=1
elif [ "$#" -ne 0 ]; then
    echo "usage: $0 [--emit-current OUTPUT_DIRECTORY|--validate-inventory-only]" >&2
    exit 2
fi

temporary_root=$(mktemp -d "${TMPDIR:-/private/tmp}/single-green-api-check.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

module_inventory="$temporary_root/modules.tsv"
python3 - "$architecture_config" "$baseline_root" "$validate_snapshot_inventory" >"$module_inventory" <<'PY'
from collections import Counter
from pathlib import Path
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)
baseline_root = Path(sys.argv[2])
validate_snapshots = sys.argv[3] == "1"

library_products = {
    (package["name"], product["name"])
    for package in config.get("packages", [])
    for product in package.get("products", [])
    if product.get("type") == "library"
}
mappings = config.get("public_api_modules", [])
mapped_products = [
    (item.get("package"), item.get("product", item.get("module")))
    for item in mappings
]
mapping_counts = Counter(mapped_products)
duplicate_products = sorted(item for item, count in mapping_counts.items() if count != 1)
unknown_products = sorted(set(mapped_products) - library_products)
missing_products = sorted(library_products - set(mapped_products))
module_counts = Counter(item.get("module") for item in mappings)
duplicate_modules = sorted(str(item) for item, count in module_counts.items() if count != 1)
if duplicate_products or unknown_products or missing_products or duplicate_modules:
    if duplicate_products:
        print(f"error: duplicate public API product mappings: {duplicate_products}", file=sys.stderr)
    if duplicate_modules:
        print(f"error: duplicate public API module mappings: {duplicate_modules}", file=sys.stderr)
    if unknown_products:
        print(f"error: unknown public API product mappings: {unknown_products}", file=sys.stderr)
    if missing_products:
        print(f"error: missing public API product mappings: {missing_products}", file=sys.stderr)
    raise SystemExit(1)

if validate_snapshots:
    if not baseline_root.is_dir():
        print(f"error: public API baseline is missing: {baseline_root}", file=sys.stderr)
        raise SystemExit(1)
    platforms = ("macos-arm64", "ios-simulator-arm64")
    expected = {
        f"{platform}/{item['module']}.json"
        for platform in platforms
        for item in mappings
    }
    actual = {
        str(path.relative_to(baseline_root))
        for path in baseline_root.rglob("*.json")
    }
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing:
        print(f"error: missing public API snapshot files: {missing}", file=sys.stderr)
    if unexpected:
        print(f"error: unexpected public API snapshot files: {unexpected}", file=sys.stderr)
    if missing or unexpected:
        raise SystemExit(1)

for item in mappings:
    maps = ";".join(item.get("clang_modulemaps", []))
    print(f"{item['module']}\t{item['package']}\t{maps}")
PY
module_count=$(wc -l <"$module_inventory" | tr -d ' ')

if [ "$inventory_only" -eq 1 ]; then
    echo "Public API inventory check passed (complete library mapping and exact snapshot set)."
    exit 0
fi

canonicalize_snapshot() {
    input_path=$1
    output_path=$2
    python3 "$script_directory/canonicalize_api_snapshot.py" \
        "$input_path" "$output_path" \
        --repository-root "$repository_root" \
        --temporary-root "$temporary_root"
}

generate_platform() {
    platform_name=$1
    sdk_name=$2
    target_triple=$3
    build_component=$4
    destination_root=$5
    sdk_path=$(xcrun --sdk "$sdk_name" --show-sdk-path)
    mkdir -p "$destination_root/$platform_name"

    while IFS="$(printf '\t')" read -r module package modulemaps; do
        scratch_path="$temporary_root/build/$platform_name/$package"
        marker="$scratch_path/.single-green-built-$module"
        if [ ! -f "$marker" ]; then
            swift build \
                --package-path "$repository_root/Packages/$package" \
                --scratch-path "$scratch_path" \
                --target "$module" \
                --triple "$target_triple" \
                --sdk "$sdk_path"
            touch "$marker"
        fi
        product_root="$scratch_path/$build_component/debug"
        module_root="$product_root/Modules"
        raw_snapshot="$temporary_root/$platform_name-$module.raw.json"
        set -- xcrun swift-api-digester \
            -dump-sdk -module "$module" -o "$raw_snapshot" \
            -avoid-location -avoid-tool-args -swift-only -abort-on-module-fail \
            -I "$module_root" -I "$product_root" \
            -sdk "$sdk_path" -target "$target_triple"
        if [ -n "$modulemaps" ]; then
            old_ifs=$IFS
            IFS=';'
            for modulemap in $modulemaps; do
                set -- "$@" -Xcc "-fmodule-map-file=$product_root/$modulemap"
            done
            IFS=$old_ifs
        fi
        "$@"
        canonicalize_snapshot "$raw_snapshot" "$destination_root/$platform_name/$module.json"
    done <"$module_inventory"
}

current_root="$temporary_root/current"
generate_platform macos-arm64 macosx arm64-apple-macosx14.0 arm64-apple-macosx "$current_root"
generate_platform ios-simulator-arm64 iphonesimulator arm64-apple-ios18.0-simulator arm64-apple-ios-simulator "$current_root"

if [ -n "$emit_root" ]; then
    mkdir -p "$emit_root"
    cp -R "$current_root/." "$emit_root/"
    echo "Current public API snapshots generated at $emit_root"
    exit 0
fi

failed=0
for platform_name in macos-arm64 ios-simulator-arm64; do
    while IFS="$(printf '\t')" read -r module package modulemaps; do
        baseline="$baseline_root/$platform_name/$module.json"
        current="$current_root/$platform_name/$module.json"
        if [ ! -f "$baseline" ]; then
            echo "error: missing public API baseline: ${baseline#"$repository_root/"}" >&2
            failed=1
            continue
        fi
        if ! cmp -s "$baseline" "$current"; then
            echo "error: public API snapshot changed: $module ($platform_name)" >&2
            diagnosis="$temporary_root/diagnosis-$platform_name-$module.txt"
            scratch_path="$temporary_root/build/$platform_name/$package"
            case "$platform_name" in
                macos-arm64)
                    sdk_name=macosx
                    target_triple=arm64-apple-macosx14.0
                    build_component=arm64-apple-macosx
                    ;;
                ios-simulator-arm64)
                    sdk_name=iphonesimulator
                    target_triple=arm64-apple-ios18.0-simulator
                    build_component=arm64-apple-ios-simulator
                    ;;
            esac
            sdk_path=$(xcrun --sdk "$sdk_name" --show-sdk-path)
            product_root="$scratch_path/$build_component/debug"
            module_root="$product_root/Modules"
            set -- xcrun swift-api-digester -diagnose-sdk \
                -baseline-path "$baseline" -module "$module" \
                -avoid-location -avoid-tool-args -swift-only -abort-on-module-fail \
                -I "$module_root" -I "$product_root" \
                -sdk "$sdk_path" -target "$target_triple" -o "$diagnosis"
            if [ -n "$modulemaps" ]; then
                old_ifs=$IFS
                IFS=';'
                for modulemap in $modulemaps; do
                    set -- "$@" -Xcc "-fmodule-map-file=$product_root/$modulemap"
                done
                IFS=$old_ifs
            fi
            if "$@" >/dev/null 2>&1; then
                if [ -s "$diagnosis" ]; then
                    sed -n '1,160p' "$diagnosis" >&2
                else
                    echo "Exact snapshot comparison detected an addition or metadata change." >&2
                fi
            else
                echo "swift-api-digester could not render a semantic diagnosis; exact comparison still failed." >&2
            fi
            failed=1
        fi
    done <"$module_inventory"
done

if [ "$failed" -ne 0 ]; then
    echo "Review the API change, then explicitly update the snapshots if it is intentional." >&2
    exit 1
fi

echo "Public API baseline check passed ($module_count library modules, macOS arm64 and iOS Simulator arm64)."
