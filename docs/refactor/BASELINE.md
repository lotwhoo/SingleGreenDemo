# Refactor baseline

Status: Milestone 1 / PR-01 planning baseline

Baseline revision: `69ce212f386b5f2c3da556ea5521736a4901d0cc`

Branch at capture: `codex/refactor-m1`

Capture date: 2026-08-30

## Purpose and evidence boundary

This document fixes the measurable starting point for the staged refactor. It
does not claim that production tests, builds, device installation, provider
calls, or hosted CI were rerun for PR-01. The repository metadata below was
collected locally with `scripts/collect_refactor_baseline.sh`; the collector
structurally inspects tracked source files for line counts and
`project.pbxproj` for configuration names. It emits metadata and names only; it
does not inspect or emit environment variables, credential stores,
credential/configuration values, or provider and user payloads.

Generate a fresh report outside the repository:

```sh
scripts/collect_refactor_baseline.sh
```

Or write to an explicitly reviewed location:

```sh
scripts/collect_refactor_baseline.sh --output /private/tmp/single-green-baseline.md
```

The report records its own revision, branch, and working-tree state. Reports
are deliberately not written under the repository by default and are not
release artifacts.

## Current measured repository shape

The following values were captured from the tracked files at the baseline
revision. Package manifests and tracked paths under generated/build directory
names are excluded from Swift line counts.

| Metric | Baseline |
|---|---:|
| Production Swift files | 101 |
| Production Swift lines | 18,563 |
| Test Swift files | 52 |
| Test Swift lines | 20,231 |
| Local Swift packages | 7 |
| Xcode app targets | 1 |
| Xcode test targets | 1 |
| Xcode configurations | 2 (`Debug`, `Release`) |

The seven local packages are `LLMKit`, `SingleGreenConversationAdapters`,
`SingleGreenGlassesKit`, `StreamingTextKit`, `VoiceActivityDetectionKit`,
`VoiceChatCore`, and `VoiceChatDomain`. `xcodebuild -list` currently exposes the
app scheme, the package schemes, `VADBenchmark`, and
`WebRTCVoiceActivityDetection`. There are no tracked `.xcconfig` files at this
baseline; build settings are held in `SingleGreenDemo.xcodeproj/project.pbxproj`.

### Largest production Swift files

| Lines | Path |
|---:|---|
| 826 | `Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/AI/VoiceConversationController.swift` |
| 806 | `Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/AI/TextAdventureDomain.swift` |
| 664 | `Packages/VoiceChatCore/Sources/VoiceChatCore/VoiceActivatedASRSession.swift` |
| 641 | `SingleGreenDemo/Platform/AI/TextAdventureLiveAdapter.swift` |
| 589 | `SingleGreenDemo/Platform/Rendering/HUDFlowingTextView.swift` |
| 544 | `Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/AI/TeleprompterController.swift` |

Line count identifies review hotspots; it is not itself a reason to split an
owner. In particular, asynchronous task, transport, generation, and
cancellation ownership must stay with the existing controller/actor while pure
value algorithms are extracted.

## Existing quality and architecture controls

Current tracked controls include:

- Seven-package inventory and dependency-boundary checks.
- Swift 6 strict-concurrency and warnings-as-errors gates.
- Eight public modules with macOS arm64 and iOS Simulator arm64 API snapshots.
- Repository hygiene, secret, privacy, VAD privacy, and Release credential
  isolation checks.
- Deterministic Package tests and App-hosted XCTest.

Earlier local gates are recorded with their own revisions and scope in the
[architecture report](../PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md), while the
[teleprompter PRD](../ASR_TELEPROMPTER_PRD.md) records its separate historical
simulator, build, and device-install boundary. Those records must not be
represented as PR-01 evidence and do not prove the current branch launches or
that live ASR, LLM, search, optical readability, or audio routing works.

PR-01 changes documentation and baseline tooling only. Its focused gate is
`scripts/test_refactor_baseline.sh`, followed by `git diff --check`. Production
test/build gates remain mandatory for each later behavior or build-system PR.

## Baseline limitations and next measurement

This first collector intentionally omits build duration, `.app` size, launch
latency, diagnostics write throughput, and export throughput. Those metrics
require controlled artifacts or runtime instrumentation and must not be inferred
from source metadata. PR-02 will first make the four build variants
constructible; later diagnostics work can then add comparable performance
measurements without changing the PR-01 collector's privacy boundary.
