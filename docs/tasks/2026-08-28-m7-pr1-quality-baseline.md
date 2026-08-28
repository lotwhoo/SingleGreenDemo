# M7 PR1: Architecture, API, and toolchain quality baseline

## Scope and status

M7 PR1 is locally complete as a documentation and quality-gate milestone. It does not complete M7 overall. The baseline under test started at commit `a2c39745b61bef71ecbfe6f2541287f86ca0e8f9` with an uncommitted PR1 worktree. The stable historical product baseline remains `5a02b2e90321265b61533b948928319cccf9f161`.

The only production-source change is removal of an unused conditional UIKit import from `Packages/VoiceChatCore/Sources/VoiceChatCore/AudioCapture.swift`; this change is behavior-neutral.

## Delivered quality controls

- `config/architecture-boundaries.json` defines package products, target dependencies, allowed imports, and App local-package ownership. The checker covers SwiftPM and the textual Xcode project graph; its self-test includes 10 negative fixtures.
- `config/toolchain.json` and `scripts/check_toolchain.sh` pin the verified contract to Xcode 26.6 build 17F113, Swift 6.3.3, and macOS/iPhone Simulator SDK 26.5.
- `api-baselines/xcode-26.6-swift-6.3.3/` contains 14 exact snapshots: seven modules on macOS arm64 and iOS Simulator arm64. Additions and removals require explicit review. Updates use `scripts/update_public_api_baselines.sh --accept-current-api` and are blocked in CI.
- CI is selected for the pinned macOS 26/Xcode 26.6 toolchain and runs architecture, API, concurrency, coverage, hygiene, and privacy gates. GitHub Actions has not yet run this workflow.

## Local verification evidence

- Strict concurrency/WAE package suites: **377/377** (`7, 16, 43, 150, 70, 91`); coverage artifacts: `/private/tmp/SingleGreenDemo-M7-PR1-Coverage-Final`.
- Package line coverage: StreamingTextKit **85.23%**, VoiceChatDomain **99.07%**, VoiceActivityDetectionKit **95.47%**, SingleGreenGlassesKit **93.38%**, LLMKit **89.89%**, VoiceChatCore **74.50%**.
- App-hosted XCTest: **62/62**, `/private/tmp/SingleGreenDemo-M7-PR1-AppTests-Final.xcresult`.
- Debug generic Simulator build passed; Release universal Simulator build passed for arm64 and x86_64.
- Release credential-isolation scan passed.
- Architecture valid graph plus 10 negative fixtures passed; public API self-test, update safety test, and exact 14-snapshot check passed. Repository hygiene, secret scan, VAD documentation state, YAML parsing, and `git diff --check` passed.

These are local results for the uncommitted worktree. No physical-device build/install/launch occurred for PR1, no real-service validation occurred, and no commit or push was performed.

## Residual risks and next step

- P3: the API updater has no concurrent invocation lock.
- P3: snapshots intentionally cover arm64 only.
- P3: the textual pbxproj parser may need maintenance after future Xcode format changes.

M7 PR2 is lifecycle correctness: add and test the VAD no-frame wall-clock watchdog with an injected clock, preserving cancellation and generation isolation.
