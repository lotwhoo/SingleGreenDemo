#ifndef C_WEBRTC_VAD_H_
#define C_WEBRTC_VAD_H_

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__)
#define SGD_WEBRTC_VAD_EXPORT __attribute__((visibility("default")))
#else
#define SGD_WEBRTC_VAD_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SGDWebRTCVADHandle SGDWebRTCVADHandle;

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin
#endif

SGD_WEBRTC_VAD_EXPORT SGDWebRTCVADHandle* _Nullable
SGDWebRtcVad_Create(void);
SGD_WEBRTC_VAD_EXPORT int SGDWebRtcVad_Init(SGDWebRTCVADHandle* handle);
SGD_WEBRTC_VAD_EXPORT int SGDWebRtcVad_SetMode(SGDWebRTCVADHandle* handle,
                                               int mode);
SGD_WEBRTC_VAD_EXPORT int SGDWebRtcVad_Process(
    SGDWebRTCVADHandle* handle,
    int sample_rate_hertz,
    const int16_t* samples,
    size_t sample_count);
SGD_WEBRTC_VAD_EXPORT void SGDWebRtcVad_Free(SGDWebRTCVADHandle* handle);

#if defined(__clang__)
#pragma clang assume_nonnull end
#pragma clang diagnostic pop
#endif

#ifdef __cplusplus
}
#endif

#endif  // C_WEBRTC_VAD_H_
