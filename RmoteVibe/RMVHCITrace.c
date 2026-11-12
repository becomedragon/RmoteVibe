#include "RMVHCITrace.h"

#include <opus/opus.h>

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define RMV_TRACE_RESIDUAL (64 * 1024)
#define RMV_TRACE_READ (16 * 1024)
#define RMV_TRACE_SLOTS 8
#define RMV_ATT_VOICE 0x0036
#define RMV_OPUS_TOC 0xB8

typedef struct {
    int used;
    uint16_t handle;
    uint16_t l2capLength;
    uint16_t filled;
    uint8_t bytes[1024];
} RMVAssembly;

struct RMVHCITrace {
    int fd;
    uint8_t residual[RMV_TRACE_RESIDUAL];
    size_t residualLength;
    RMVAssembly slots[RMV_TRACE_SLOTS];
};

static OpusDecoder *gDecoder;

static const char *kTracePaths[] = {
    "/private/var/root/Library/Logs/Bluetooth/bluetoothd-hci-latest.pklg",
    "/tmp/bt-live.pklg",
    "/tmp/bt-latest.pklg",
    NULL
};

const char *RMVHCITracePreferredPath(void) {
    for (int index = 0; kTracePaths[index] != NULL; index++) {
        if (access(kTracePaths[index], R_OK) == 0) {
            return kTracePaths[index];
        }
    }
    return NULL;
}

static uint32_t RMVReadBE32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static uint16_t RMVReadLE16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

RMVHCITrace *RMVHCITraceOpen(const char *path) {
    if (path == NULL) {
        return NULL;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return NULL;
    }
    RMVHCITrace *trace = calloc(1, sizeof(*trace));
    if (trace == NULL) {
        close(fd);
        return NULL;
    }
    trace->fd = fd;
    return trace;
}

void RMVHCITraceClose(RMVHCITrace *trace) {
    if (trace == NULL) {
        return;
    }
    if (trace->fd >= 0) {
        close(trace->fd);
    }
    free(trace);
}

static void RMVResetParse(RMVHCITrace *trace) {
    trace->residualLength = 0;
    memset(trace->slots, 0, sizeof(trace->slots));
}

void RMVHCITraceSeekEnd(RMVHCITrace *trace) {
    if (trace == NULL || trace->fd < 0) {
        return;
    }
    lseek(trace->fd, 0, SEEK_END);
    RMVResetParse(trace);
}

void RMVHCITraceFollow(RMVHCITrace *trace, const char *path) {
    if (trace == NULL || path == NULL || trace->fd < 0) {
        return;
    }
    struct stat openStat;
    struct stat liveStat;
    if (fstat(trace->fd, &openStat) != 0 || stat(path, &liveStat) != 0) {
        return;
    }
    if (openStat.st_dev == liveStat.st_dev && openStat.st_ino == liveStat.st_ino) {
        off_t cursor = lseek(trace->fd, 0, SEEK_CUR);
        if (cursor >= 0 && liveStat.st_size < cursor) {
            lseek(trace->fd, 0, SEEK_SET);
            RMVResetParse(trace);
        }
        return;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return;
    }
    close(trace->fd);
    trace->fd = fd;
    RMVResetParse(trace);
}

static RMVAssembly *RMVSlot(RMVHCITrace *trace, uint16_t handle, int create) {
    RMVAssembly *freeSlot = NULL;
    for (int index = 0; index < RMV_TRACE_SLOTS; index++) {
        RMVAssembly *slot = &trace->slots[index];
        if (slot->used && slot->handle == handle) {
            return slot;
        }
        if (!slot->used && freeSlot == NULL) {
            freeSlot = slot;
        }
    }
    if (!create || freeSlot == NULL) {
        return NULL;
    }
    memset(freeSlot, 0, sizeof(*freeSlot));
    freeSlot->used = 1;
    freeSlot->handle = handle;
    return freeSlot;
}

