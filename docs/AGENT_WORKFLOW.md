# Codex Agent Workflow

## Purpose

This repository stores project-scoped Codex agents so the architecture, testing, review, documentation, device, and release practices established during the streaming AI conversation work can be reused in later tasks.

The product baseline remains commit `5a02b2e90321265b61533b948928319cccf9f161`. Agent configuration changes improve the development workflow; they do not alter App runtime behavior.

## Configuration layout

```text
AGENTS.md
.codex/
├── config.toml
└── agents/
    ├── ios-architect.toml
    ├── swift-implementer.toml
    ├── streaming-qa.toml
    ├── code-reviewer.toml
    ├── release-engineer.toml
    └── docs-maintainer.toml
```

`AGENTS.md` contains repository-wide invariants and quality gates. `.codex/config.toml` enables project agents and limits concurrency. Each standalone TOML file defines one narrow custom agent.

## Agent responsibilities

| Agent | Access | Primary responsibility | Must not do |
| --- | --- | --- | --- |
| `ios_architect` | Read-only | Trace ownership, contracts, concurrency, migration, acceptance criteria | Edit files or invent unverified APIs |
| `swift_implementer` | Workspace write | Implement scoped Swift/SwiftUI changes and focused tests | Change behavior outside scope or store secrets |
| `streaming_qa` | Workspace write | Build deterministic test matrices and execute regression | Weaken assertions or silently edit production code |
| `code_reviewer` | Read-only | Find concrete P0-P2 correctness, concurrency, security, and test issues | Produce style-only findings |
| `release_engineer` | Workspace write | Verify release state, signed builds, device install/launch, Git actions | Publish, install, or rewrite history without explicit authorization |
| `docs_maintainer` | Workspace write | Keep architecture, upgrade, task, and evidence documents current | Claim unexecuted verification |

## Recommended feature workflow

```text
Architecture evidence
    -> Scoped implementation
    -> Focused tests
    -> Full regression
    -> Independent review
    -> Fix and re-test if needed
    -> Documentation
    -> Explicitly authorized device/Git/release action
```

Parallel work is reserved for independent read-only tasks. Implementation and review should be sequential so the reviewer sees the final diff. Never assign overlapping edits to multiple agents.

## Language policy

- User-facing commentary and final responses are in Simplified Chinese unless the user requests otherwise.
- Custom-agent instructions, internal tasks, handoffs, and technical coordination are in English.
- Hidden chain-of-thought is neither exposed nor stored. Agents provide concise rationale, evidence, decisions, and verification summaries.

## Quality gates inherited from the baseline

Every streaming conversation change must consider:

- ASR lifecycle and cancellation.
- LLM provider isolation through `LLMChatTransport`.
- SSE choice selection, termination, partial failure, tool assembly, retry, and rollback.
- Reply UUID and generation isolation.
- Grapheme safety, combining scalars, backlog catch-up, Reduce Motion, and auto-follow.
- App-hosted integration behavior and signed-device compatibility when release scope requires it.

Test counts are evidence for a specific commit, not a fixed target. Agents must report the current count produced by the current code.

## Example requests

Architecture and implementation:

```text
Use ios_architect to review the requested AI conversation change, then have swift_implementer make the smallest compatible implementation after the architecture handoff.
```

Independent verification:

```text
Use streaming_qa to run the affected package tests and App-hosted XCTest, then have code_reviewer review the final diff and test coverage.
```

Release:

```text
After all gates pass, use release_engineer to build, install, and launch on my connected iPhone. Do not commit or push until I explicitly ask.
```

## Maintenance

Update an agent when its role repeatedly misses the same class of defect, produces overlapping ownership, or requires manual reminders that should be persistent. Prefer tightening a narrow agent over creating a broad duplicate. Any agent update should include a TOML parse check, a documentation consistency check, and a review of whether its permissions are still the minimum necessary.
