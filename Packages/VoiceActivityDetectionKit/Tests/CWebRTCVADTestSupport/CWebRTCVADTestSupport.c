#include "CWebRTCVADTestSupport.h"

#include <stddef.h>

typedef void* (*SGDWebRTCVADAllocator)(size_t size);

extern SGDWebRTCVADHandle* SGDWebRtcVad_CreateWithAllocator(
    SGDWebRTCVADAllocator allocator);

static void* FailingAllocator(size_t size) {
  (void)size;
  return NULL;
}

SGDWebRTCVADHandle* SGDWebRtcVad_CreateWithFailingAllocation(void) {
  return SGDWebRtcVad_CreateWithAllocator(FailingAllocator);
}
