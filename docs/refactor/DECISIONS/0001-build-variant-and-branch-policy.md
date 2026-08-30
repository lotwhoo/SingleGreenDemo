# ADR 0001: Build variants and branch policy

- Status: Accepted; PR-02 and local PR-03 contract implemented; remote
  enforcement blocked
- Date: 2026-08-30
- First implementation: PR-02

## Context

The project needs a user product with no owner diagnostics or local demo
credential capability and an owner-internal product with debug controls and
one-tap diagnostics export. Maintaining duplicate business implementations on
`main` and `codex/internal-debug` would make fixes, concurrency invariants,
tests, and provider behavior drift over time. The current Xcode project has only
`Debug` and `Release`, so the build configuration also carries product identity
implicitly.

Tests must remain versioned and reviewable even though no test source or test
bundle belongs in the distributed user `.app`.

## Decision

Use one business-code line and the existing shared `SingleGreenDemo` App target
with two explicit product schemes and four XCConfig-backed configurations. PR-02
does not add a second App target:

- `SingleGreenUser`: `User-Debug` and `User-Release`.
- `SingleGreenInternal`: `Internal-Debug` and `Internal-Release`.

Capability injection happens at App composition. User variants receive no-op or
unavailable internal capability implementations. Internal variants receive the
reviewed diagnostics/export and local demo-credential implementations. Feature
code must not consult a global runtime registry to discover these capabilities.

PR-02 includes a mechanical compile-guard migration because configuration names
alone cannot prove capability isolation. Provider-neutral public
`ConversationTelemetryEvent`, `ConversationTelemetrySink`,
`NoopConversationTelemetry`, and shared conversation composition remain
unconditional. Only the App-local `ConversationTelemetryStore`,
diagnostics/export UI, lifecycle string recording, and internal sink selection
are available under `INTERNAL_DIAGNOSTICS`; User composition injects
`NoopConversationTelemetry` and produces no stored or exportable User logs.
Demo credential types, UI, and composition are available only under
`INTERNAL_DEMO_CREDENTIALS`, while the provider-neutral server credential
contract remains unconditional. Generic `DEBUG` controls compiler/debug behavior
only. This migration preserves public Package API and the existing internal
workflow/storage behavior while deliberately removing owner-only capabilities
from User-Debug and User-Release.

The internal bundle identifier intentionally uses an isolated App sandbox,
settings domain, and Keychain context. This is a compatibility break for locally
stored owner setup: the owner performs one-time settings and credential re-entry
after installing the internal product. PR-02 does not add shared Keychain access
or copy data between bundle identities. A later migration requires an explicit
security, entitlement, rollback, and data-lifecycle review.

`main` is the canonical source for both products, including complete Internal
XCConfigs, the shared `SingleGreenInternal` scheme, capability flags, identity,
source, tests, Packages, project definitions, and CI. `codex/internal-debug` is
retained as the owner's promotion/delivery pointer, not as a development lane.
Promotion moves that ref to an explicitly reviewed commit already on `main`.
The two branches therefore satisfy the user's two-branch delivery workflow
without maintaining two tracked product definitions.

PR-03 now enforces the following exact branch policy after fetching both refs:

- Promotion receives a reviewed-main SHA that must equal the freshly fetched
  current `origin/main` SHA and must resolve to the exact commit selected for
  internal delivery.
- `origin/codex/internal-debug` must resolve to that same reviewed-main SHA. A
  defensive tree-hash comparison and `git diff --exit-code` must also report
  exact equality.
- Zero tracked delta means zero exceptions. The internal ref may not modify
  Internal XCConfigs or scheme, product identity, capability/compiler/linker
  flags, signing, provisioning, entitlements, source, tests, Packages, project,
  CI, documentation, or release metadata.
- Version overrides, release notes/evidence, credentials, signing identities,
  provisioning, notarization/export settings, and delivery destinations are
  external injected release operations. They are not committed as an internal
  branch delta and never contain secrets in tracked files.

The checker contract is `scripts/check_internal_branch_policy.sh
REVIEWED_MAIN_SHA MAIN_SHA INTERNAL_SHA`. It validates full lowercase commit
SHAs, then commit objects, current-main equality, exact internal/reviewed SHA
equality, tree equality, and an empty diff, in that order. The trusted push flow sources the reviewed SHA
from `github.event.after`, the internal SHA from `GITHUB_SHA`, and main from an
explicitly fetched `origin/main`; it rejects pull requests targeting the
delivery pointer and does not trust workflow-dispatch input.

The policy test suite uses deterministic temporary Git fixtures. Its positive
fixture points both refs at the same current reviewed canonical commit. A
reviewed commit older than freshly fetched `origin/main` is rejected, because
a workflow sourced from the pushed commit may not contain PR-03.
Negative fixtures cover a SHA not on `main`, a divergent/empty internal commit,
an Internal XCConfig change, a `SingleGreenInternal` scheme change, and a shared
source/test/Package/project/CI change. Each negative must fail for its expected
reason rather than merely returning a nonzero exit status.

Tests stay in source control on `main` and in a separate test target. Neither
user nor internal `.app` embeds test source or the test bundle.

## Consequences

Benefits:

- User and internal behavior share the same domain and orchestration code.
- Product identity and internal capabilities become independently auditable.
- Separate bundle identities prevent accidental settings or credential sharing;
  the owner pays a one-time re-entry cost.
- Release artifact scans can prove capability absence instead of relying on a
  branch name or the generic `DEBUG` flag.
- Both compositions can be tested before changes merge.

Costs and constraints:

- The one shared App target has four configurations and two product schemes to
  maintain.
- CI must build and inspect both products.
- The internal delivery branch is an operational promotion pointer with no
  tracked customization; internal artifacts are created by external release
  operations from its canonical commit.
- Local credentials remain an internal convenience, never a production
  credential-distribution design.

## Rejected alternatives

- **Duplicate product branches:** rejected because fixes and invariants would
  diverge.
- **Allowlist Internal XCConfig or scheme changes on the delivery branch:**
  rejected because those are complete canonical product definitions on `main`;
  even a narrow tracked delta can drift from tested source and artifacts.
- **Use `DEBUG` as the internal switch:** rejected because optimization mode,
  owner identity, diagnostics, and credential capability are separate concerns.
- **Delete tests from the user source branch:** rejected because it removes the
  quality evidence needed to protect the user artifact; target membership and
  artifact scans provide the required isolation.
- **Introduce a global service locator:** rejected because it makes invalid
  capability combinations constructible and hides dependencies.
- **Adopt Tuist or another project generator in PR-02:** deferred until project
  scale demonstrates a stable payoff; XCConfig and schemes are sufficient now.

## Follow-up checks

PR-02 implemented the capability matrix in `../TARGET_ARCHITECTURE.md` and
proved compile guards, unavailable/no-op User composition, isolated settings
and Keychain behavior, fail-closed credentials, unchanged public Package APIs,
and built artifacts locally. PR-03 implements current-main SHA equality,
exact commit/tree equality, zero-delta, and deterministic fixture gates for
promotion and pushes affecting either maintained branch. Remote bootstrap and
promotion remain separately authorized release operations; GitHub remote
enforcement is blocked until an independently controlled ruleset is configured.
