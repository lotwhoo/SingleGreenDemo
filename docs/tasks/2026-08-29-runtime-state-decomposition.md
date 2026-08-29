# M9: Runtime State Decomposition

> Status: implemented in `8abce82323b58a80f4e6d9c3b79bef92e6150008`; affected packages and static contracts reverified
>
> Date: 2026-08-29
>
> Scope: behavior-preserving runtime-state extraction; no App, device, or live-provider claim

## Objective

Reduce the amount of interleaved mutable bookkeeping in the conversation and audio paths without creating a second runtime owner. The existing controller, actors, and capture objects continue to own Task handles, transports, cancellation, cleanup, and side effects. Extracted types contain only synchronized or actor-owned per-run facts that can be tested independently.

## Implemented boundaries

### Conversation execution state

`ConversationControllerExecutionState` owns pure admission facts for:

- conversation-operation generation;
- host lifecycle generation and active/background state;
- continuous voice-activation generation;
- idempotent shutdown admission.

`VoiceConversationController` remains the sole owner of lifecycle, input, reset, reply, display, automatic-rearm, and shutdown Tasks. The extracted value does not schedule work or call dependencies.

### Audio capture run state

`AudioCaptureRunState` owns one lock-protected capture run: run identity, callback token, chunk and level handlers, pending PCM bytes, chunk emission, and the remainder returned during stop. `AudioCaptureSession` and the platform audio path continue to own AVFoundation setup, teardown, audio-session activation, system events, and callback installation.

The former `AudioCapture.swift` responsibilities are also separated into `AudioCaptureSession.swift`, `AudioCaptureSystemEvents.swift`, and `PCMBufferSnapshot.swift`. This is a file/responsibility split, not a new public framework boundary.

### Voice-activated ASR run state

`VoiceActivatedASRRunState` owns per-run facts and bounded buffering: accepted-frame state, onset/transport facts, FIFO frame queue, pending upload frames, in-flight count, manual finish, and finalization admission. `VoiceActivatedASRSession` remains the actor owner of the frame source, VAD pipeline, ASR transport, watchdog, cleanup barrier, generation checks, and Tasks.

## Preserved invariants

- New input, reset, backgrounding, cancellation, or shutdown invalidates stale generations before asynchronous cleanup can finish.
- A voice-activated session does not open ASR transport before local onset confirmation.
- Accepted upload frames remain FIFO and bounded; backpressure failure does not silently discard or duplicate accepted audio.
- Manual and automatic finalization retain one-terminal semantics and tail-drain behavior.
- Agent context still commits only after completed upstream delivery, display catch-up, and synchronous domain acceptance.
- No provider, UI, AVFoundation, or WebRTC dependency moves into `SingleGreenGlassesKit`.

## Current verification

Fresh verification against `8abce82323b58a80f4e6d9c3b79bef92e6150008`:

- `swift test --package-path Packages/SingleGreenGlassesKit --scratch-path /private/tmp/SingleGreenGlassesKit-ReadAudit`: **184/184**.
- `swift test --package-path Packages/VoiceChatCore --scratch-path /private/tmp/VoiceChatCore-ReadAudit`: **109/109**.
- `scripts/check_architecture_boundaries.sh`: passed for seven Packages.
- `scripts/check_package_inventory.sh`: passed for seven local Packages.
- `scripts/check_public_api_baselines.sh`: passed for eight library modules on macOS arm64 and iOS Simulator arm64, **16 snapshots** total.
- `scripts/check_repository_hygiene.sh`, `scripts/scan_secrets.sh`, and `git diff --check`: passed.

The current verification did not run App-hosted XCTest, an App Simulator build, signed device build, device install/launch, physical microphone/VAD acceptance, live ASR/LLM/Search, GitHub-hosted CI, accessibility, or optical validation.

## Follow-up boundary

Do not extract Task ownership from `VoiceConversationController` or `VoiceActivatedASRSession` merely to reduce file length. A further owner split requires a stable lifecycle contract, a clear cancellation/join boundary, and deterministic tests proving that the new owner cannot race reset, backgrounding, shutdown, or a newer generation.
