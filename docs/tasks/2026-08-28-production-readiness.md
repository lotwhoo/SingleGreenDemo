# M5 Production Readiness evidence record

## Scope delivered locally

- M5 建立了五包 strict-concurrency matrix、App-hosted Simulator tests、Release generic Simulator build、仓库卫生、secret scan 和生产源码覆盖率；M6 Stage 1 已在不改写本段 M5 历史证据的前提下把当前 matrix 扩展到第六个 `VoiceActivityDetectionKit`。
- Fresh-checkout App CI prints Xcode destinations, prefers an available iPhone 17 Pro UDID, falls back to another available iPhone, and always uploads the App xcresult when one exists.
- `Tools/ASRCLI` is outside the package `Sources/` coverage aggregation; it has a separate strict-concurrency, warnings-as-errors product build and privacy-log static gate.
- Reviewed coverage baseline and pragmatic regression thresholds.
- Deterministic release-evidence JSON schema, template generator, and structural validator.
- Versioned release checklist, device/service matrix, rollback procedure, and NOTICE/license status.
- Privacy-safe typed conversation telemetry with bounded host storage, coarse failure categories, monotonic durations, and no transcript, answer, credential, provider payload, tool argument, or stable identifier fields.
- Every telemetry phase has a single terminal recorder. Configuration, credential, network, authorization, interruption, incomplete-stream, and context-commit failures are carried as typed coarse codes rather than inferred from localized text.
- Explicit background suspension: active input/reply/display work is cancelled and the uncommitted turn is aborted; committed history is preserved; foreground activation does not restart capture.
- Controller operation and host-lifecycle generations are established before speech/reply credential awaits and checked immediately afterward. The App synchronously captures scene transitions through the Controller-owned serialized task, so stale background cleanup cannot cancel a newer foreground input.
- Agent context commit and domain completion now share one non-suspending MainActor acceptance step. Token-scoped abort can roll back an internally committed but not yet host-accepted transaction without clearing earlier history; deterministic post-commit gates cover background, reset, and new-input supersession.
- Injectable ASR transport fault tests and typed audio interruption/route/media-reset seam.
- `ASRSession` validates state plus lifecycle generation across start, cancel, restart, queued audio, and terminal delivery; deterministic gates cover captured and buffered stale terminal events.
- Short-lived credential provider contract with lease expiry validation and single-flight refresh. Fetch and minimum-lifetime validation run inside the same shared task, so concurrent waiters receive the same valid lease or the same typed rejection; invalid leases are never cached. Debug/internal builds retain the clearly labeled demo Keychain provider. Release uses a fail-closed server transport stub and does not read the demo credential fields.
- Provider-neutral ASR failures cross the glasses-core port as a typed coarse code plus optional reviewed static copy. The host maps provider and audio failures without forwarding raw detail; deterministic 401/403 integration tests prove exactly one redacted `unauthorized` input terminal, with additional network and audio mapping coverage.
- Release does not compile demo credential properties, Keychain helper/provider, bindings, or secret controls. A built-app binary assertion protects that boundary; Debug keeps the mode visibly labelled as internal demo behavior.
- Repository secret scanning treats NUL-containing inputs as bytes instead of skipping them as binaries; safe binary, binary-secret, and `.log` fixtures pin the behavior.
- Coverage aggregation is restricted to each package's canonical `Sources/` root, with a synthetic dependency-source regression test.

## Verification boundary

The repository tests use fakes, deterministic clocks, URLProtocol, and injected transports. They do not call real ASR, LLM, search, credential, or telemetry services. GitHub Actions has been defined and syntax-checked locally, but has not been run on a GitHub-hosted runner.

CI does not restore compiled SwiftPM `.build` directories。M5 的五个包只使用本地源码依赖；当前第六个 `VoiceActivityDetectionKit` 无第三方依赖，因此仍没有依赖下载缓存收益，而可变的 macOS/Xcode runner image 可能使已编译 module cache 不兼容。远程包解析变得显著后可重新评估。

Existing deterministic coverage includes DisplayProfile viewport/safe-area projection, Reduce Motion behavior, capability accessibility labels, weak-network retry policy, non-retryable client errors, partial-stream interruption, ASR failure before content, ASR authorization failure after partial transcript, and background cancellation/generation isolation.

Fresh local QA on 2026-08-28 passed the strict five-package gate with 254 tests (7 StreamingTextKit, 15 VoiceChatDomain, 125 SingleGreenGlassesKit, 63 LLMKit, 44 VoiceChatCore), the separate strict ASRCLI build, and 35 App-hosted tests on the resolved iPhone 17 Pro Simulator. The final App result bundle is `/private/tmp/SingleGreenDemo-M5-OwnerFinal-App.xcresult`. The unsigned Release Simulator binary was verified as `arm64 + x86_64`, and the Release demo-credential binary assertion passed. A clean canonical package-source coverage run passed at 75/88 (85.23%), 106/107 (99.07%), 2362/2532 (93.29%), 879/976 (90.06%), and 878/1277 (68.75%) respectively. The retained reports are at `/private/tmp/SingleGreenDemo-M5-OwnerFinal-Coverage`. These are local results, not evidence of a GitHub-hosted run, physical-device execution, or real-provider behavior.

