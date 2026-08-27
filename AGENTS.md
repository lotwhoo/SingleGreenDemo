# SingleGreenDemo Agent Instructions

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
SingleGreenDemo composition root
    -> Conversation ports
    -> Conversation live adapters
        -> VoiceChatCore
        -> LLMKit -> LLMChatTransport -> provider client
    -> VoiceChatDomain
    -> StreamingTextKit
    -> SwiftUI HUD rendering
```

- `VoiceConversationController` owns orchestration, state transitions, cancellation, generation checks, and display scheduling.
- `ConversationPorts.swift` owns stable App-level ASR and Agent contracts.
- `ConversationLiveAdapters.swift` owns production bridges to VoiceChatCore and LLMKit.
- `VoiceChatDomain` owns conversation and reply lifecycle semantics.
- `LLMKit` owns provider-neutral chat, SSE parsing contracts, tool rounds, and context transactions.
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

Run the narrowest affected suite first, then all suites relevant to the changed boundary.

```bash
swift test
cd Packages/VoiceChatDomain && swift test
cd Packages/VoiceChatCore && swift test
cd Packages/LLMKit && swift test
cd Packages/StreamingTextKit && swift test
```

For App integration, resolve an available simulator before running:

```bash
xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenDemo -showdestinations
xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/SingleGreenDemo-AgentTests \
  test -only-testing:SingleGreenDemoTests
```

For build compatibility:

```bash
xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenDemo \
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
