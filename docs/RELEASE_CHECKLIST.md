# Release candidate checklist

This checklist records evidence; it does not imply that a GitHub runner, device, or real service was exercised.

## Provider-neutral post-audit evidence (historical PR1 snapshot, 2026-08-28)

- Six local Package strict-concurrency/WAE suites: **377/377** (`StreamingTextKit` 7, `VoiceChatDomain` 16, `VoiceActivityDetectionKit` 43, `SingleGreenGlassesKit` 150, `LLMKit` 70, `VoiceChatCore` 91).
- App-hosted XCTest: **62/62**, result bundle `/private/tmp/SingleGreenDemo-QA-PostWrapper-AppTest.xcresult`; focused ASR/controller: **24/24** and **77/77**; VAD sanitizer suites: **43/43** each under ASan/UBSan/TSan.
- Release Simulator `arm64 + x86_64` build: passed.
- Mic-fix worktree signed Debug `iphoneos arm64` build, strict codesign, install, and (after unlock) launch passed at 2026-08-28 13:29 local time; PID 5053 remained stable. Evidence: `/private/tmp/SingleGreenDemo-MicFix-DeviceBuild.xcresult`. The user then reported the physical-device test had no apparent issues. This is user-observed functional acceptance, not a scripted VAD/service matrix. The fix activates AVAudioSession before graph-format access, filters categoryChange, retains genuine startup/runtime observers, and maps local startup errors to `audioUnavailable`. The earlier relock was transient environment evidence.
- Historical pre-throwing-VAD-contract P2 worktree signed Debug `iphoneos arm64` build, strict codesign validation, install, and launch passed on iPhone 17 Pro Max / iOS 26.6.1; PID 3457 stable at +5s/+15s. Evidence: `/private/tmp/SingleGreenDemo-Final-P2-DeviceBuild.xcresult`. This predates the current App contract change and is not evidence that the current throwing-VAD worktree was installed; it proves deployment/launch stability only, and VAD/mic/ASR/provider/UI runtime behavior remains unverified.
- Historical device app artifact: `/private/tmp/SingleGreenDemo-Final-P2-DeviceBuild/Build/Products/Debug-iphoneos/SingleGreenDemo.app`; CoreDevice: `40BE3CD1-94E4-5767-A10E-9374D30DF01C`.
- Continuous voice rearm, audio notification wiring, unexpected ASR stream closure, open custom Experience registration, and complete tool-call argument validation are covered by the post-audit code/tests.
- The production WebRTC detector is integrated only at the App composition root; independent AISettings remains fail-closed and there is no energy fallback. The current worktree has the user-observed physical-device microphone/VAD/conversation-flow acceptance described above. No complete scripted route/interruption matrix, independently captured real-provider trace, GitHub CI, backend, or rollback evidence is claimed.

## M7 PR2 historical local evidence (superseded by PR3+PR4, 2026-08-28)

- [x] Six Package strict-concurrency/WAE suites: **390/390** (7, 16, 43, 150, 70, 104); focused `VoiceActivatedASRSession` **37/37**, critical repetition **100/100**, Controller **77/77**, App adapter **7/7**.
- [x] Full App-hosted XCTest: **62/62**, `/private/tmp/SingleGreenDemo-M7-PR2-AppTests-Final.xcresult`.
- [x] Coverage thresholds pass at `/private/tmp/SingleGreenDemo-M7-PR2-Coverage-Final`; Debug generic Simulator and Release universal Simulator arm64+x86_64 builds pass.
- [ ] GitHub hosted CI, PR2 physical-device build/install/launch, real providers, manual accessibility/optical validation, and fresh sanitizer execution.

## M7 PR3 historical local evidence (superseded by PR3+PR4, 2026-08-28)

- [x] Seven Package strict-concurrency/WAE suites: **414/414** (7, 16, 43, 150, 70, 104, 24); adapter-package critical lifecycle repetition **100/100**.
- [x] Full App-hosted XCTest: **55/55**, `/private/tmp/SingleGreenDemo-M7-PR3-AppTests-4.xcresult`.
- [x] Package coverage thresholds pass; `SingleGreenConversationAdapters` is **347/354 (98.02%)** and the complete table is maintained in `docs/COVERAGE_BASELINE.md`.
- [x] Debug Simulator and strict Release Simulator builds pass. Architecture/import, package inventory, API, privacy, repository-hygiene, YAML, and diff gates pass locally.
- [x] Public API inventory is **16 snapshots** for eight modules across macOS arm64 and iOS Simulator arm64; the two new adapter snapshots were reviewed.
- [ ] GitHub hosted CI, PR3 physical-device build/install/launch, real providers, manual accessibility/optical validation, and rollback evidence.

## M7 PR3 + PR4 combined historical local evidence (superseded by PR5, 2026-08-28)

Historical compatibility marker: current combined PR3+PR4 gate is seven Packages **438/438**; this section is superseded by the current PR5 evidence below.

