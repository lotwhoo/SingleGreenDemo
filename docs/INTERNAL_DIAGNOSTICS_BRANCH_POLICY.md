# User and internal diagnostics branches

## Branch contract

- `main` is the user-facing branch. Its Release build does not define
  `INTERNAL_DIAGNOSTICS`, so the debug toggle, safe-area overlay, diagnostics
  panel, in-memory diagnostic log, export code path, and text-adventure debug
  logging are compiled out or inactive.
- `codex/internal-debug` is the owner's internal branch. Both App target build
  configurations define `INTERNAL_DIAGNOSTICS`; it exposes the diagnostics
  panel and one-tap log export while retaining the same product code.
- Test sources stay in source control and in the separate test target. Xcode
  does not embed that target or its source files in the user `.app`.

## Log privacy contract

The export contains only timestamps, app/build metadata, lifecycle changes,
conversation phase/outcome, elapsed milliseconds, and typed failure codes. It
must never contain API keys, credentials, speech audio, transcripts, user or
assistant message bodies, teleprompter scripts, search results, or prompts.

## Maintenance

Product fixes land on `main` first. The internal branch then fast-forwards or
merges `main` and preserves only its compilation-condition delta. A user release
must pass the Release credential-isolation and secret-scan gates. The internal
branch must additionally build with `INTERNAL_DIAGNOSTICS` and exercise export.
