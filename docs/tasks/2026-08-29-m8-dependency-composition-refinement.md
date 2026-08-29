# M8: Dependency & Composition Refinement

> Status: locally implemented and verified; no device or live-provider claim
>
> Date: 2026-08-29
>
> Method: Design-First SDD

## Scope and decision

M8 addresses the next complexity center after the M7 modular quality baseline: the dependency container and the App composition root. The public core dependency value is grouped by ownership while retaining the existing source-facing construction surface. The App composition is split by responsibility without moving orchestration ownership out of `VoiceConversationController`.

The lifecycle is `draft → accepted → frozen → implemented → verified → superseded`. This record is frozen for PR1–PR4; later changes append a new change record rather than rewriting these requirements.

## Frozen requirements trace

| ID | Requirement | Acceptance evidence |
| --- | --- | --- |
| REQ-1 | The core dependency value SHALL expose four immutable groups: input, agent, presentation, and observability. | Public API review and dependency tests |
| REQ-2 | The existing flat initializer and 11 accessors SHALL remain source-package compatible; no binary-layout or ABI promise is made. | API snapshots and compatibility tests |
| REQ-3 | Controller Task handles, generation checks, cancellation, session/reply identity, and display scheduling SHALL remain owned by `VoiceConversationController`. | Controller regression and review |
| REQ-4 | The App live entry SHALL remain small; extracted files SHALL have single ownership boundaries for credentials, preparation, presentation, telemetry, and production VAD/ASR factory. | File-boundary review |
| REQ-5 | `VoiceConversationComposition` SHALL accept one shared preparation resolver. The resolver SHALL exclusively own settings-derived input, ASR, and Agent behavior. | Composition isolation, mode-switch, missing-configuration, and factory tests |
| REQ-6 | The internal `AgentFactory` SHALL remain a test seam only. No Service Locator, global registry, or runtime hot swap SHALL be introduced. | Architecture review and negative checks |

### PR1 — grouped core dependencies

Design: four public immutable structs are the ownership units. `VoiceConversationDependencies` stores them and offers the grouped initializer. Compatibility projections preserve the old flat call sites. The projections are a source compatibility device, not a promise about stored-property order, binary layout, or ABI.

Implementation: `VoiceConversationDependencies.swift` plus the four group types. Tests cover grouped construction, compatibility projections, defaults, and observability injection.

### PR2 — App dependency extraction

Design: keep `ConversationDependencies.swift` as the live entry point and extract five App-internal files: `ConversationCredentialProvider.swift`, `ConversationPreparationResolver.swift`, `ConversationPresentationPolicy.swift`, `ConversationTelemetryStore.swift`, and `ProductionVoiceActivatedSessionFactory.swift`. `VoiceConversationComposition.swift` is the explicit composition boundary.

Implementation: provider credentials, preparation, reviewed copy, telemetry, and inactive VAD/ASR production creation are no longer mixed in the live entry file.

### PR3 — composition isolation

Design: construct one resolver from the current settings and provider boundary, pass that same resolver into `VoiceConversationComposition`, and derive both input and Agent groups from it. The resolver is `@MainActor` and its factory is inert until the returned session is armed.

Implementation: mode switching creates the expected fresh voice session; PTT does not invoke the voice-activated factory; unavailable configuration fails before credential preparation; the injected `AgentFactory` is only used by tests.

### PR4 — compatibility and verification closure

Design: review public API additions/removals as artifacts, run focused and full regressions, and record the toolchain caveat separately from source correctness.

Implementation: the two `SingleGreenGlassesKit` snapshots were refreshed and manually reviewed; all other snapshots remain unchanged.

## Design and dependency contract

```text
SingleGreenDemo/Platform/AI/ConversationDependencies.swift
  -> VoiceConversationComposition
       -> one ConversationPreparationResolver
       -> credential / presentation / telemetry / production factory boundaries
  -> VoiceConversationDependencies (core grouped value)
       -> VoiceConversationController
```

`VoiceConversationController` remains the use-case orchestrator and sole owner of Task handles, generation/cancellation rules, session lifecycle, reply identity, and display scheduling. Dependency grouping must not be used as a reason to split those ownership concerns.

