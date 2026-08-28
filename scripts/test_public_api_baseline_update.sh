#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/private/tmp}/single-green-api-updater-tests.XXXXXX")
trap 'find "$temporary_root" -depth -delete' EXIT HUP INT TERM

python3 - "$script_directory/update_public_api_baselines.sh" "$temporary_root" <<'PY'
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys

updater = Path(sys.argv[1])
root = Path(sys.argv[2])

def fixture(name: str, version: str) -> Path:
    target = root / name
    (target / "scripts").mkdir(parents=True)
    (target / "config").mkdir()
    shutil.copy2(updater, target / "scripts/update_public_api_baselines.sh")
    (target / "config/toolchain.json").write_text(
        json.dumps({"api_baseline_version": version}) + "\n"
    )
    checker = target / "scripts/check_public_api_baselines.sh"
    checker.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        "[ \"${1:-}\" = \"--emit-current\" ]\n"
        "mkdir -p \"$2/macos-arm64\" \"$2/ios-simulator-arm64\"\n"
        "printf 'new\\n' >\"$2/new-sentinel\"\n"
    )
    checker.chmod(0o755)
    return target

def run(target: Path, **extra_environment: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.pop("CI", None)
    environment.update(extra_environment)
    return subprocess.run(
        [str(target / "scripts/update_public_api_baselines.sh"), "--accept-current-api"],
        cwd=target,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

for index, value in enumerate(("", ".", "..", "../escape", "nested/value", "/absolute")):
    target = fixture(f"invalid-{index}", value)
    result = run(target)
    if result.returncode == 0 or "safe non-dot slug" not in result.stderr:
        raise SystemExit(f"unsafe API baseline version was not rejected: {value!r}\n{result.stderr}")

outside = root / "outside-parent"
outside.mkdir()
symlinked = fixture("symlinked-parent", "fixture")
(symlinked / "api-baselines").symlink_to(outside, target_is_directory=True)
result = run(symlinked)
if result.returncode == 0 or "canonical API baseline parent" not in result.stderr:
    raise SystemExit(f"symlinked API baseline parent was not rejected\n{result.stderr}")

rollback = fixture("rollback", "fixture")
old = rollback / "api-baselines/fixture"
old.mkdir(parents=True)
(old / "old-sentinel").write_text("old\n")
result = run(rollback, SINGLE_GREEN_TEST_SIMULATE_API_REPLACEMENT_FAILURE="1")
if result.returncode == 0 or "prior baseline was restored" not in result.stderr:
    raise SystemExit(f"simulated replacement failure was not reported\n{result.stderr}")
if (old / "old-sentinel").read_text() != "old\n":
    raise SystemExit("simulated replacement failure did not preserve the old baseline")
if (old / "new-sentinel").exists():
    raise SystemExit("failed replacement leaked the staged baseline into the destination")
leftovers = [path.name for path in (rollback / "api-baselines").iterdir() if path.name.startswith(".")]
if leftovers:
    raise SystemExit(f"updater left staging or rollback artifacts: {leftovers}")

success = fixture("success", "fixture")
old = success / "api-baselines/fixture"
old.mkdir(parents=True)
(old / "old-sentinel").write_text("old\n")
result = run(success)
if result.returncode != 0:
    raise SystemExit(f"valid atomic replacement failed\n{result.stderr}")
if not (old / "new-sentinel").is_file() or (old / "old-sentinel").exists():
    raise SystemExit("valid replacement did not atomically publish the staged baseline")

print("Public API updater safety tests passed (slug, canonical parent, rollback, success).")
PY
