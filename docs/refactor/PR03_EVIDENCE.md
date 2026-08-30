# PR-03 evidence: delivery pointer and four-variant CI contract

- Status: local implementation complete; hosted baseline green; GitHub remote
  enforcement BLOCKED pending independent ruleset verification
- Date: 2026-08-30
- Scope: `codex/internal-debug` zero-delta policy, CI workflow guards, and the
  complete User/Internal Debug/Release build matrix

## Branch contract

The checker is invoked as:

```text
scripts/check_internal_branch_policy.sh REVIEWED_MAIN_SHA MAIN_SHA INTERNAL_SHA
```

It validates the three full, lowercase SHA-1 values in this order:

1. Validate syntax and require all three objects to be commits.
2. Require `REVIEWED_MAIN_SHA` to equal the freshly fetched current
   `origin/main` SHA.
3. Require `INTERNAL_SHA` to equal `REVIEWED_MAIN_SHA` exactly.
4. Compare the reviewed and internal tree hashes.
5. Require an empty `git diff --no-ext-diff` between the reviewed and internal
   commits.

The checker therefore has zero tracked exceptions: no source, tests, Packages,
project, CI, documentation, release metadata, Internal XCConfig, scheme,
identity, capability, signing, provisioning, or entitlement delta is allowed
on the delivery pointer. A pull request targeting `codex/internal-debug` is
rejected. Product fixes land on `main`; the internal ref is only a promotion
and delivery pointer.

For a trusted internal push event, CI obtains `MAIN_SHA` from an explicitly
fetched `origin/main`, obtains `REVIEWED_MAIN_SHA` from
`github.event.after`, obtains `INTERNAL_SHA` from `GITHUB_SHA`, first asserts
that the latter two are identical, and then calls the checker in the exact
three-SHA order above. `github.event.before`, a workflow-dispatch input, or an
untrusted branch input is not accepted as the reviewed commit.

## CI matrix and artifact boundary

The local workflow contract requires both schemes and all four configurations:

| Job | Product | Configuration | Required validation |
| --- | --- | --- | --- |
| App simulator | User | `User-Debug` | App XCTest, then clean App-only build and User artifact scan |
| App simulator | Internal | `Internal-Debug` | App XCTest, then clean App-only build and Internal capability scan |
| Release build | User | `User-Release` | generic Simulator build and User artifact scan |
| Release build | Internal | `Internal-Release` | generic Simulator build and Internal capability scan |

The Debug test command builds an XCTest host, so its derived-data product can
contain XCTest support artifacts. It must not be scanned as the distributed
App. CI therefore performs a separate clean generic Simulator App-only build
for each Debug row before scanning `SingleGreenDemo.app`. An initial attempt to
scan the XCTest host correctly failed; that failure led to this explicit
separation rather than weakening the artifact scanner.

The workflow also retains the package matrix, public API, architecture,
privacy, repository hygiene, build-flavor, and coverage gates. The exact
workflow mutation suite now rejects 56/56 tested mutations, including missing
internal triggers, shallow checkout,
missing matrix rows or scanners, reused test derived data, swapped scanners,
missing branch-policy invocation, and untrusted workflow-dispatch review input.
The hardened cases also cover missing/incorrect job dependencies, non-`always`
Required CI conditions, `continue-on-error` at job or step level, shell-level
promotion write/ordering/post-check omissions, and any unexpected write
permission or write step in a third workflow.

`Required CI` is a stable, always-running aggregation job. It depends on
`branch-contract`, `package-matrix`, `app-simulator`, `release-build`,
`coverage-and-hygiene`, and `public-api`, and fails closed unless every
dependency result is exactly `success`. Its check name is the ruleset-facing
required check. The promotion workflow is a no-input `workflow_dispatch` with
exactly two jobs: `Internal promotion authorization` and `Promote authorized
main`. Authorization checks the current `main` event SHA, checkout SHA, and
freshly fetched `origin/main`, then requires the latest successful `Required CI`
check for that exact SHA from GitHub Actions app ID `15368`. Promotion
re-checks the same trust chain, proves the existing internal pointer can be
fast-forwarded, pushes without force, and runs the branch checker again after
fetching both refs.

