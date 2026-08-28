# M7 PR5: Mechanical decomposition without contract change

## Status and scope

M7 PR5 is locally complete as a behavior-neutral code-organization milestone. The reviewed four-file delta has been mechanically synchronized into the main worktree, and the main-worktree `SingleGreenGlassesKit` strict suite passes **174/174**. The change extracts the controller's synchronous telemetry bookkeeping into an internal `ConversationTelemetryTracker` and moves test support into a dedicated test-support file. It does not change public APIs, package dependencies, project configuration, runtime ownership, task ownership, generation checks, or user-facing behavior.

The PR5 delta is intentionally limited to exactly four files:

1. `Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/AI/Internal/ConversationTelemetryTracker.swift` (new internal tracker)
2. `Packages/SingleGreenGlassesKit/Sources/SingleGreenGlassesKit/AI/VoiceConversationController.swift` (delegates telemetry bookkeeping)
3. `Packages/SingleGreenGlassesKit/Tests/SingleGreenGlassesKitTests/VoiceConversationControllerTestSupport.swift` (new test helpers and fixtures)
4. `Packages/SingleGreenGlassesKit/Tests/SingleGreenGlassesKitTests/VoiceConversationControllerTests.swift` (retains the test cases and uses the support file)

`VoiceConversationController` remains the owner of orchestration, tasks, cancellation, reply/display generations, and lifecycle transitions. The tracker owns only synchronous telemetry phase start/finish bookkeeping and receives the existing telemetry sink and monotonic clock by injection. `ConversationInputCoordinator`, `ExperienceRuntime`, and `ConversationLiveAdapters` were deliberately not split in this milestone.

## Compatibility contract

- No `Package.swift`, Xcode project, configuration, dependency, documentation gate, or API baseline change is part of the PR5 code delta.
- All eight module API baselines across macOS arm64 and iOS Simulator arm64 remain byte-identical: **16 snapshots**.
- The 174 `SingleGreenGlassesKit` test identifiers remain byte-for-byte identical. **95 controller test methods** retain their names, bodies, and assertions; support helpers/fixtures moved to the dedicated support file.
- Telemetry event order and active-phase termination order remain unchanged; the tracker terminates active phases in the existing preparation → input → display → reply order.
- The PR5 App rerun is isolated from unrelated concurrent simulator work; the concurrent-only timing warning is recorded as an environment limitation, not a product failure.

## Review and verification evidence

Independent read-only review returned **GO**. The review confirmed the four-file boundary, unchanged controller task/generation ownership, unchanged test method names/assertions, no public API drift, and no provider/UI coupling.

Fresh local evidence for the isolated PR5 worktree:

- Focused telemetry and PR4 terminal-lifecycle regression: **25/25**.
- `SingleGreenGlassesKit` strict concurrency / warnings-as-errors suite: **174/174**.
- Seven-package strict gate: **438/438** (`7, 16, 43, 174, 24, 70, 104`).
- Critical lifecycle repetition: **17 cases × 20 = 340/340**.
- Isolated App-hosted XCTest rerun on the resolved iPhone 17 Pro Simulator: **55/55**; result `/private/tmp/SingleGreenDemo-M7-PR5-AppTests-Retry/Logs/Test/Test-SingleGreenDemo-2026.08.28_19-46-03-+0800.xcresult`.
- Non-authoritative concurrent timing-warning result: `/private/tmp/SingleGreenDemo-M7-PR5-AppTests.xcresult`.
- Coverage thresholds passed: `SingleGreenGlassesKit` **93.91%** and `SingleGreenConversationAdapters` **98.02%**.
- Debug generic Simulator and strict universal Release Simulator (`arm64 + x86_64`) builds passed.
- Architecture boundary and package inventory checks passed; architecture negative fixtures: **11**.
- API, privacy, repository-hygiene, secret, generated-artifact, and `git diff --check` gates passed.

These are local deterministic checks. No physical-device build/install/launch, live provider call, or GitHub-hosted CI run was performed for PR5. The synchronized main worktree remains uncommitted; commit and push were not performed.

## Upgrade checklist

Future controller decomposition must preserve the single owner for task handles, cancellation, lifecycle generations, reply/display identity, and terminal publication. A new extracted component needs an injected protocol/value boundary, focused deterministic tests, and an API snapshot review if any public symbol changes. Do not infer runtime or device behavior from the mechanical split; rerun the simulator, device, and provider matrices separately when those gates are authorized.
