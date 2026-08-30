# User and internal product variants

## Current CI and promotion contract

The current local CI design is documented in [CI workflow](./CI_WORKFLOW.md).
PRs use deterministic fail-closed impact selection, while cheap branch,
hygiene, architecture, privacy, and security checks always run. `main` pushes
and no-input manual runs are full. The protected aggregate remains
`Required CI`; an optional expensive job is accepted only when its planner
decision and result agree exactly. Coverage uploads contain reports only.

Promotion reuses the successful `Required CI` result for the exact protected
`main` SHA. After the zero-delta fast-forward update, it performs a lightweight
read-only fresh equality check for the promoted SHA, `main`, and
`codex/internal-debug`; it does not dispatch a third full CI run. The manual
full internal run remains diagnostic. The redesign is local until the next
upload; the detailed historical hosted paragraphs below retain their original
facts and are superseded for the new workflow shape.

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
design are implemented; the narrow bootstrap succeeded and the pointer is
present at the audited ref below. Steady-state promotion on a genuinely new
protected `main` SHA remains pending.

The owner authorization job retains only read permissions plus
`statuses: write`. After current-main and Required-CI validation it posts one
success commit status linked to its exact in-progress job. The writer requires
both that latest exact status and the original completed job
check/suite/app-15368 linkage, so status-only authorization fails closed. After
a successful push and postcheck, a short job with only `actions: write` and
`contents: read` freshly revalidates main/internal/promoted equality before one
explicit dispatch. A separate job with `actions: read`, `checks: read`, and
`contents: read` performs the bounded exact-run verification, then freshly
requires main/internal/expected equality again before success, so the write
token is not retained while waiting.

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

Ruleset snapshots are validated independently with:

```text
scripts/check_internal_ruleset_contract.sh {steady|bootstrap} RULESET_JSON
```

`steady` requires both app-15368 checks; `bootstrap` is the audited first-ref
shape that retains only app-15368 `Required CI`. Both modes require the exact
ruleset identity, active enforcement, no bypass, the single internal target,
deletion/non-fast-forward/linear-history rules, and
`do_not_enforce_on_create=false`.

The trusted push flow uses `github.event.after` for the reviewed SHA,
`GITHUB_SHA` for the internal SHA, and an explicitly fetched `origin/main` for
the main SHA, in that order. Pull requests targeting `codex/internal-debug`
and workflow-dispatch review input are rejected. A no-input CI
`workflow_dispatch` is accepted only at the exact internal ref when checkout,
fresh main, and fresh internal SHAs are identical. Its aggregate is named
`Internal post-promotion CI`, never the ruleset-facing `Required CI`; the
writer validates its exact run metadata and aggregate
job/check/suite/details/app-15368 linkage within fixed bounds. CI's complete
User/Internal Debug/Release matrix is implemented locally: Debug tests are
followed by a separate clean App-only build because XCTest hosts embed XCTest
support; both Debug and Release artifacts are scanned for their variant
capabilities.

The main ruleset `21847803` and internal integrity ruleset `21848414` are active
with no bypass. A separate attempted GitHub Actions writer-bypass ruleset
failed HTTP 422, so no exclusive writer identity is claimed. The remote branch
is present at audited ref
`eb21fa1aa9958075a81fbd0887619c5000975665`; no PAT or repository secret is
used. Steady-state new-SHA promotion remains pending.

Steady-state writer run `33310076996` failed twice for main
`34981ff62512293b62f74899b8cd5c7ddad25782` with the identical sole GH013
missing-authorization-check detail, including a diagnostic rerun several
minutes later. The exact authorization job check remained successful and
app-15368 linked, so bounded retry was rejected as a structural non-fix. The
local protocol now adds the separately verified commit status described above
and an explicit post-push CI dispatch. The ruleset remains unchanged; hosted
proof of the new protocol is still pending.

The separate internal Bundle ID intentionally creates an isolated settings
domain, App sandbox, and Keychain context. Internal first launch therefore
requires one-time settings and credential re-entry; PR-02 does not copy or
migrate user-variant data.
