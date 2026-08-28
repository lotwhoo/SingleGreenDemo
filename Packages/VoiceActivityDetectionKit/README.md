# VoiceActivityDetectionKit

`VoiceActivityDetectionKit` is the framework-neutral M6 foundation for local voice-activity endpointing. The package also exposes a separate, opt-in `WebRTCVoiceActivityDetection` product containing the approved production detector. Neither product captures audio, opens network connections, uploads PCM, or integrates with ASR/UI code.

## Production contract

- `VADPCMFrame` accepts exactly 20 ms of 16 kHz, mono, signed 16-bit little-endian PCM: 320 samples / 640 bytes.
- `VoiceActivityDetecting` is an actor-bound detector abstraction.
- `VADSegmenter` is a deterministic value-type state machine with bounded pre-roll, N-of-M onset hysteresis, internal/trailing silence forwarding, resume events, and exactly one silence or maximum-duration endpoint.
- `VoiceActivityDetectionPipeline` composes a detector actor with the pure segmenter while preserving detector errors. It serializes complete detect-and-consume operations in FIFO order; reset invalidates suspended older-generation work, and cancellation cannot publish a late observation into segmentation state.
- The approved Stage 2A policy uses 20 ms frames, a 300 ms bounded pre-roll, 3 speech frames in a 5-frame onset window, an 800 ms trailing-silence endpoint, a 20 s maximum segment, and a 15 s no-speech timeout. `VoiceChatCore` bounds both source and pending-upload queues and sends no audio to ASR before onset.

`VADBenchmarkSupport` is intentionally not a library product. Its simple energy detector exists only for deterministic tests and the aggregate-only benchmark executable; an application cannot select it as a package product.

## Production WebRTC adapter

The package keeps the dependency direction explicit:

```text
WebRTCVoiceActivityDetection -> VoiceActivityDetectionKit
WebRTCVoiceActivityDetection -> CWebRTCVAD
```

The provider-neutral `VoiceActivityDetectionKit` product does not import the C target. Applications opt into `WebRTCVoiceActivityDetection`, construct a `WebRTCVoiceActivityDetector`, and inject it through `VoiceActivityDetecting` at the composition root.

```swift
import WebRTCVoiceActivityDetection

let detector = try WebRTCVoiceActivityDetector(aggressiveness: .aggressive)
```

One actor-confined `VadInst` owns the detector state. Initialization validates allocation, initialization, and mode setup; processing consumes `VADPCMFrame.samples` rather than binding potentially unaligned byte storage. Reset reinitializes the same instance and reapplies its mode. Because the stable port has a non-throwing `reset()`, a reset failure is retained and surfaced by subsequent observations until a later reset succeeds.

WebRTC returns a binary speech decision. The adapter maps this to `speechProbability == 0` or `1` only for compatibility with `VoiceActivityObservation`; this value is not a calibrated probability or confidence score.

## Vendored dependency and legal inventory

`CWebRTCVAD` contains exactly 11 unmodified upstream C files and 12 unmodified upstream headers from WebRTC commit `1e7f4c3c39e1aacaf8884452f80cd82749b1f8f1`, plus project-owned `rtc_fatal_message.c` and its adapter header. Probe-only `min_max_operations.c`, `resample_by_2.c`, and `spl_init.c` are intentionally absent. Each upstream C file is excluded from direct SwiftPM compilation and included byte-for-byte by exactly one three-line project wrapper that pushes hidden visibility, includes one source, and pops visibility. This preserves 11 independent upstream translation units while making every upstream implementation symbol private. The public C header does not include or re-export WebRTC headers: it exposes only a project-owned opaque handle and five `SGDWebRtcVad_*` facade functions. The allocator-injection seam and fatal callback also have source-level hidden visibility. The checked create function is explicitly nullable, and the Swift adapter converts that optional pointer before constructing its handle, so allocation failure surfaces as `allocationFailed` instead of a force-unwrap trap or upstream `NULL` dereference. The compatibility fatal callback terminates without logging file names, messages, PCM, or dynamic data, and compile-time checks require Apple Clang with the GNU-compatible builtins used by the upstream headers. No ARM, NEON, or MIPS optimization flags are defined by this package.

Root WebRTC `LICENSE`, `PATENTS`, and `AUTHORS`, plus the SPL sqrt-floor license and provenance, are retained under `ThirdParty/WebRTC`. `ThirdParty/WebRTC/provenance.json` pins the commit, tree, exact file list, SHA-256 hashes, legal inventory, input contract, compiler assumptions, and unverified quality/device/service dimensions. `Package.swift` selects C11 without unsafe product flags so a tagged Git dependency remains consumable. The mandatory build verifier recompiles Release for iphoneos arm64, Simulator arm64, and Simulator x86_64 with `-Wall`, `-Wextra`, `-Wpedantic`, and `-Werror`.

Run the integrity gate independently with:

```bash
bash Packages/VoiceActivityDetectionKit/Scripts/verify_webrtc_vad_vendor.sh
bash Packages/VoiceActivityDetectionKit/Scripts/verify_webrtc_vad_public_surface.sh
bash Packages/VoiceActivityDetectionKit/Scripts/verify_webrtc_vad_builds.sh
```

Synthetic golden frames only protect deterministic API behavior. They do not establish speech accuracy, noise robustness, endpoint quality, power use, or physical-device behavior.

## Local verification

```bash
swift test --package-path Packages/VoiceActivityDetectionKit \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
swift build --package-path Packages/VoiceActivityDetectionKit \
  --target WebRTCVoiceActivityDetection \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
swift run --package-path Packages/VoiceActivityDetectionKit VADBenchmark
```

The benchmark prints only aggregate frame, segment, endpoint, and elapsed-time counters. It never prints PCM samples or inferred content.
