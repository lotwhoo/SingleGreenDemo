# SingleGreenDemo Agent Instructions

## Current CI operating contract

The layered CI design in [docs/CI_WORKFLOW.md](./docs/CI_WORKFLOW.md) is the
current local contract. Pull requests use deterministic, fail-closed impact
selection from the exact PR base planner/config; cheap branch/hygiene/security
gates always run; pushes to `main` and no-input manual diagnostic runs are
full. The initial rollout falls back to a hard-coded full plan when the base
does not yet contain the planner. `Required CI` remains the stable protected
aggregate. Promotion reuses the exact successful `main` SHA and performs a
lightweight fresh pointer check instead of a third full CI run. Coverage
uploads contain reports only. This behavior is not hosted evidence until the
next upload.

## Communication contract

- Communicate with the user in Simplified Chinese unless the user explicitly requests another language.
- Write internal agent tasks, agent-to-agent messages, technical handoffs, and custom-agent instructions in English.
- Do not reveal, request, or persist hidden chain-of-thought. Provide concise decision summaries, evidence, assumptions, and verification results instead.
- Lead user-facing updates with the outcome or current status, then state the next concrete action.

## Project baseline

- Repository: `lotwhoo/SingleGreenDemo`.
- Stable product baseline: commit `5a02b2e90321265b61533b948928319cccf9f161`.
- Baseline evidence: 156 automated tests passed, signed iphoneos arm64 build passed, and the user confirmed the physical-device AI conversation flow.
- Treat test counts and device state as historical evidence. Re-run or clearly label them as historical when the code under test changes.

## Architecture ownership

Maintain this dependency direction:

```text
SingleGreenDemo simulator composition root
    -> SingleGreenGlassesKit
        -> Experience contracts, runtime, domain models, and built-in experiences
        -> Conversation ports and VoiceConversationController
        -> VoiceChatDomain
        -> StreamingTextKit
    -> SingleGreenConversationAdapters
        -> VoiceChatCore
        -> LLMKit compatibility -> AgentCore -> LLMCore
    -> ConversationLiveAdapters.swift
        -> provider transports, credentials, factories, and presentation policy
    -> SwiftUI HUD rendering
```

- `SingleGreenGlassesKit` owns device-independent glasses behavior and must not import SwiftUI, UIKit, AVFoundation, provider SDKs, settings persistence, or camera code.
- `SingleGreenDemo` is a simulator/debug host. It owns camera preview, control surfaces, settings, live adapters, and composition only.
- Simulator controls consume generic `ExperienceControlState`; they must not read a concrete experience controller directly.
- `VoiceConversationController` owns orchestration, state transitions, cancellation, generation checks, and display scheduling.
- `ConversationPorts.swift` owns stable glasses-core ASR and Agent contracts.
- `SingleGreenConversationAdapters` owns reusable semantic bridges from VoiceChatCore/LLMKit into the glasses-core conversation ports.
- `ConversationLiveAdapters.swift` owns App-specific provider transports, credentials, factories, and presentation policy; it composes the reusable adapters and must not move those concerns into the core package.
- `VoiceChatDomain` owns conversation and reply lifecycle semantics.
- `LLMCore` owns provider-neutral chat values, tool contracts, streaming events, the transport port, and typed errors.
- `AgentCore` depends only on `LLMCore` and owns tool rounds, context limits, transactions, commit/abort, and terminal rules.
- `LLMKit` remains the compatibility import and temporarily owns the OpenAI-compatible HTTP/SSE and Bocha implementations until M13-PR2 moves them into adapter targets.
- `StreamingTextKit` owns typewriter cadence, grapheme-safe buffering, Unicode reconciliation, and auto-follow policy.
- SwiftUI views own measurement and rendering, not network or conversation business logic.

Do not move provider-specific code into the Controller, duplicate StreamingTextKit algorithms in the App, or let views mutate conversation state.

## Streaming and concurrency invariants

- Only the first observed target SSE choice contributes content and completion state.
- A target `finish_reason` or global `[DONE]` terminates a valid stream; connection close alone does not.
- Do not retry after publishing content unless deduplication is explicitly designed and tested.
- Assemble tool calls by index and reject incomplete id, name, or arguments.
- Commit Agent context only after the final answer completes successfully.
- Cancellation, Reset, a newer transaction, tool failure, incomplete stream, or mixed content/tool failure must not commit stale context.
- Every network event and typewriter tick must remain isolated by reply identity and generation.
- Preserve Swift `Character` boundaries and the Unicode-scalar reconciliation behavior for combining marks across deltas.
- Default `TypewriterPolicy.standard` behavior is a compatibility contract unless the user requests a UX change.
- Reduce Motion must continue to flush incremental text without per-character animation.

## Implementation rules

- Inspect the real code path and current tests before editing.
- Preserve unrelated user changes in a dirty worktree.
- Use `apply_patch` for source and documentation edits.
- Prefer small protocols and injected values over service locators, global mutable state, or concrete provider dependencies.
- Extract a package only when there is a stable ownership, reuse, or independent-test boundary.
- Keep public API invariants enforced by immutable properties or validated initializers.
- Do not add production dependencies without explaining the need and obtaining user approval when the dependency materially changes the project.
- Never write API keys, access tokens, provisioning content, or user secrets into tracked files, fixtures, logs, or documentation.

## Test gates

For impact-selective CI or promotion-workflow changes, run the planner and
coverage fixtures before the static workflow contract and mutation suite:

```bash
scripts/test_ci_impact_plan.sh
scripts/test_coverage_gate_selection.sh
scripts/check_ci_workflow.sh
scripts/test_ci_workflow_check.sh
```

M7 PR1 quality gates (run from the repository root):

