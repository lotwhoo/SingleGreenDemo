# CI workflow

Status: redesigned locally on 2026-08-31; hosted behavior is unverified until
the next upload.

This document is the source of truth for the repository's CI shape. The
protected check name remains `Required CI`; no ruleset-facing check is renamed.

## Event policy

Pull requests use a deterministic, fail-closed impact plan. The planner reads
the changed merged tree and the reverse dependency closure in
`config/architecture-boundaries.json`. It selects the smallest safe set of
expensive jobs. Unknown paths, malformed Git topology, manifests, project
files, configuration, CI, security, scripts, and other high-risk changes fall
back to the full matrix. A path filter is not used as a substitute for the
planner.

For a pull request, both the planner executable and architecture configuration
are extracted from the exact base SHA, while the comparison still targets the
synthetic merge checkout. A PR therefore cannot change its own planner to
under-select itself. During the one-time rollout, if the base does not yet
contain the planner, the workflow emits a hard-coded full plan; it never runs
the merge-controlled planner selectively.

Pushes to `main`, direct safety-fallback pushes to `codex/internal-debug`, and
no-input manual diagnostic runs execute the full matrix.
The internal delivery pointer is promoted from an exact reviewed `main` SHA;
promotion itself does not run a third full macOS certification.

## Layers

Every PR runs the cheap, fail-closed layer:

- impact planning and branch-contract validation;
- repository hygiene, architecture, privacy, security, and configuration
  checks.

The planner then controls these expensive layers:

- affected package tests, including reverse dependents;
- App Debug tests and clean App-only artifact builds when App behavior may be
  affected;
- User/Internal Release builds for production package source and App changes,
  including code compiled only outside `DEBUG`;
- coverage for directly affected production packages and directly changed
  package-test owners;
- public API checks when public API or package-contract inputs change.

`Required CI` waits for every layer and fails closed. An optional job must be
`success` when planned and exactly `skipped` when not planned; cancellation,
failure, or an unrecognized result is not accepted. This preserves one stable
required check while allowing documentation-only and narrow package changes
to avoid unrelated macOS work.

## Coverage artifact boundary

The coverage gate keeps the existing package thresholds and accepts an
explicit validated package selection. CI uploads only the human-readable
summary and package report files. Derived data, build products, object files,
and other temporary trees are not uploaded. This reduces transfer time and
retention cost without changing the measured gate.

## Internal promotion

The authorization and writer workflows retain the exact-main, exact-check,
fast-forward, and zero-delta protections. After promotion, a lightweight
read-only verifier fetches the current `main` and `codex/internal-debug` refs
and requires both to equal the promoted SHA. It performs no checkout, build,
test, dispatch, workflow-run polling, or write operation. Its two ref reads use
a three-attempt bounded transport retry; successful responses still have to
pass exact SHA equality. The normal promotion path reuses the already
successful `Required CI` result for that exact main SHA.

The no-input full internal run remains available as a manual diagnostic and is
not a normal promotion prerequisite. Its evidence must be labelled separately
from `Required CI`.

## Operating procedure

1. Make the change on a feature branch and open a PR.
2. Let the impact planner select the required gates; investigate any
   fail-closed full fallback rather than bypassing it.
3. Merge only after `Required CI` succeeds.
4. Promote the exact successful main SHA through the authorized workflow.
5. Use the manual full internal run only for diagnosis or an explicitly
   requested extra certification.

The redesign is a local contract until a subsequent upload proves the hosted
workflow, protected checks, artifact boundary, and promotion verifier
end-to-end.

## Local validation evidence

The 2026-08-31 pre-upload validation passed the repository's architecture,
public API, documentation, privacy, secret, release-evidence, branch-policy,
ruleset, coverage-scope, and simulator-destination gates. The new focused
contracts also passed:

- impact planner unit tests: 23/23;
- CI workflow mutation fixtures: 122/122 rejected;
- internal branch policy fixtures: 25/25;
- internal ruleset fixtures: 63/63;
- build flavor fixtures: 31/31;
- coverage selection and bounded promotion-pointer retry fixtures.

These results validate the local files and deterministic fixtures only. They
do not replace the pending hosted pull-request run, hosted `main` run, or the
first optimized protected promotion.