`VoiceConversationComposition` is App-internal. Its shared resolver prevents combining settings-derived input from composition A with an Agent or ASR behavior from composition B. `AgentFactory` is internal and test-only; new production integrations should enter through the existing provider-neutral ports and App adapters.

## Property and test trace

| ID | Property / invariant | Deterministic test |
| --- | --- | --- |
| PROP-1 | Grouped dependencies and compatibility projections represent the same injected behavior. | `VoiceConversationDependenciesTests` |
| PROP-2 | A missing or invalid dependency fails closed before starting capture, transport, or credential work. | dependency and `ConversationPreparationTests` |
| PROP-3 | Switching input mode through one resolver produces isolated preparation and does not cross-wire Agent/ASR behavior. | composition mode-switch and A/B isolation tests |
| PROP-4 | Controller lifecycle ownership and generation/cancellation semantics are unchanged. | Controller lifecycle regression suite |
| PROP-5 | Public API changes contain additions only; no reviewed symbol is removed. | API baseline check and manual diff |

No property is labeled property-based testing unless the test generates a domain and deterministic seed and reports a shrinkable counterexample. The M8 checks are deterministic example/contract tests, not PBT.

## Acceptance and evidence

The verified local evidence for this checkpoint is:

- `SingleGreenGlassesKit`: **178/178**.
- App XCTest: **58/58**, result bundle `/private/tmp/SingleGreenDemo-M8-FinalReview/Logs/Test/Test-SingleGreenDemo-2026.08.29_01-48-06-+0800.xcresult`.
- Focused PR3 tests: **3/3**, result bundle `/private/tmp/SingleGreenDemo-M8PR3-Focused/Logs/Test/Test-SingleGreenDemo-2026.08.29_01-24-55-+0800.xcresult`; `ConversationPreparation` ReQA: **17/17**, result bundle `/private/tmp/SingleGreenDemo-M8PR3-ReQA/Logs/Test/Test-SingleGreenDemo-2026.08.29_01-38-11-+0800.xcresult`.
- Controller + dependency focused regression: **99/99**.
- Public API: **8 modules × 2 platforms = 16 snapshots**. Exactly the two `SingleGreenGlassesKit` snapshots changed; each has **39 additions / 0 removals**. The remaining 14 snapshots are unchanged.
- Architecture checks: seven Packages and **11 negative fixtures**.
- Debug generic Simulator build and Release generic Simulator build passed.
- The first global `SWIFT_TREAT_WARNINGS_AS_ERRORS` attempt conflicted with Package `-suppress-warnings`; this is recorded as tooling evidence, not a source failure. The subsequent scoped verification passed.

These are local deterministic results. No physical-device build/install/launch, microphone acceptance, real ASR/LLM/Search call, or GitHub-hosted CI result is claimed for M8.

## Non-goals

- No full TCA migration.
- No splitting of Controller Task ownership to reduce file length.
- No further Package split without a second stable implementation/consumer boundary.
- No global Service Locator, runtime plugin system, or premature Experience/Provider Registry.
- No LLMKit core/protocol split in this milestone.

## Deferred decisions

Evaluate an LLMKit split only after a second independently shipped transport/provider SDK/platform consumer creates a stable ownership and release boundary. Evaluate an Experience/Provider Registry only after a real runtime switching requirement exists, at least two production implementations are shipped, and lifecycle/context semantics are specified and tested.

## Rollback and upgrade procedure

Rollback is a source-level revert to the pre-M8 commit while preserving this historical record. Do not edit API snapshots manually to hide a regression. On a forward fix, update the grouped implementation and compatibility tests together, rerun the affected package/App suites, rerun API review, then append a superseding task record. If a managed consumer cannot migrate, continue using the flat initializer/accessors while the grouped initializer remains the preferred new path.

## Residual risks

The resolver is an App-internal composition boundary, not a runtime registry or plugin ABI. Release credential transport remains fail-closed until a reviewed server-issued lease is available. Simulator evidence does not establish physical-device, real microphone, optical, or live-provider behavior. The API snapshot updater remains a reviewed artifact workflow and should not be run concurrently.
