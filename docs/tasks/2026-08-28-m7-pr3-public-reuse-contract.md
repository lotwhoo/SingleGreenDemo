# M7 PR3: Public reuse contract for conversation adapters

## Status and scope

M7 PR3 is locally complete as a public-reuse and composition-boundary milestone. M7 overall continues. The change extracts provider-neutral bridges from the App into the new `SingleGreenConversationAdapters` package; it does not change the glasses-core ports, VAD policy, UI behavior, provider protocol, or device/runtime claims.

The package owns four reusable public entry points:

- `VoiceChatSpeechRecognitionAdapter`, which maps `VoiceChatCore.ASRSession` events to the glasses-core `SpeechRecognitionSession` port.
- `VoiceChatVoiceActivatedSpeechRecognitionAdapter`, which maps `VoiceChatCore.VoiceActivatedASRSession` events and endpoint reasons to the glasses-core voice-activated session port.
- `LLMKitConversationAgentAdapter`, which maps `LLMKit.LLMAgent` stream and staged-context operations to the glasses-core `ConversationAgent` port.
- `LLMKitConversationAgentAdapterPolicy`, which lets the host supply semantic tool-activity and reviewed stream-error mappings without moving provider copy or raw tool names into the reusable package.

The dependency direction is:

```text
SingleGreenConversationAdapters
    -> SingleGreenGlassesKit
    -> VoiceChatCore
    -> LLMKit
SingleGreenDemo composition root
    -> SingleGreenConversationAdapters
```

Credentials, account leases, provider model/resource configuration, WebRTC factory selection, AISettings, localization/presentation copy, raw `web_search` mapping, and provider-specific error classification remain App-owned. Low-level `PCMFrameSource` and `StreamingASRTransport` are intentionally not publicized by this milestone.

## Public compatibility contract

- The adapters preserve one-terminal-event and cancellation semantics of their wrapped sessions.
- Voice-activated adapter events are deduplicated and late events after cancellation/finish are ignored.
- Agent stream deltas preserve transaction ordering; context is committed only through the explicit staged transaction API, and abort/rollback clears stale pending state.
- The reusable package has no SwiftUI, UIKit, AppKit, AVFoundation, AudioToolbox, OSLog, Security, Network, WebRTC, or C-module imports.
- The package is Swift 6 strict-concurrency compatible for iOS 18 and macOS 14.
- Public API changes require reviewed macOS arm64 and iOS Simulator arm64 snapshots. The current repository contains 16 snapshots for eight library modules.

## Local verification evidence

The current PR3 worktree was verified locally with:

- Seven Package strict-concurrency/WAE suites: **414/414**. The new adapter package contributes **24/24**; its critical lifecycle cases were repeated **100/100**.
- App-hosted XCTest: **55/55**, result bundle `/private/tmp/SingleGreenDemo-M7-PR3-AppTests-4.xcresult`.
- Adapter package coverage: **347/354 (98.02%)**. The full package coverage table is maintained in [`docs/COVERAGE_BASELINE.md`](../COVERAGE_BASELINE.md).
- Debug Simulator and strict Release Simulator builds passed for the current App composition.
- Architecture/import/package-inventory, API, privacy, repository-hygiene, YAML, and `git diff --check` gates passed locally. API inventory is **8 modules × 2 architectures = 16 snapshots**; the two new adapter snapshots were reviewed as part of PR3.

These are local code and build results. GitHub-hosted CI, physical-device build/install/launch for PR3, real ASR/LLM/Search providers, accessibility, optical, and rollback validation are not claimed here. No commit or push is recorded by this task.

## Upgrade checklist

When adding another live provider or host:

1. Implement or configure the low-level provider in its owning package/App composition root.
2. Reuse the stable glasses-core ports and the adapter package; do not add provider imports to `SingleGreenGlassesKit`.
3. Keep credentials, leases, raw provider tool names, and user-facing error text in the host policy/resolver.
4. Add deterministic adapter tests with fake sessions/agents, including cancel, duplicate terminal, late-event, error, and transaction rollback cases.
5. Review public API snapshots and run the seven-package strict gate, App tests, coverage, architecture, privacy, and repository checks.

## Residual risks

The adapters are validated with deterministic fakes and App composition tests, not a live provider or physical microphone. A future public API addition/removal still needs explicit snapshot review. The existing low-level Core ports remain intentionally internal until a second independent production implementation demonstrates a stable reuse boundary.
