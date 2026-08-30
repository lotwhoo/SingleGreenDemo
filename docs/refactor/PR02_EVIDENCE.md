# PR-02 implementation and evidence

Date: 2026-08-30

## Scope

PR-02 implemented the two-product build matrix in one Xcode App target:

- `SingleGreenUser`: `User-Debug`, `User-Release`, bundle
  `com.local.SingleGreenDemo`, display name `单绿测试平台`.
- `SingleGreenInternal`: `Internal-Debug`, `Internal-Release`, bundle
  `com.local.SingleGreenDemo.internal`, display name `单绿内部版`.
- Internal configurations define `INTERNAL_DIAGNOSTICS` and
  `INTERNAL_DEMO_CREDENTIALS`; User configurations define neither.
- The reviewed capability resource is
  `SingleGreenDemo/SingleGreenInternalCapabilities.txt`. User artifacts
  exclude it; Internal artifacts contain the exact marker
  `diagnostics-demo-credentials-v1` plus a newline.
- Provider-neutral telemetry contracts remain unconditional. User composition
  injects `NoopConversationTelemetry`; internal storage/export UI and demo
  credentials remain capability-gated.

`docs/refactor/BASELINE.md` remains the historical PR-01 baseline and is not
rewritten by this record.

## Automated evidence

Evidence was produced from the current working tree before commit or push:

| Check | Result | Evidence |
| --- | --- | --- |
| Swift Package strict concurrency/WAE | 515/515 passed | `/private/tmp/SingleGreenDemo-PR02-Strict.SUhlVE/strict.log` |
| User App XCTest | 83/83 passed, 0 failed/skipped | `/private/tmp/SingleGreenDemo-PR02-UserTests.KabSss/UserTests.xcresult` |
| Internal App XCTest | 92/92 passed, 0 failed/skipped | `/private/tmp/SingleGreenDemo-PR02-InternalTests.qFwFTQ/InternalTests.xcresult` |
| Four simulator builds | 4/4 passed | `/private/tmp/SingleGreenDemo-PR02-Artifacts-Final.186uog` |
| Four artifact scans | 4/4 passed | Same artifact root; User isolation and Internal capability scanners |
| Build-flavor mutation suite | 31/31 passed | `scripts/test_build_flavor_checks.sh` |

Release configurations retain `ENABLE_TESTABILITY=NO`. Separate
`build-for-testing` compilation was run with command-line
`ENABLE_TESTABILITY=YES` only to compile test sources under Release compiler
settings; both User-Release and Internal-Release compilation passed. This
override is not part of a production configuration.

Repository architecture, API baseline, privacy, secret, hygiene, and strict
concurrency gates also passed in the PR-02 gate run. `xcodebuild -list` showed
the two schemes and four configurations above; it is the source of truth for
current build names.

## Not performed

No device installation or launch, real microphone/ASR/LLM/Search provider call,
commit, or push was performed in this evidence run. The four builds are
simulator artifacts and do not substitute for physical-device validation.

## Follow-up

PR-03 will complete the CI User/Internal matrix and enforce
`codex/internal-debug` as a zero-delta delivery pointer to a reviewed `main`
commit, including exact commit/tree equality and promotion checks. Device and
real-service validation remain separate release gates.