static int RMVTakeOpus(const uint8_t *pdu, uint16_t length, uint8_t *packet, int capacity) {
    if (length < 12 || pdu[2] != 0x04 || pdu[3] != 0x00 || pdu[4] != 0x1B) {
        return 0;
    }
    uint16_t attribute = RMVReadLE16(pdu + 5);
    if (attribute != RMV_ATT_VOICE) {
        return 0;
    }
    const uint8_t *value = pdu + 7;
    uint16_t valueLength = (uint16_t)(length - 7);
    if (valueLength < 6) {
        return 0;
    }
    int opusLength = value[4];
    if (opusLength < 2 || 5 + opusLength > valueLength || value[5] != RMV_OPUS_TOC) {
        return 0;
    }
    if (opusLength > capacity) {
        return 0;
    }
    memcpy(packet, value + 5, (size_t)opusLength);
    return opusLength;
}

static int RMVConsumeACL(RMVHCITrace *trace, const uint8_t *acl, uint16_t aclLength, uint8_t *packet, int capacity) {
    if (aclLength < 4) {
        return 0;
    }
    uint16_t header = RMVReadLE16(acl);
    uint16_t handle = header & 0x0FFF;
    unsigned pb = (header >> 12) & 0x3;
    uint16_t dataLength = RMVReadLE16(acl + 2);
    if ((uint32_t)4 + dataLength > aclLength) {
        dataLength = (uint16_t)(aclLength - 4);
    }
    const uint8_t *data = acl + 4;

    if (pb == 0 || pb == 2) {
        RMVAssembly *slot = RMVSlot(trace, handle, 1);
        if (slot == NULL || dataLength < 2) {
            return 0;
        }
        uint16_t l2capLength = RMVReadLE16(data);
        uint16_t total = (uint16_t)(4 + l2capLength);
        if (total > sizeof(slot->bytes)) {
            slot->used = 0;
            return 0;
        }
        memcpy(slot->bytes, data, dataLength);
        slot->l2capLength = l2capLength;
        slot->filled = dataLength;
    } else if (pb == 1) {
        RMVAssembly *slot = RMVSlot(trace, handle, 0);
        if (slot == NULL) {
            return 0;
        }
        uint16_t total = (uint16_t)(4 + slot->l2capLength);
        if ((uint32_t)slot->filled + dataLength > total || (uint32_t)slot->filled + dataLength > sizeof(slot->bytes)) {
            slot->used = 0;
            return 0;
        }
        memcpy(slot->bytes + slot->filled, data, dataLength);
        slot->filled = (uint16_t)(slot->filled + dataLength);
    } else {
        return 0;
    }

    RMVAssembly *slot = RMVSlot(trace, handle, 0);
    if (slot == NULL || slot->filled < 4 + slot->l2capLength) {
        return 0;
    }
    int taken = RMVTakeOpus(slot->bytes, (uint16_t)(4 + slot->l2capLength), packet, capacity);
    slot->used = 0;
    return taken;
}

// 1 when a whole record sits at offset, 0 when the buffer ends inside it,
// -1 when these bytes are not a record.
static int RMVRecordEnd(const uint8_t *bytes, size_t count, size_t offset, size_t *endOut) {
    if (offset + 13 > count) {
        return 0;
    }
    uint32_t length = RMVReadBE32(bytes + offset);
    if (length < 9 || length > 65536) {
        return -1;
    }
    size_t end = offset + 4 + (size_t)length;
    if (end > count) {
        return 0;
    }
    if (bytes[offset + 12] > 0x03) {
        return -1;
    }
    *endOut = end;
    return 1;
}

