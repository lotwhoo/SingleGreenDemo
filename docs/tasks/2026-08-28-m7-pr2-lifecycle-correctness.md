# M7 PR2: VAD/ASR lifecycle correctness

## Status and scope

M7 PR2 is locally complete; M7 overall continues. The baseline under test started at `a2c39745b61bef71ecbfe6f2541287f86ca0e8f9` with PR1+PR2 changes uncommitted. No public API or API snapshot changed.

`VoiceActivatedASRSession` owns one ContinuousClock-backed, injectable monotonic frame-liveness watchdog. It starts after source start, uses one sleeper loop, and accepted raw frames refresh `noSpeechFrameLimit × 20 ms` (standard 15 s). Deadline starvation fails closed as typed `audioUnavailable`; valid silent frames remain the automatic `.noSpeech` path. Levels, VAD, transport, stale, and rejected frames are not heartbeats. Manual pre-onset finish emits Core `.noSpeech` then `.finished`; post-onset finish drains buffered tail frames FIFO.

## Verification

- Strict packages: **390/390** — StreamingTextKit 7, VoiceChatDomain 16, VoiceActivityDetectionKit 43, SingleGreenGlassesKit 150, LLMKit 70, VoiceChatCore 104. VADBenchmark and ASRCLI strict builds passed.
- Focused VoiceActivatedASRSession: **37/37**; five critical cases repeated 20× by independent QA: **100/100**; Controller **77/77**; App adapter **7/7**, result `/tmp/SingleGreenDemo-M7-PR2-FinalQA-AppAdapter/Logs/Test/Test-SingleGreenDemo-2026.08.28_16-02-10-+0800.xcresult`.
- Coverage `/private/tmp/SingleGreenDemo-M7-PR2-Coverage-Final`: StreamingTextKit 75/88 (85.23%), VoiceChatDomain 106/107 (99.07%), VoiceActivityDetectionKit 379/397 (95.47%), SingleGreenGlassesKit 2602/2793 (93.16%), LLMKit 925/1029 (89.89%), VoiceChatCore 2051/2706 (75.79%); all thresholds pass.
- Full App XCTest **62/62**, `/private/tmp/SingleGreenDemo-M7-PR2-AppTests-Final.xcresult`; Simulator `iPhone 17 Pro`, iOS 26.5, `C6946499-FF39-4047-865C-2618445BB07A`.
- Debug generic Simulator and Release universal arm64+x86_64 builds passed; release credential isolation, toolchain, architecture (10 negatives), API (14 snapshots), privacy, hygiene, secrets, release validator, simulator resolver, YAML, and diff gates passed.

Expected warnings only were the destination diagnostic, AppIntents/AppShortcuts skips, and unsigned bitcode-strip notice. Final independent reviewer and QA were GO with no P0–P2 findings; earlier expired-deadline masking, tautological terminal recorder, and tail-audio regression findings were fixed and re-tested.

## Evidence boundaries and residual risks

GitHub hosted CI has not run. No PR2 physical-device build/install/launch, real provider validation, manual accessibility/optical validation, or fresh sanitizer execution occurred. Deterministic clocks are not prolonged real-microphone suspension evidence. P3 risks: source start itself is not timed out; deliberately suspended `openStream`/`send` lacks a dedicated watchdog test; the liveness interval is compatibility-derived and a future distinct policy requires API review.
