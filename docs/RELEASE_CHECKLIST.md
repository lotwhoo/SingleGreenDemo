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

## M7 PR2 current local evidence (2026-08-28)

- [x] Six Package strict-concurrency/WAE suites: **390/390** (7, 16, 43, 150, 70, 104); focused `VoiceActivatedASRSession` **37/37**, critical repetition **100/100**, Controller **77/77**, App adapter **7/7**.
- [x] Full App-hosted XCTest: **62/62**, `/private/tmp/SingleGreenDemo-M7-PR2-AppTests-Final.xcresult`.
- [x] Coverage thresholds pass at `/private/tmp/SingleGreenDemo-M7-PR2-Coverage-Final`; Debug generic Simulator and Release universal Simulator arm64+x86_64 builds pass.
- [ ] GitHub hosted CI, PR2 physical-device build/install/launch, real providers, manual accessibility/optical validation, and fresh sanitizer execution.

## Version and source

- [ ] Version and migration notes are reviewed.
- [ ] The candidate commit is immutable and the working tree is clean.
- [ ] `git diff --cached --check`, secret scan, and generated-artifact scan pass.
- [ ] Root license status and `NOTICE.md` are reviewed for the intended distribution.

## Automated gates

- [x] Local toolchain matches the reviewed contract: Xcode 26.6 (17F113), Swift 6.3.3, macOS/iPhone Simulator SDK 26.5.
- [x] Architecture boundary checker and its 10 negative fixtures pass.
- [x] Public API inventory has 14 reviewed snapshots (7 modules × macOS arm64 and iOS Simulator arm64); additions and removals require explicit review.
- [ ] GitHub Actions execution of the pinned workflow (not run for M7 PR1).

- [x] Six Package suites pass in Swift 6 complete concurrency mode with warnings as errors: `StreamingTextKit` 7, `VoiceChatDomain` 16, `VoiceActivityDetectionKit` 43, `SingleGreenGlassesKit` 150, `LLMKit` 70, `VoiceChatCore` 91 (377/377 total).
- [x] ASRCLI passes its separate strict-concurrency/warnings-as-errors build and privacy-log static check; it is not included in package `Sources/` coverage.
- [x] App-hosted simulator tests pass on the resolved destination (62/62; Package warnings-as-errors is enforced by the separate strict gate because Xcode suppresses local Package warnings).
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