static int RMVPullRecords(RMVHCITrace *trace, uint8_t *packet, int capacity) {
    size_t offset = 0;
    while (offset + 4 <= trace->residualLength) {
        size_t recordEnd = 0;
        int kind = RMVRecordEnd(trace->residual, trace->residualLength, offset, &recordEnd);
        if (kind == 0) {
            break;
        }
        if (kind < 0) {
            offset += 1;
            continue;
        }
        // A real PacketLogger stream has another record after this one.
        // A lucky header in the tail preamble does not.
        size_t following = 0;
        int next = RMVRecordEnd(trace->residual, trace->residualLength, recordEnd, &following);
        if (next < 0) {
            offset += 1;
            continue;
        }
        uint8_t type = trace->residual[offset + 12];
        const uint8_t *payload = trace->residual + offset + 13;
        uint16_t payloadLength = (uint16_t)(RMVReadBE32(trace->residual + offset) - 9);
        offset = recordEnd;
        if (type == 0x03) {
            int taken = RMVConsumeACL(trace, payload, payloadLength, packet, capacity);
            if (taken > 0) {
                memmove(trace->residual, trace->residual + offset, trace->residualLength - offset);
                trace->residualLength -= offset;
                return taken;
            }
        }
    }
    if (offset > 0 && offset < trace->residualLength) {
        memmove(trace->residual, trace->residual + offset, trace->residualLength - offset);
        trace->residualLength -= offset;
    } else if (offset >= trace->residualLength) {
        trace->residualLength = 0;
    }
    return 0;
}

int RMVHCITraceNextOpus(RMVHCITrace *trace, uint8_t *packet, int capacity) {
    if (trace == NULL || packet == NULL || capacity < 2 || trace->fd < 0) {
        return -1;
    }
    for (;;) {
        int ready = RMVPullRecords(trace, packet, capacity);
        if (ready != 0) {
            return ready;
        }
        if (trace->residualLength + 1 >= sizeof(trace->residual)) {
            trace->residualLength = 0;
        }
        ssize_t count = read(trace->fd, trace->residual + trace->residualLength,
                             sizeof(trace->residual) - trace->residualLength);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (count == 0) {
            return 0;
        }
        trace->residualLength += (size_t)count;
    }
}

int RMVOpusDecoderOpen(void) {
    if (gDecoder != NULL) {
        return 0;
    }
    int error = OPUS_OK;
    gDecoder = opus_decoder_create(48000, 1, &error);
    if (gDecoder == NULL || error != OPUS_OK) {
        gDecoder = NULL;
        return -1;
    }
    return 0;
}

void RMVOpusDecoderClose(void) {
    if (gDecoder != NULL) {
        opus_decoder_destroy(gDecoder);
        gDecoder = NULL;
    }
}

int RMVOpusDecodePacket(const uint8_t *packet, int length, float *pcm, int capacity) {
    if (gDecoder == NULL || packet == NULL || pcm == NULL || length < 2 || capacity < 120) {
        return 0;
    }
    int samples = opus_decode_float(gDecoder, packet, length, pcm, capacity, 0);
    return samples > 0 ? samples : 0;
}

int RMVHCIDecodeFile(const char *path, float *peak, uint32_t *packetCount, uint32_t *sampleCount) {
    if (peak != NULL) {
        *peak = 0;
    }
    if (packetCount != NULL) {
        *packetCount = 0;
    }
    if (sampleCount != NULL) {
        *sampleCount = 0;
    }
    RMVHCITrace *trace = RMVHCITraceOpen(path);
    if (trace == NULL || RMVOpusDecoderOpen() != 0) {
        RMVHCITraceClose(trace);
        return -1;
    }
    uint8_t packet[256];
    float pcm[5760];
    uint32_t packets = 0;
    uint32_t samples = 0;
    float loudest = 0;
    for (;;) {
        int length = RMVHCITraceNextOpus(trace, packet, (int)sizeof(packet));
        if (length == 0) {
            break;
        }
        if (length < 0) {
            RMVHCITraceClose(trace);
            return -1;
        }
        int count = RMVOpusDecodePacket(packet, length, pcm, 5760);
        if (count <= 0) {
            continue;
        }
        packets += 1;
        samples += (uint32_t)count;
        for (int index = 0; index < count; index++) {
            float magnitude = pcm[index] < 0 ? -pcm[index] : pcm[index];
            if (magnitude > loudest) {
                loudest = magnitude;
            }
        }
    }
    RMVHCITraceClose(trace);
    if (peak != NULL) {
        *peak = loudest;
    }
    if (packetCount != NULL) {
        *packetCount = packets;
    }
    if (sampleCount != NULL) {
        *sampleCount = samples;
    }
    return packets > 0 ? 0 : -1;
}
