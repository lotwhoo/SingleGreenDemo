#include <stdlib.h>

#include "common_audio/vad/include/webrtc_vad.h"
#include "common_audio/vad/vad_core.h"
#include "include/CWebRTCVAD.h"

#if !defined(__APPLE__) || !defined(__clang__) || !defined(__GNUC__)
#error "CWebRTCVAD requires Apple Clang with GNU-compatible builtins."
#endif

#if !defined(__has_builtin)
#error "CWebRTCVAD requires compiler builtin feature detection."
#elif !__has_builtin(__builtin_clz) || !__has_builtin(__builtin_clzll)
#error "CWebRTCVAD requires __builtin_clz and __builtin_clzll."
#endif

#define SGD_WEBRTC_VAD_HIDDEN __attribute__((visibility("hidden")))

typedef void* (*SGDWebRTCVADAllocator)(size_t size);

// This non-public seam is linked only by CWebRTCVADTestSupport to inject a
// deterministic NULL allocator. Production callers use SGDWebRtcVad_Create.
SGD_WEBRTC_VAD_HIDDEN SGDWebRTCVADHandle* SGDWebRtcVad_CreateWithAllocator(
    SGDWebRTCVADAllocator allocator) {
  if (allocator == NULL) {
    return NULL;
  }

  VadInstT* instance = (VadInstT*)allocator(sizeof(VadInstT));
  if (instance == NULL) {
    return NULL;
  }
  instance->init_flag = 0;
  return (SGDWebRTCVADHandle*)instance;
}

SGDWebRTCVADHandle* SGDWebRtcVad_Create(void) {
  return SGDWebRtcVad_CreateWithAllocator(malloc);
}

int SGDWebRtcVad_Init(SGDWebRTCVADHandle* handle) {
  return WebRtcVad_Init((VadInst*)handle);
}

int SGDWebRtcVad_SetMode(SGDWebRTCVADHandle* handle, int mode) {
  return WebRtcVad_set_mode((VadInst*)handle, mode);
}

int SGDWebRtcVad_Process(SGDWebRTCVADHandle* handle,
                         int sample_rate_hertz,
                         const int16_t* samples,
                         size_t sample_count) {
  return WebRtcVad_Process((VadInst*)handle, sample_rate_hertz, samples,
                           sample_count);
}

void SGDWebRtcVad_Free(SGDWebRTCVADHandle* handle) {
  WebRtcVad_Free((VadInst*)handle);
}

// WebRTC's C DCHECK contract requires a non-returning callback. Do not log
// arguments here: they can contain dynamic context and this target handles PCM.
SGD_WEBRTC_VAD_HIDDEN _Noreturn void rtc_FatalMessage(const char* file,
                                                       int line,
                                                       const char* msg) {
  (void)file;
  (void)line;
  (void)msg;
  abort();
}
