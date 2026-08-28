# Minimal WebRTC VAD source distribution

This directory records the legal and provenance material for the minimal
WebRTC VAD source closure compiled by `CWebRTCVAD`. The upstream code is pinned
to commit `1e7f4c3c39e1aacaf8884452f80cd82749b1f8f1`, tree
`9e1c614027e41b4885cb3712cd9b2444388fac73` from
`https://webrtc.googlesource.com/src`.

`provenance.json` is the authoritative machine-readable inventory. It lists
exactly 11 unmodified upstream C files, 12 unmodified upstream headers, 11
project-owned one-source visibility wrappers, one project-owned compatibility
C file, one project-owned adapter header, and the required legal files. Run
`bash Scripts/verify_webrtc_vad_vendor.sh` from the package root to reject
hash drift, missing files, or extra C/header translation inputs.

The included synthetic tests and build checks establish API and integration
behavior only. They are not evidence of speech-detection quality, false-positive
or false-negative rates, power use, device behavior, or real-service behavior.
