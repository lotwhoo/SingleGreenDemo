# User and internal product variants

## Current contract

The repository has one `SingleGreenDemo` App target, two shared product schemes,
and four tracked configurations:

| Scheme | Configuration | Display name | Bundle ID |
| --- | --- | --- | --- |
| `SingleGreenUser` | `User-Debug` / `User-Release` | `单绿测试平台` | `com.local.SingleGreenDemo` |
| `SingleGreenInternal` | `Internal-Debug` / `Internal-Release` | `单绿内部版` | `com.local.SingleGreenDemo.internal` |

`User-Debug` and `Internal-Debug` retain `DEBUG` for compiler/debug behavior.
Only the Internal configurations define `INTERNAL_DIAGNOSTICS` and
`INTERNAL_DEMO_CREDENTIALS`; Release configurations do not define `DEBUG` and
use whole-module optimization. `DEBUG` is not an owner or capability switch.

User variants inject `NoopConversationTelemetry` and contain no diagnostics
panel, safe-area controls, stored/exportable logs, or local demo-credential
path. Internal variants receive the reviewed diagnostics implementation and
demo-credential path. Provider-neutral conversation telemetry APIs and the
server-credential contract remain available in every variant.

The internal capability marker is the reviewed target resource
`SingleGreenDemo/SingleGreenInternalCapabilities.txt`; its exact content is
`diagnostics-demo-credentials-v1` followed by a newline. User configurations
explicitly exclude this resource. Artifact scanners verify both presence and
absence in the built `.app`; source guards alone are not sufficient evidence.

Test sources remain versioned in the repository and in a separate test target.
Neither product embeds the test bundle or test source in its distributed App.

## Branch contract

`main` is the canonical source for both products, including all four configs,
both schemes, capability flags, source, tests, Packages, project definitions,
and documentation. `codex/internal-debug` is retained as the owner's delivery
pointer. It is a zero-delta pointer to an explicitly reviewed commit already on
`main`; it is not a second development lane and must not carry tracked product
differences. The local PR-03 checker and two-workflow authorization/writer
design are implemented; remote pointer bootstrap remains separately authorized
and pending hosted validation.

## Log privacy contract

Internal export contains only timestamps, app/build metadata, lifecycle
changes, conversation phase/outcome, elapsed milliseconds, and typed failure
codes. It must never contain API keys, credentials, speech audio, transcripts,
user or assistant message bodies, teleprompter scripts, search results, or
prompts. User variants have no storage or export path.

## Validation and maintenance

Use `xcodebuild -list` as the source of truth for available schemes and
configurations. Current builds and tests must name one of the two schemes and
one of the four configurations; historical records may retain the command
that was actually run, labelled as historical.

Product fixes land on `main` first. The PR-03 checker verifies equality with
the freshly fetched current `origin/main`, exact commit/tree equality, and zero
tracked delta before promoting the internal pointer. An older reviewed commit
is rejected because a workflow sourced from the pushed commit may not contain
PR-03. Its exact invocation is:

```text
scripts/check_internal_branch_policy.sh REVIEWED_MAIN_SHA MAIN_SHA INTERNAL_SHA
```

The trusted push flow uses `github.event.after` for the reviewed SHA,
`GITHUB_SHA` for the internal SHA, and an explicitly fetched `origin/main` for
the main SHA, in that order. Pull requests targeting `codex/internal-debug`
and workflow-dispatch review input are rejected. CI's complete User/Internal
Debug/Release matrix is implemented locally: Debug tests are followed by a
separate clean App-only build because XCTest hosts embed XCTest support; both
Debug and Release artifacts are scanned for their variant capabilities.

The main ruleset `21847803` and internal integrity ruleset `21848414` are active
with no bypass. A separate attempted GitHub Actions writer-bypass ruleset
failed HTTP 422, so no exclusive writer identity is claimed. The remote branch
is absent pending post-merge hosted validation and authorized bootstrap; no PAT
or repository secret is used.

The separate internal Bundle ID intentionally creates an isolated settings
domain, App sandbox, and Keychain context. Internal first launch therefore
requires one-time settings and credential re-entry; PR-02 does not copy or
migrate user-variant data.
