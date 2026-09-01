# Target architecture for the staged refactor

## Current delivery workflow

The local delivery workflow now uses deterministic, fail-closed impact
selection for PRs and retains cheap branch/hygiene/security checks on every
run. Pushes to `main` and no-input manual diagnostics run the full matrix.
`Required CI` remains the protected aggregate; promotion reuses its exact
successful `main` SHA and performs a lightweight fresh pointer equality check
instead of a third full CI run. Coverage artifacts contain reports only. See
[CI workflow](../CI_WORKFLOW.md); hosted validation is pending the next upload.

Status: PR-03 implementation merged and narrow bootstrap verified;
steady-state hosted promotion validation pending

## Outcomes

The refactor preserves product behavior while making four properties explicit:

1. User and owner-internal products share one business-code line.
2. Build variants select capabilities at the composition root, not inside
   feature state machines.
3. Provider-neutral domain and orchestration remain separate from live
   frameworks, credentials, diagnostics storage, and SwiftUI rendering.
4. Pure value algorithms may be extracted, but existing asynchronous owners
   keep task, cancellation, generation, transport, and cleanup responsibility.

## Dependency direction

```text
SingleGreenUser / SingleGreenInternal product schemes
    -> one shared SingleGreenDemo App target
    -> AppBootstrap + immutable AppEnvironment
        -> feature composition
            -> SingleGreenGlassesKit
                -> Experience runtime and domain models
                -> Conversation ports + VoiceConversationController
                -> VoiceChatDomain
                -> StreamingTextKit
            -> SingleGreenConversationAdapters
                -> VoiceChatCore
                    -> ASRDomain -> VoiceActivityDetectionKit
                -> LLMKit -> LLMChatTransport
        -> App live adapters
            -> provider transports, system frameworks, credentials
            -> diagnostics implementation selected by build variant
        -> SwiftUI/UIKit measurement and rendering
```

The following existing ownership rules remain non-negotiable:

- `VoiceConversationController` is the sole conversation orchestration and
  cancellation owner; it does not gain provider networking or UI algorithms.
- `ConversationPorts` remains the stable App-facing ASR and Agent contract.
- `ASRDomain` owns provider-neutral ASR failures, session and voice-activated
  state/events, VAD policy, frame-source contracts, and streaming-transport
  contracts. It depends only on Foundation and `VoiceActivityDetectionKit`.
- `VoiceChatCore` re-exports the ASR domain for source compatibility while it
  continues to own session actors, Apple audio implementation, provider
  transport mapping, cancellation, generation, and cleanup.
- `ConversationLiveAdapters` remains the production framework bridge.
- `LLMKit` owns provider-neutral chat, stateless/stateful Agent semantics, tool
  rounds, and context transactions through `LLMChatTransport`.
- `StreamingTextKit` owns typewriter cadence, grapheme-safe buffering, Unicode
  reconciliation, and auto-follow policy.
- SwiftUI views measure and render; they do not recreate streaming or feature
  state rules.

## Staged follow-up

1. PR-02 (implemented): add XCConfig-backed User/Internal build variants and
   schemes, then mechanically migrate owner-only compile guards to the two
   narrow capability flags.
2. PR-03 (implemented locally): make `codex/internal-debug` a zero-delta
   promotion pointer to a reviewed `main` commit and enforce branch equality,
   artifact capability checks, and the complete four-variant CI matrix.
3. PR-04–06: introduce typed diagnostics contracts, internal persistence,
   rotation, privacy-safe export, and correlated feature events.
4. PR-07–09: extract pure text-adventure, teleprompter, and HUD algorithms from
   current complexity centers without moving runtime ownership.
5. PR-10: split only pure conversation state decisions after the preceding
   extraction pattern is proven.
6. PR-11–12: consolidate composition and add visual/XCUITest coverage for both
   products.

New Packages are not a success metric. Extraction requires a stable reuse or
independent-test boundary. PR-02 does not add TCA, Tuist, Pulse, SwiftLog, or any
other production dependency.

## Exact PR-02 capability matrix

PR-02 adds `Configurations/Base.xcconfig`, `User-Debug.xcconfig`,
`User-Release.xcconfig`, `Internal-Debug.xcconfig`, and
`Internal-Release.xcconfig`, plus two explicit shared product schemes over the
existing `SingleGreenDemo` App target. It does not add a second App target and
does not change diagnostics storage, schemas, or shared feature business logic.
All complete User and Internal XCConfigs and both shared schemes are canonical
tracked definitions on `main`. PR-02 also performs a capability-boundary
migration. Provider-neutral public `ConversationTelemetryEvent`,
`ConversationTelemetrySink`, `NoopConversationTelemetry`, and shared
conversation composition remain unconditional so Package APIs and User
compilation stay compatible. Only the App-local `ConversationTelemetryStore`,
diagnostics/export UI, lifecycle string recording, and internal sink selection
are compiled under `INTERNAL_DIAGNOSTICS`. User composition injects
`NoopConversationTelemetry`, producing no stored or exportable User logs. Demo
credential types, UI, and composition are compiled only under
`INTERNAL_DEMO_CREDENTIALS`; the provider-neutral server credential contract
remains unconditional. This preserves existing internal behavior and storage
while intentionally removing owner-only features from User-Debug and
User-Release.

