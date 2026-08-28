# M7 PR4: Terminal lifecycle and shutdown correctness

## Status and scope

M7 PR4 is locally complete as a lifecycle-correctness milestone. It hardens terminal ownership and shutdown joining across `VoiceConversationController`, `ExperienceRuntime`, and the conversation adapters. The goal is that shutdown, reset, background cancellation, finish, and late events converge on one terminal state without duplicate cleanup, stale publication, or re-entry after shutdown.

The integration boundary remains:

```text
SingleGreenDemo
  -> SingleGreenConversationAdapters (semantic VoiceChatCore/LLMKit bridges)
  -> SingleGreenGlassesKit conversation ports and runtime
  -> VoiceChatCore / LLMKit provider-neutral implementations
SingleGreenDemo/Platform/AI/ConversationLiveAdapters.swift
  -> provider transports, credentials, factories, and presentation policy
```

## Design contract

- `VoiceConversationController.shutdown()` is idempotent and concurrent callers join the same cleanup work.
- Lifecycle, input-start, input-finish, reset, and automatic-rearm tasks are retained until their cleanup is joined; late events are rejected after shutdown.
- A shutdown publishes one terminal snapshot, leaves input idle, clears active reply/display state, and prevents new conversation work.
- `ExperienceRuntime` validates catalog construction through the additive public `init(validating:)` API; existing construction remains compatible.
- Existing generation, session-identity, reply-identity, actor isolation, one-terminal-event, staged Agent transaction, and VAD frame-liveness invariants remain in force.

## Review history

The initial red review identified a P2 lifecycle risk: a single stored lifecycle task could be overwritten by rapid background/foreground transitions, while independent reset, input, and rearm tasks could outlive shutdown. The implementation was revised to retain task generations, join all retired work, make shutdown idempotent, and publish a single terminal snapshot. The green review then confirmed that the new joins, post-shutdown guards, runtime validation initializer, and late-event tests preserve the public contracts without introducing provider or UI coupling.

## Final local evidence

- Seven Package strict-concurrency/WAE suites: **438/438** with package counts `7, 16, 43, 174, 24, 70, 104`.
- Adapter lifecycle critical cases: **480** repetitions (24 × 20).
- Terminal lifecycle cases: **380** repetitions (19 × 20).
- App-hosted XCTest: **55/55**, `/private/tmp/SingleGreenDemo-M7-Combined-QA-App.xcresult`.
- Coverage thresholds pass: `SingleGreenGlassesKit` **94.08%**, `SingleGreenConversationAdapters` **98.02%**.
- Debug and strict universal Release Simulator builds pass for `arm64 + x86_64`.
- Public API baseline is **8 modules × 2 architectures = 16 snapshots**; PR4 adds the reviewed `ExperienceRuntime.init(validating:)` initializer.
- Architecture, package inventory, API, privacy, hygiene, and `git diff --check` gates pass locally.

## Residual manual checks

No physical-device build/install/launch, live ASR/LLM/Search provider call, GitHub-hosted CI run, accessibility validation, optical validation, or rollback rehearsal is claimed for the combined milestone. Deterministic lifecycle repeats do not replace prolonged real microphone suspension, OS audio interruption, Bluetooth routing, or background execution validation.

## Upgrade checklist

Future lifecycle changes must add deterministic tests for concurrent shutdown callers, rapid host transitions, reset/finish races, cancellation while credential or provider work is suspended, late adapter events, one terminal snapshot, and no post-shutdown re-entry. Public API changes require both architecture snapshots and an explicit compatibility review.
