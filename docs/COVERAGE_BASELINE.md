# Production source coverage baseline

Reviewed locally on 2026-08-28 for the provider-neutral M6 Stage 2A state. The gate accepts only files whose canonical path is under that package's own production `Sources/<package-name>/` directory. Test, generated, dependency-package, benchmark-support, executable, and `Tools/ASRCLI` files are excluded. `scripts/test_coverage_scope.sh` pins this behavior with mixed production-target, benchmark-support, dependency, and test paths. ASRCLI and VADBenchmark are reported separately through strict-concurrency, warnings-as-errors product builds; no executable line-coverage percentage is claimed. Stage 1's report at `/private/tmp/SingleGreenDemo-M6-P1-Coverage` remains historical; current provider-neutral evidence is recorded in the task record.

| Package | Covered / source lines | Baseline | Gate |
| --- | ---: | ---: | ---: |
| StreamingTextKit | 75 / 88 | 85.23% | 70% |
| VoiceChatDomain | 106 / 107 | 99.07% | 75% |
| VoiceActivityDetectionKit | 379 / 397 | 95.47% | 80% |
| SingleGreenGlassesKit | FinalQA2 measured baseline | 93.38% | 65% |
| LLMKit | Post-provider-neutral measured baseline | 89.89% | 60% |
| VoiceChatCore | M7 PR2 measured baseline | 75.79% | 55% |

The initial gates are intentionally below the measured baseline. They catch large regressions while leaving room for platform seams and provider adapters that require higher-level tests. Line coverage is not evidence of real-service, physical-device, accessibility, or optical behavior.

The generated reports and package build products are local artifacts and are ignored by Git. CI is configured to upload the reports, but the GitHub-hosted workflow has not been executed as part of this local review.