| Capability | User-Debug | User-Release | Internal-Debug | Internal-Release |
|---|---|---|---|---|
| Display name | `单绿测试平台` | `单绿测试平台` | `单绿内部版` | `单绿内部版` |
| Bundle ID | `com.local.SingleGreenDemo` | `com.local.SingleGreenDemo` | `com.local.SingleGreenDemo.internal` | `com.local.SingleGreenDemo.internal` |
| Provider-neutral telemetry API | Yes | Yes | Yes | Yes |
| `INTERNAL_DIAGNOSTICS` | No | No | Yes | Yes |
| Stored/exportable App diagnostics | No; no-op sink | No; no-op sink | Yes; internal sink | Yes; internal sink |
| Debug panel and safe-area controls | No | No | Yes | Yes |
| One-tap diagnostics export | No | No | Yes | Yes |
| `INTERNAL_DEMO_CREDENTIALS` | No | No | Yes | Yes |
| Local Keychain demo-credential UI/path | No | No | Yes | Yes |
| Server credential contract | Yes, fail closed | Yes, fail closed | Available | Available |
| Test sources embedded in `.app` | No | No | No | No |
| Compiler optimization | Debug default | Release default | Debug default | Release default |
| Debug symbols | Development setting | Release setting | Development setting | Release setting |

`DEBUG` means compiler/debug configuration only. It does not imply
owner identity, diagnostics capability, or local credential capability. No API
key, token, provisioning profile, or credential value may enter XCConfig,
source, tests, fixtures, logs, or documentation.

Both schemes retain a Test action so each product composition can be validated;
test sources remain in the separate test target and are never copied into an
App product. The phrase "user build has no tests" refers to the distributed
artifact, not removal of tests from the source repository.

The separate internal bundle identifier intentionally creates an isolated App
sandbox, settings domain, and Keychain access context. Existing user-variant
settings and locally entered demo credentials do not migrate automatically.
The owner must perform one-time setup and credential re-entry in the internal
variant. Shared Keychain access is not part of PR-02; any future migration or
access-group design requires a separate security and compatibility review.

## PR-02 acceptance evidence

The implementation and current evidence are recorded in [PR-02 evidence](./PR02_EVIDENCE.md).

- All four configurations resolve with the expected flags and distinct app
  identities; User and Internal products can coexist on a device.
- User Debug and User Release contain no internal UI, export path, internal
  display name, internal bundle identifier, or demo credential capability.
- Internal Debug and Internal Release contain the reviewed owner capabilities.
- Compile and API tests prove the provider-neutral telemetry event, sink, no-op
  sink, and shared conversation composition remain available in all variants
  with unchanged public Package API.
- Source and artifact tests prove the App-local telemetry store, export UI,
  lifecycle string recording, and internal sink selection are guarded only by
  `INTERNAL_DIAGNOSTICS`. User composition injects
  `NoopConversationTelemetry` and produces no stored/exportable User logs.
- Demo credential types, UI, and composition are guarded only by
  `INTERNAL_DEMO_CREDENTIALS`; neither owner capability may be enabled through
  generic `DEBUG`.
- Composition tests prove User variants receive unavailable/no-op owner
  capabilities and fail closed without the unconditional server credential
  contract being fulfilled. Internal behavior remains compatible with the
  pre-migration owner build.
- The user Release credential-isolation and secret gates pass against the built
  `.app`, not just source.
- Both schemes and all four configuration mappings compile; focused guard,
  composition, settings-isolation, and artifact-capability tests pass before App
  integration tests.
- Installing both bundle identifiers is a remaining device validation step;
  Internal first launch must request one-time owner setup and must not read or
  silently copy user-variant credentials.
- Public Package APIs and streaming/concurrency behavior remain unchanged.

## PR-03 implementation evidence

The local branch contract and CI matrix are recorded in [PR-03 evidence](./PR03_EVIDENCE.md).
The three-SHA checker validates syntax/commit objects, equality with the
freshly fetched current `origin/main`, exact reviewed/internal SHA equality,
tree equality, and empty diff in that order. An older reviewed commit is
rejected because a workflow sourced from the pushed commit may not contain
PR-03. The trusted internal push flow uses `github.event.after`,
`GITHUB_SHA`, and an explicitly fetched `origin/main`; PRs targeting the
delivery pointer and workflow-dispatch review input are rejected. Zero tracked
exceptions are permitted. The active main ruleset is `21847803` and the active
internal integrity ruleset is `21848414`, both with no bypass. The internal
pointer is present at verified ref
`eb21fa1aa9958075a81fbd0887619c5000975665`; steady-state promotion on a new
protected `main` SHA remains pending. The narrow-window evidence and ruleset
versions are recorded in PR03_EVIDENCE.md.

CI covers User/Internal Debug App tests plus separate clean App-only Debug
builds and scans, and User/Internal Release builds and scans. The separate
Debug App build is required because the XCTest host embeds XCTest support and
is not the distributed artifact. Local fixture and matrix evidence, including
the initial expected XCTest-host scan failure, is in PR03_EVIDENCE.md.
The hosted baseline run **33299053875** passed package, App, Release, public API,
and coverage jobs after the locale portability fix. The two-workflow Required
CI/promotion design has hosted narrow-bootstrap evidence; steady-state new-SHA
promotion remains pending. Required CI is
an always-running fail-closed aggregation job. Promotion uses a read-only,
no-input owner-triggered authorization workflow followed by a separate
`workflow_run` writer. The writer revalidates the exact authorization
run/job/check/suite, Actions app `15368`, current-main SHA, and Required-CI
linkage before a non-force fast-forward-only zero-delta pointer update. The
active main ruleset `21847803` and internal integrity ruleset `21848414` have
no bypass; an attempted separate writer-bypass ruleset failed HTTP 422, so no
exclusive writer identity is claimed. The internal branch is present at the
verified bootstrap ref. The first split attempt had completed authorization,
but GitHub still reported the expected check during first-ref creation; the
later narrow bootstrap succeeded, but steady-state promotion on a genuinely
new protected `main` SHA remains pending. No PAT, secret, bypass, manual/force push,
deletion, device, or live-provider validation is claimed.
