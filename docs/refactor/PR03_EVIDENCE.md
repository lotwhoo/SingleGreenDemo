# PR-03 evidence: delivery pointer and four-variant CI contract

- Status: local implementation complete; GitHub remote enforcement BLOCKED
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
workflow mutation suite rejects missing internal triggers, shallow checkout,
missing matrix rows or scanners, reused test derived data, swapped scanners,
missing branch-policy invocation, and untrusted workflow-dispatch review input.

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
| Branch-policy fixtures | 24/24 passed | local terminal run |
| CI workflow mutations | 9/9 rejected as expected | local terminal run |
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

The remote check `git ls-remote` confirmed that
`origin/codex/internal-debug` is absent at this time; `origin/main` resolved to
`aadc54a`. The current local worktree is dirty, so it is not promotion
evidence. No hosted CI run, remote branch bootstrap, commit, push, device
install/launch, or live-provider validation is claimed by this record.

Remote branch bootstrap and promotion require separate explicit release
authorization after the external ruleset requirements above are satisfied.