## Deferred acceptance items

- [ ] Implement and security-review the authenticated application-server credential endpoint and its production transport. No backend is included in this repository.
- [ ] Wire the typed audio seam to AVAudioSession interruption, route-change, and media-services-reset notifications, then validate Bluetooth and wired routes on hardware.
- [ ] Run the workflow on GitHub and retain the resulting checks and artifacts.
- [ ] Select/add a repository-level license; `NOTICE.md` records the current absence and is not legal advice.
- [ ] Run a signed device build, install and launch it separately, then complete the device/service matrix with non-secret evidence.
- [ ] Validate real ASR to LLM to optional search, including expired credential, 401, weak network, backgrounding, and interruption behavior without logging payloads.
- [ ] Complete manual VoiceOver, Dynamic Type, Reduce Motion, screen-size, camera-permission, and real-glasses optical checks. No screenshots or device claims are synthesized by automated tests.
- [ ] Exercise and record rollback against a real release candidate and distribution channel.

## Superseding integrated VAD status (2026-08-28)

The approved WebRTC production detector is integrated only at the `SingleGreenDemo` composition root; independent AISettings remains fail-closed. Current strict evidence is **377/377** across six Packages (7,16,43,150,70,91), App **62/62** at `/private/tmp/SingleGreenDemo-QA-PostWrapper-AppTest.xcresult`, focused ASR/controller **24/24** and **77/77**, and VAD ASan/UBSan/TSan **43/43** each. Debug/Release universal simulator, unsigned Release iphoneos, and static gates pass; coverage is `/private/tmp/SingleGreenDemo-QA-PostWrapper-Coverage`. After unlock, the mic-fix device launch succeeded at 2026-08-28 13:29 with PID 5053 stable; the user reported no apparent issues in physical-device testing. This is user-observed acceptance, not a complete scripted VAD/ASR/provider route/interruption matrix.

Until those boxes are supported by release evidence, M5 is an automated foundation rather than a production launch approval.

## Superseding post-audit status (2026-08-28)

The prior provider-neutral post-audit snapshot (now historical) had six Package suites at **349/349** (`StreamingTextKit` 7, `VoiceChatDomain` 16, `VoiceActivityDetectionKit` 23, `SingleGreenGlassesKit` 148, `LLMKit` 70, `VoiceChatCore` 85) and App-hosted XCTest **48/48** at `/private/tmp/SingleGreenDemo-ProviderNeutral-OwnerApp.xcresult`; Release Simulator `arm64 + x86_64` builds and credential isolation passed. Its package source coverage was 85.23%, 99.07%, 95.47%, 93.57%, 89.89%, and 73.02% respectively.

The prior FinalQA2 snapshot (now superseded) had six Package suites at **351/351**, App-hosted XCTest **54/54** at `/private/tmp/SingleGreenDemo-FinalQA2-App.xcresult`, and focused `VoiceActivatedASRSession`/`VoiceConversationController` suites **24/24** and **77/77**. Its coverage was 85.23%, 99.07%, 95.47%, 93.38%, 89.89%, and 73.02% respectively.

The current Throwing-VAD FinalQA2 evidence has six Package suites at **351/351**, App-hosted XCTest **58/58** at `/private/tmp/SingleGreenDemo-ThrowingVAD-Full.xcresult`, and throwing factory focused tests **12/12** at `/private/tmp/SingleGreenDemo-ThrowingVAD-Focused.xcresult`; Debug/Release generic Simulator universal `arm64 + x86_64` builds, static gates, and Release credential isolation pass.

The final provider-neutral fixes discard an unused same-context prepared Agent, use stable non-secret account scope with per-call refreshed credentials and account isolation, provide safe copy for unknown errors, cancel suspended credential resolution, and define DEBUG non-secret persisted account revision semantics. Provider/model/resource configuration, credential leasing, validation copy and raw `web_search` mapping remain App-only; the glasses core consumes prepared sessions and opaque/semantic contracts.

The post-audit code path covers continuous voice rearm, audio interruption/route/media-services-reset notification wiring, unexpected ASR stream closure, open custom Experience registration, and complete tool-call argument validation. These are local deterministic and simulator/build results, not real service or hardware evidence.

Historical pre-throwing-VAD evidence: the Final-P2 worktree's signed Debug `iphoneos arm64` build, strict codesign validation, install, and launch passed; PID 3457 was stable at +5s/+15s. This predates WebRTC integration and is retained only as deployment history.

The pre-implementation WebRTC dependency decision is recorded in [the WebRTC VAD approval ADR](./2026-08-28-webrtc-vad-approval-adr.md). Its approval box is intentionally unchecked: the repository still contains no WebRTC source or binary, and the external feasibility probe is not VAD quality or device evidence.
