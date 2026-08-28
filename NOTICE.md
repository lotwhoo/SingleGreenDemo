# Notice and license status

SingleGreenDemo contains first-party Swift source plus Apple platform frameworks. Its six local Swift Package manifests use repository-local packages; `VoiceActivityDetectionKit` also vendors the reviewed minimal WebRTC VAD source closure described below.

`VoiceActivityDetectionKit` owns the provider-neutral VAD contract and the project-hidden WebRTC wrappers. The production detector is linked only by the `SingleGreenDemo` composition root; the independent AISettings path remains fail-closed and there is no energy fallback. `VADBenchmarkSupport` remains a non-product benchmark/test target with a synthetic classifier.

The vendored WebRTC files are governed by the accompanying upstream `LICENSE` (BSD-style), `PATENTS`, `AUTHORS`, and `provenance.json` under `Packages/VoiceActivityDetectionKit/ThirdParty/WebRTC/`. The `common_audio/third_party/spl_sqrt_floor/spl_sqrt_floor.h` implementation retains its upstream attribution and license requirements. These notices apply to those vendored files only; they do not license the whole repository. App Store and binary distributions must carry the applicable BSD/PATENTS/AUTHORS acknowledgements and preserve these files.

The repository does not currently contain a root `LICENSE` file. That is a release decision, not an implied license grant. Before any external distribution, the owner must choose and add the intended project license and re-run a dependency/license inventory for the exact candidate commit.

Provider names and trademarks mentioned in source or documentation belong to their respective owners. This notice is an engineering inventory, not legal advice.