- [x] Seven Package strict-concurrency/WAE suites: **438/438** (`7, 16, 43, 174, 24, 70, 104`).
- [x] Adapter lifecycle critical cases repeated **480** times (24 cases × 20); terminal lifecycle cases repeated **380** times (19 cases × 20).
- [x] Full App-hosted XCTest: **55/55**, `/private/tmp/SingleGreenDemo-M7-Combined-QA-App.xcresult`.
- [x] Coverage thresholds pass; `SingleGreenGlassesKit` is **94.08%** and `SingleGreenConversationAdapters` is **98.02%**.
- [x] Debug and strict universal Release Simulator builds pass for `arm64 + x86_64`.
- [x] Public API inventory is **8 modules × 2 architectures = 16 snapshots**. PR4 adds the reviewed `ExperienceRuntime.init(validating:)` API.
- [ ] GitHub hosted CI, physical-device build/install/launch, live providers, accessibility/optical validation, and rollback evidence.

## M7 PR5 mechanical decomposition (current local evidence, 2026-08-28)

- [x] PR5 delta is limited to exactly four files; controller task/generation ownership is unchanged.
- [x] Focused telemetry/terminal regression **25/25** and critical lifecycle repetition **17 × 20 = 340/340**.
- [x] Seven Package strict-concurrency/WAE suites **438/438**; isolated App-hosted XCTest **55/55**, `/private/tmp/SingleGreenDemo-M7-PR5-AppTests-Retry/Logs/Test/Test-SingleGreenDemo-2026.08.28_19-46-03-+0800.xcresult`.
- [x] The non-authoritative concurrent timing-warning run is retained at `/private/tmp/SingleGreenDemo-M7-PR5-AppTests/Logs/Test/Test-SingleGreenDemo-2026.08.28_19-43-48-+0800.xcresult`.
- [x] Coverage thresholds pass: `SingleGreenGlassesKit` **93.91%**, `SingleGreenConversationAdapters` **98.02%**.
- [x] Eight modules × two architectures remain **16 byte-identical API snapshots**; architecture negative fixtures remain **11**.
- [x] Debug generic Simulator and strict universal Release Simulator (`arm64 + x86_64`) builds pass; independent review is GO.
- [ ] Physical-device build/install/launch, live providers, GitHub-hosted CI, accessibility/optical validation, commit, and push remain outside this checkpoint.

The concurrent-only simulator timing warning was followed by an isolated **55/55** rerun. This is local deterministic evidence and does not establish device or real-service behavior.

## Version and source

- [ ] Version and migration notes are reviewed.
- [ ] The candidate commit is immutable and the working tree is clean.
- [ ] `git diff --cached --check`, secret scan, and generated-artifact scan pass.
- [ ] Root license status and `NOTICE.md` are reviewed for the intended distribution.

## Automated gates

- [x] Local toolchain matches the reviewed contract: Xcode 26.6 (17F113), Swift 6.3.3, macOS/iPhone Simulator SDK 26.5.
- [x] Architecture boundary checker and its 11 negative fixtures pass in the current PR5 gate; the earlier 10-fixture count is historical PR1 evidence. (Historical compatibility wording: Architecture boundary checker and its 11 negative fixtures pass in the current combined gate.)
- [x] Public API inventory has 16 reviewed snapshots (8 modules × macOS arm64 and iOS Simulator arm64); the earlier 14-snapshot inventory is historical M7 PR1 evidence.
- [ ] GitHub Actions execution of the pinned workflow (not run for M7 PR1).

- [x] The historical M7 PR1 six-Package gate was 377/377 and App 62/62; the current PR5 gate is seven Packages **438/438** (`7, 16, 43, 174, 24, 70, 104`) and App **55/55**.
- [x] ASRCLI passes its separate strict-concurrency/warnings-as-errors build and privacy-log static check; it is not included in package `Sources/` coverage.
- [x] App-hosted simulator tests pass on the resolved destination (current PR5 isolated retry **55/55**; the earlier 62/62 result is historical PR1/PR2 evidence).
- [x] Release generic Simulator build passes for universal arm64 and x86_64.
- [x] Coverage report is archived and pragmatic package thresholds pass (FinalQA2 coverage baseline).
- [x] Release evidence JSON validates against the versioned contract.
- [x] Evidence-validator mutation tests and repository scan regression fixtures pass.

## Device and service matrix

| Area | Minimum candidate evidence | Status |
| --- | --- | --- |
| iPhone compact / regular / max | Launch, 8:3 HUD layout, control accessibility labels | Not run |
| Physical microphone | Built-in, Bluetooth route change, interruption, media reset | Not run |
| App lifecycle | Background cancels uncommitted work; foreground does not auto-resume | Not run |
| Network | Offline, timeout, HTTP 401 before content, disconnect after content | Not run |
| Accessibility | Reduce Motion, VoiceOver, Dynamic Type, contrast | Not run |
| Real providers | ASR → LLM → optional search with non-production account | Not run |
| Glasses hardware | Optical safe area, alignment, brightness, power, thermal | Blocked until hardware exists |

Never place a credential, transcript, answer, audio sample, or provider response in release evidence.

## Rollback

- [ ] Record the previous known-good commit and App version.
- [ ] Confirm settings/profile data remains readable by the previous version or document migration loss.
- [ ] Stop rollout before changing server-issued credential policy.
- [ ] Reinstall the previous signed build through the authorized distribution channel.
- [ ] Confirm launch and one privacy-safe smoke flow; do not reuse expired credential leases.
- [ ] Record the rollback reason and any data/configuration implications.

Device install, launch, signing, tagging, pushing, and release creation require explicit user authorization and are separate gates.
