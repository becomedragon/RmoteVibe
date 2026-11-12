#ifndef RMV_RING_BUFFER_H
#define RMV_RING_BUFFER_H

#include <stdint.h>

// Shared layout for the menu-bar app (writer) and the HAL plug-in (reader).
// Both targets compile RingBuffer.c. Keep this header the only definition.

#define RMV_RING_SAMPLE_RATE 48000u
#define RMV_RING_CHANNELS 2u
#define RMV_RING_CAPACITY_FRAMES 48000u
#define RMV_SHM_NAME "/rmotevibe-mic-v1"
#define RMV_RING_MAGIC 0x524D5631u /* 'RMV1' */
#define RMV_RING_VERSION 1u

#define RMV_FEED_MAC 0u
#define RMV_FEED_SILENCE 1u
#define RMV_FEED_REMOTE 2u

// Pointer, not a char array, so the Swift overlay imports it as a C string.
extern const char *RMVDeviceUID;
extern const uint32_t RMVRingSampleRate;
extern const uint32_t RMVRingChannels;
extern const uint32_t RMVFeedMac;
extern const uint32_t RMVFeedSilence;
extern const uint32_t RMVFeedRemote;

// 0 on success. Any other value is errno. The segment is mode 0666 so the
// sandboxed coreaudiod process can map it. That is local-machine only.
int RMVRingOpenWriter(void);
void RMVRingCloseWriter(void);

// Maps an existing segment. 1 if usable, 0 if the app has not created it yet.
// Safe to call again. Does not create the segment.
int RMVRingOpenReader(void);

void RMVRingWriteInterleaved(const float *samples, uint32_t frames);
// Fills interleaved stereo. Returns 1 when at least one frame came from the writer.
int RMVRingReadLatestInterleaved(float *samples, uint32_t frames);
void RMVRingFlush(void);

void RMVRingUseMac(void);
void RMVRingUseSilence(void);
void RMVRingUseRemote(void);
uint32_t RMVRingFeed(void);

#endif
