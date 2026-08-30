# ADR 0002: Impact-selective PR CI and exact-SHA promotion reuse

- Status: Accepted locally; hosted validation pending the next upload
- Date: 2026-08-30

## Context

The previous workflow repeated the complete package, App, Release, API, and
coverage matrix for a PR, the resulting `main` push, and internal promotion.
Recent runs showed approximately 28 minutes of wall-clock time for the PR and
main pair, with coverage reports contributing about 1.16 GiB per run. Most
documentation and narrow package changes do not affect every expensive gate.

## Decision

Keep `Required CI` as the protected aggregate and preserve the existing
workflow identities. Add a deterministic PR impact planner backed by
`config/architecture-boundaries.json`:

- ordinary package source changes select that package, its reverse dependents,
  direct-package coverage and API checks, App Debug when consumed by the App,
  and both Release variants so `#if !DEBUG` paths are compiled;
- package test changes select the owning package test and coverage gate;
- App changes select both App Debug and both Release variants, while known
  API-baseline changes select only the API gate;
- manifests, project/configuration files, CI, scripts, unknown paths,
  malformed Git state, and reviewed high-risk streaming/concurrency sources
  select the full matrix;
- `main` pushes, direct internal safety-fallback pushes, and no-input manual
  runs always select the full matrix.

The pull-request workflow extracts the planner and architecture configuration
from the exact base SHA and applies them to the synthetic merge comparison. If
the base does not yet contain the planner during initial rollout, the workflow
emits a hard-coded full plan instead of trusting the PR copy.

Cheap branch, hygiene, architecture, privacy, and security checks always run.
The aggregate accepts only `success` for planned jobs and exactly `skipped` for
unplanned jobs. Coverage accepts an explicit package list and uploads reports
only, not build trees.

Promotion reuses the already successful `Required CI` for the exact protected
`main` SHA. Its writer retains the existing authorization, current-main,
fast-forward, zero-delta, and branch-policy checks, then performs a lightweight
read-only equality check that fresh `main` and `codex/internal-debug` both point
to the promoted SHA. The two read-only ref requests use a fixed three-attempt
transport retry without weakening the equality predicate. A third full CI
dispatch is removed from normal promotion. Manual full internal certification
remains a diagnostic path.

## Consequences

Small PRs finish with less queue, build, and artifact-transfer time while
dependency changes still expand through the reviewed closure. Fail-closed
classification makes uncertainty expensive rather than silently untested.
The exact-SHA rule avoids claiming that a later run certifies a different tree.
The next upload must validate GitHub Actions behavior; this local decision is
not hosted evidence.

## Rejected alternatives

- Workflow-level path filters: rejected because they can suppress required
  checks and do not express reverse dependency closure.
- Always running the full PR matrix: rejected because it repeats unrelated
  work and large coverage transfers.
- A third post-promotion full CI run: rejected because the exact main SHA was
  already certified and the extra run adds delay without new tree evidence.
- Treating a manual internal run as `Required CI`: rejected because it could
  mint protected context outside the exact main certification path.
