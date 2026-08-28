#ifndef C_WEBRTC_VAD_TEST_SUPPORT_H_
#define C_WEBRTC_VAD_TEST_SUPPORT_H_

#include "CWebRTCVAD.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#endif

SGDWebRTCVADHandle* _Nullable
SGDWebRtcVad_CreateWithFailingAllocation(void);

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#ifdef __cplusplus
}
#endif

#endif  // C_WEBRTC_VAD_TEST_SUPPORT_H_
