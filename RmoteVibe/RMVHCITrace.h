#ifndef RMV_HCI_TRACE_H
#define RMV_HCI_TRACE_H

#include <stdint.h>

// Reads bluetoothd's PacketLogger file and pulls the A2854 voice packets:
// ACL data, L2CAP CID 0x0004, ATT notification 0x1B, attribute 0x0036,
// Opus TOC 0xB8. The connection handle is not fixed; it changes on reconnect.

typedef struct RMVHCITrace RMVHCITrace;

// First readable path wins. bluetoothd's PacketLogger file is the usual live
// source. Optional /tmp follows are used when a copy of that file is running.
const char *RMVHCITracePreferredPath(void);

RMVHCITrace *RMVHCITraceOpen(const char *path);
void RMVHCITraceClose(RMVHCITrace *trace);
// Ignore bytes already in the file so a new Siri hold does not replay it.
void RMVHCITraceSeekEnd(RMVHCITrace *trace);
// If bluetoothd replaced the file, follow the new one from its start.
void RMVHCITraceFollow(RMVHCITrace *trace, const char *path);
// Next Opus packet. Returns its length, 0 when nothing new is complete, -1
// when the file can no longer be read.
int RMVHCITraceNextOpus(RMVHCITrace *trace, uint8_t *packet, int capacity);

int RMVOpusDecoderOpen(void);
void RMVOpusDecoderClose(void);
// Mono float at 48 kHz. Returns the sample count, or 0 when Opus rejects it.
int RMVOpusDecodePacket(const uint8_t *packet, int length, float *pcm, int capacity);

// Decode every voice packet in the file. peak is the largest absolute sample.
// Returns 0 when at least one packet decoded.
int RMVHCIDecodeFile(const char *path, float *peak, uint32_t *packetCount, uint32_t *sampleCount);

#endif
