#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 EVIDENCE.json" >&2
    exit 64
fi

python3 - "$1" <<'PY'
import json
from datetime import datetime
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)

required = {
    "schemaVersion", "version", "commit", "generatedAt", "workingTreeDirty",
    "automated", "manual", "residualRisks"
}
if type(document) is not dict:
    raise SystemExit("document must be an object")
if set(document) != required:
    raise SystemExit(f"invalid root fields: {sorted(document)}")
if type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1:
    raise SystemExit("unsupported schemaVersion")
if type(document["version"]) is not str or not document["version"]:
    raise SystemExit("version must be a non-empty string")
if type(document["commit"]) is not str or not re.fullmatch(r"[0-9a-f]{40}", document["commit"]):
    raise SystemExit("commit must be a full SHA-1")
generated_at = document["generatedAt"]
if type(generated_at) is not str or not re.fullmatch(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",
    generated_at,
):
    raise SystemExit("generatedAt must be an RFC 3339 date-time")
try:
    parsed_generated_at = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
except ValueError as error:
    raise SystemExit("generatedAt must be a valid date-time") from error
if parsed_generated_at.tzinfo is None:
    raise SystemExit("generatedAt must include a time-zone offset")
if type(document["workingTreeDirty"]) is not bool:
    raise SystemExit("workingTreeDirty must be a boolean")
allowed = {"not_run", "passed", "failed", "blocked"}
expected_checks = {
    "automated": {"packageStrictGate", "asrCLIPrivacyBuild", "appSimulatorTests", "releaseSimulatorBuild", "coverageGate", "secretScan"},
    "manual": {"physicalDevice", "realServices", "accessibility", "opticalCalibration"},
}
for section, expected in expected_checks.items():
    if type(document[section]) is not dict:
        raise SystemExit(f"{section} must be an object")
    if set(document[section]) != expected:
        raise SystemExit(f"invalid {section} fields: {sorted(document[section])}")
    for name, status in document[section].items():
        if type(status) is not str or status not in allowed:
            raise SystemExit(f"invalid {section}.{name}: {status}")
if type(document["residualRisks"]) is not list:
    raise SystemExit("residualRisks must be an array")
if any(type(risk) is not str for risk in document["residualRisks"]):
    raise SystemExit("residualRisks items must be strings")
print(f"Release evidence is structurally valid: {path}")
PY
