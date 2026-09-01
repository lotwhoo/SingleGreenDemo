# Production source coverage baseline

## CI collection policy

The coverage thresholds and source-scope rules below remain unchanged. The
current CI selects directly affected production packages and directly changed
package-test owners for PR coverage, then uploads only summary/package report
files; build products and derived data are not uploaded. Pushes to `main` and
no-input manual diagnostics still run the full coverage matrix. The redesigned
hosted collection behavior is unverified until the next upload.

Reviewed locally on 2026-08-28 for the combined M7 PR3+PR4 state and the isolated M7 PR5 rerun. The gate accepts only files under the explicitly selected production library targets in a package. Most packages retain their canonical `Sources/<package-name>/` target; after the M13 split, `LLMKit` intentionally aggregates `LLMCore`, `AgentCore`, `OpenAICompatibleTransport`, `BochaSearchAdapter`, and the compatibility target. Test, generated, dependency-package, benchmark-support, executable, and `Tools/ASRCLI` files are excluded. `scripts/test_coverage_scope.sh` pins this behavior with multiple selected production targets plus benchmark-support, dependency, and test paths. ASRCLI and VADBenchmark are reported separately through strict-concurrency, warnings-as-errors product builds; no executable line-coverage percentage is claimed. Earlier M6/PR1/PR2/PR3 reports remain historical. The PR5 isolated measurement is `SingleGreenGlassesKit` **93.91%** and `SingleGreenConversationAdapters` **98.02%**; the combined PR3+PR4 measurement remains the superseded comparison at SGK **94.08%**.

| Package | Covered / source lines | Baseline | Gate |
| --- | ---: | ---: | ---: |
| StreamingTextKit | 75 / 88 | 85.23% | 70% |
| VoiceChatDomain | 106 / 107 | 99.07% | 75% |
| VoiceActivityDetectionKit | 379 / 397 | 95.47% | 80% |
| SingleGreenGlassesKit | PR5 isolated measured baseline | 93.91% | 65% |
| LLMKit | 925 / 1029 | 89.89% | 60% |
| VoiceChatCore | 2051 / 2706 | 75.79% | 55% |
| SingleGreenConversationAdapters | 347 / 354 | 98.02% | 70% |

The initial gates are intentionally below the measured baseline. They catch large regressions while leaving room for platform seams and provider adapters that require higher-level tests. Line coverage is not evidence of real-service, physical-device, accessibility, or optical behavior. The adapter package's 98.02% figure is from its current 347/354 source-line report; the SingleGreenGlassesKit figure is the isolated PR5 measurement. The earlier combined PR3+PR4 SGK measurement of 94.08% is historical and superseded for the current PR5 evidence.

The generated reports and package build products are local artifacts and are ignored by Git. CI is configured to upload the reports, but the GitHub-hosted workflow has not been executed as part of this local review.