```bash
scripts/check_toolchain.sh
scripts/check_package_inventory.sh
scripts/check_architecture_boundaries.sh
scripts/test_architecture_boundaries.sh
scripts/test_public_api_baselines.sh
scripts/test_public_api_baseline_update.sh
scripts/check_public_api_baselines.sh
```

Public API snapshots are reviewed artifacts for ten library modules (20 snapshots total) on macOS arm64 and iOS Simulator arm64. Additions and removals both require explicit review. Update only with `scripts/update_public_api_baselines.sh --accept-current-api` after inspecting the diff; the updater is never run automatically in CI.

M7 PR2 lifecycle invariants: `VoiceActivatedASRSession` owns one ContinuousClock-backed, injectable monotonic frame-liveness watchdog. It starts after source start; accepted raw frames refresh the compatibility-derived `noSpeechFrameLimit × 20 ms` interval (standard 15 s). At or after the deadline, pre/post-onset starvation fails closed as typed `audioUnavailable`; valid silent frames remain the `.noSpeech` path. Levels, VAD observations, transport activity, stale frames, and rejected frames are not heartbeats. Manual pre-onset finish emits Core `.noSpeech` then `.finished`; post-onset finish drains buffered tail frames FIFO before completion. Keep actor/generation/epoch checks and one-terminal semantics intact.

Run the narrowest affected suite first, then all suites relevant to the changed boundary.

```bash
cd Packages/SingleGreenGlassesKit && swift test
cd Packages/VoiceChatDomain && swift test
cd Packages/VoiceChatCore && swift test
cd Packages/LLMKit && swift test
cd Packages/StreamingTextKit && swift test
cd Packages/VoiceActivityDetectionKit && swift test
cd Packages/SingleGreenConversationAdapters && swift test
```

For App integration, resolve an available simulator before running:

```bash
xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenUser -showdestinations
xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenUser \
  -configuration User-Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/SingleGreenDemo-AgentTests \
  test -only-testing:SingleGreenDemoTests
```

For build compatibility:

```bash
xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenUser \
  -configuration User-Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/SingleGreenDemo-AgentBuild \
  CODE_SIGNING_ALLOWED=NO build
```

- Never claim a test, build, install, launch, real-service call, or device check passed without its actual result.
- Report exact commands, pass/fail counts, environment failures, warnings, xcresult paths, and manual validation still required.
- Automated tests must use fake services, URLProtocol, injected clocks, and deterministic streams; never consume real credentials.

## Review gate

Before declaring a code change complete:

1. Trace affected entry points, state transitions, and cancellation paths.
2. Review the diff for P0-P2 correctness, concurrency, security, compatibility, and test gaps.
3. Run `git diff --check`.
4. Scan the changed scope for secrets and generated artifacts.
5. Update README, architecture, upgrade, or task documentation when a module boundary, public contract, test baseline, or release procedure changes.
6. State residual risks instead of hiding them.

## Agent orchestration

Project custom agents live in `.codex/agents/`:

- `ios_architect`: read-only architecture and migration design.
- `swift_implementer`: focused Swift and SwiftUI implementation.
- `streaming_qa`: deterministic streaming and integration verification.
- `code_reviewer`: read-only owner-level review.
- `release_engineer`: signed builds, device operations, Git, and GitHub release actions.
- `docs_maintainer`: architecture and upgrade documentation.

Use agents only when the user explicitly requests agent delegation or the active runtime explicitly allows proactive delegation. Give each agent one bounded task in English. Do not ask multiple agents to edit the same file concurrently.

For substantial feature work, prefer this sequence:

1. `ios_architect` maps risks, contracts, and acceptance criteria.
2. `swift_implementer` makes the scoped change and focused tests.
3. `streaming_qa` executes the risk-based regression matrix.
4. `code_reviewer` reviews the final diff and evidence.
5. Route actionable findings back to `swift_implementer`, then re-test.
6. `docs_maintainer` updates durable documentation.
7. `release_engineer` acts only after explicit authorization for device, commit, push, tag, or release operations.

## Git and device safety

- Commit, tag, push, create releases, install on a device, or launch on a device only when the user explicitly requests that action.
- Before commit or push, verify branch, remote, staged scope, `git diff --cached --check`, and secret scan.
- Do not force-push, rewrite history, or use destructive reset/checkout commands unless the user explicitly requests the exact operation.
- Resolve the exact device identifier before installation. Build, install, and launch are separate gates and must be reported separately.
- Never treat a successful generic device build as evidence that installation or launch succeeded.

## PR-03 local delivery-pointer evidence

The local PR-03 contract is documented in
`docs/refactor/PR03_EVIDENCE.md`. The exact branch checker invocation is:

```bash
scripts/check_internal_branch_policy.sh REVIEWED_MAIN_SHA MAIN_SHA INTERNAL_SHA
```

Its validation order is full-SHA syntax and commit objects, equality with the
freshly fetched current `origin/main`, exact reviewed/internal SHA equality,
tree equality, then empty diff. An older reviewed commit is rejected because a
workflow sourced from the pushed commit may not contain PR-03. The trusted push workflow sources these values from
`github.event.after`, an explicitly fetched `origin/main`, and `GITHUB_SHA`,
and rejects pull requests targeting `codex/internal-debug` or workflow-dispatch
review input. Zero tracked exceptions are permitted.

CI covers User-Debug and Internal-Debug App XCTest followed by separate clean
App-only Debug builds and artifact scans, plus User-Release and Internal-Release
generic Simulator builds and scans. The separate Debug build is required
because the XCTest host embeds XCTest support and is not the distributed App.
Remote branch bootstrap/promotion, hosted CI, commit/push, device validation,
and live-provider validation remain separately authorized and must not be
claimed from local evidence.
