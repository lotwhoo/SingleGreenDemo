# Public API baselines

The reviewed snapshots in `xcode-26.6-swift-6.3.3/` cover eight library modules on macOS arm64 and iOS Simulator arm64 (16 JSON files total). They are compatibility artifacts, not generated build output.

The M8 dependency-group change updates only the two `SingleGreenGlassesKit` snapshots. Each reviewed platform snapshot contains 39 additions and 0 removals; the other 14 snapshots remain unchanged. The retained flat `VoiceConversationDependencies` initializer and accessors are source-package compatibility measures, not a binary layout or ABI promise.

Check exact drift with `scripts/check_public_api_baselines.sh`.

An intentional API change requires review of both additions and removals, relevant package tests, and this explicit update:

```bash
scripts/update_public_api_baselines.sh --accept-current-api
```

The updater is blocked in CI and preserves the prior baseline if replacement fails. Concurrent updater invocations are a known P3 limitation. Snapshots are arm64-only by design; the textual pbxproj parser may need maintenance after future Xcode format changes.