All GitHub Actions are pinned by full commit SHA: `actions/checkout` uses
`3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1), and
`actions/upload-artifact` uses `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`
(v4). The newer Required CI/promotion changes are locally checked but still
await their own hosted run.

## Three-layer remote delivery procedure

Remote enablement requires three independently auditable layers:

1. **Workflow layer:** CI runs the branch contract and full matrix on both
   maintained refs; `Required CI` is always run and fail-closed. The no-input
   promotion workflow authorizes only current `main`, verifies the exact
   successful Required CI check from app `15368`, performs a fast-forward-only
   pointer update, and re-checks the result.
2. **Ruleset layer:** an externally controlled GitHub ruleset/branch protection
   must make `Required CI` required, restrict `codex/internal-debug` updates to
   the controlled promotion path, prohibit force-push and deletion, and reject
   a direct pull-request lane. This control must not be self-authorized by the
   promoted commit.
3. **Pointer layer:** bootstrap only after layers one and two are verified,
   using the no-input promotion workflow from current `main`. Recovery repeats
   authorization against freshly fetched current `origin/main`, refuses stale
   or divergent internal state, and advances only by fast-forward. If the
   pointer is divergent, stop and repair it under separately authorized release
   procedure; never force-push or delete it as implicit recovery.

## Remote enforcement status

GitHub enablement is **BLOCKED / not complete**. Before the delivery pointer
can be bootstrapped or promoted, an independently controlled GitHub ruleset or
branch-protection configuration must:

- restrict updates to `codex/internal-debug` to the controlled promotion path;
- prohibit force-push, deletion, and a direct pull-request development lane;
- require the current branch-policy and complete User/Internal matrix checks.

The remote branch is currently absent. No ruleset or branch bootstrap was
configured because that operation was not authorized. The local PR-03
implementation can be complete while remote enforcement remains disabled.

## Local evidence

| Evidence | Result | Location |
| --- | --- | --- |
| Branch-policy fixtures | 25/25 passed | local terminal run |
| CI workflow mutations | 56/56 rejected as expected | local terminal run |
| CI workflow live guard | passed | local terminal run |
| User Debug App XCTest | 83/83 passed, 0 failed/skipped | `/private/tmp/SingleGreenDemo-PR03-DebugTests.W5UylJ/user.xcresult` |
| User Debug App-only build and scan | passed | `/private/tmp/SingleGreenDemo-PR03-DebugTests.W5UylJ/user-artifact` |
| Internal Debug App XCTest | 92/92 passed, 0 failed/skipped | `/private/tmp/SingleGreenDemo-PR03-DebugTests.W5UylJ/internal.xcresult` |
| Internal Debug App-only build and scan | passed | `/private/tmp/SingleGreenDemo-PR03-DebugTests.W5UylJ/internal-artifact` |
| User/Internal Release builds and scans | passed | `/private/tmp/SingleGreenDemo-PR03-Release.1SzF1g` |

## Full local quality gates

The fresh full gate run passed from
`/private/tmp/SingleGreenDemo-PR03-Gates.c8Ray8/coverage`:

- Strict-concurrency Package tests: **515/515** passed, in package order
  `StreamingTextKit` 7, `VoiceChatDomain` 16, `VoiceActivityDetectionKit` 43,
  `SingleGreenGlassesKit` 231, `SingleGreenConversationAdapters` 24, `LLMKit`
  85, and `VoiceChatCore` 109.
- `VADBenchmark` and `ASRCLI` product builds passed.
- Public API, architecture, privacy, repository hygiene, secret, documentation,
  build-flavor, CI workflow, and branch-policy gates all passed.
- Coverage passed every configured threshold: `StreamingTextKit` 85.23% (70),
  `VoiceChatDomain` 99.07% (75), `VoiceActivityDetectionKit` 95.47% (80),
  `SingleGreenGlassesKit` 88.86% (65), `SingleGreenConversationAdapters` 98.02%
  (70), `LLMKit` 89.98% (60), and `VoiceChatCore` 76.19% (55).

## Hosted CI status

The first public hosted CI run exposed a portability defect in lowercase SHA
validation under a UTF-8 locale: uppercase SHA input was affected by locale
collation behavior. The implementation was fixed by forcing `LC_ALL=C` and by
adding a UTF-8 locale regression case. The local branch-policy fixture count is
now **25/25** passed. Hosted run **33299053875** subsequently passed after the
locale fix; all package, App, Release, public API, and coverage jobs were green.
This is the hosted baseline for the locale fix. The newer Required CI/promotion
changes still await their own hosted run and are not covered by that run's
success.

The remote check `git ls-remote` confirmed that
`origin/codex/internal-debug` is absent at this time; `origin/main` resolved to
`aadc54a`. The current local worktree is dirty, so it is not promotion
evidence. No remote ruleset, branch bootstrap, promotion, commit, push, device
install/launch, merge, or live-provider validation is claimed by this record.

Remote branch bootstrap and promotion require separate explicit release
authorization after the external ruleset requirements above are satisfied.
