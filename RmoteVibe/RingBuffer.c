#include "RingBuffer.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

const char *RMVDeviceUID = "dev.rmotevibe.mic";
const uint32_t RMVRingSampleRate = RMV_RING_SAMPLE_RATE;
const uint32_t RMVRingChannels = RMV_RING_CHANNELS;
const uint32_t RMVFeedMac = RMV_FEED_MAC;
const uint32_t RMVFeedSilence = RMV_FEED_SILENCE;
const uint32_t RMVFeedRemote = RMV_FEED_REMOTE;

// 100 ms of backlog is dropped back to a 50 ms cushion. This is a buffer
// policy, not a measured end-to-end latency.
enum {
    RMVCatchUpFrames = 4800,
    RMVTargetDelayFrames = 2400
};

typedef struct {
    _Atomic uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t capacityFrames;
    _Atomic uint32_t feed;
    _Atomic uint64_t writeFrame;
    _Atomic uint64_t readFrame;
    uint32_t structBytes;
    uint32_t reserved;
    float samples[RMV_RING_CAPACITY_FRAMES * RMV_RING_CHANNELS];
} RMVRing;

_Static_assert(sizeof(((RMVRing *)0)->samples) == RMV_RING_CAPACITY_FRAMES * RMV_RING_CHANNELS * sizeof(float), "ring");

static RMVRing *gRing = NULL;
static int gFd = -1;
static int gWriter = 0;

static void rmv_unmap(void) {
    if (gRing != NULL) {
        munmap(gRing, sizeof(RMVRing));
        gRing = NULL;
    }
    if (gFd >= 0) {
        close(gFd);
        gFd = -1;
    }
}

static int rmv_map(int create) {
    if (gRing != NULL) {
        return 0;
    }
    int flags = create ? (O_CREAT | O_RDWR) : O_RDWR;
    // umask would otherwise clear the world bits coreaudiod needs. fchmod
    // on this object returns EINVAL, so the create mode has to be right.
    mode_t previous = umask(0);
    int fd = shm_open(RMV_SHM_NAME, flags, 0666);
    umask(previous);
    if (fd < 0) {
        return errno != 0 ? errno : EIO;
    }
    if (create) {
        // Best effort. macOS rejects fchmod on a POSIX shm fd.
        fchmod(fd, 0666);
        // Once the object is already mapped, ftruncate returns EINVAL even
        // when the length is already right. mmap is the check that matters.
        long page = sysconf(_SC_PAGESIZE);
        size_t bytes = sizeof(RMVRing);
        if (page > 0) {
            bytes = (bytes + (size_t)page - 1) & ~((size_t)page - 1);
        }
        int truncated = ftruncate(fd, (off_t)bytes);
        int truncErr = errno;
        void *mem = mmap(NULL, sizeof(RMVRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mem == MAP_FAILED) {
            int err = errno;
            close(fd);
            if (truncated != 0) {
                return truncErr != 0 ? truncErr : EIO;
            }
            return err != 0 ? err : EIO;
        }
        gFd = fd;
        gRing = (RMVRing *)mem;
        return 0;
    }
    void *mem = mmap(NULL, sizeof(RMVRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem == MAP_FAILED) {
        int err = errno;
        close(fd);
        return err != 0 ? err : EIO;
    }
    gFd = fd;
    gRing = (RMVRing *)mem;
    return 0;
}

static void rmv_publish(void) {
    uint32_t magic = atomic_load_explicit(&gRing->magic, memory_order_acquire);
    if (magic == RMV_RING_MAGIC &&
        gRing->version == RMV_RING_VERSION &&
        gRing->structBytes == (uint32_t)sizeof(RMVRing) &&
        gRing->capacityFrames == RMV_RING_CAPACITY_FRAMES) {
        return;
    }
    memset(gRing->samples, 0, sizeof(gRing->samples));
    gRing->version = RMV_RING_VERSION;
    gRing->sampleRate = RMV_RING_SAMPLE_RATE;
    gRing->channels = RMV_RING_CHANNELS;
    gRing->capacityFrames = RMV_RING_CAPACITY_FRAMES;
    gRing->structBytes = (uint32_t)sizeof(RMVRing);
    gRing->reserved = 0;
    atomic_store_explicit(&gRing->feed, RMV_FEED_SILENCE, memory_order_relaxed);
    atomic_store_explicit(&gRing->writeFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&gRing->readFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&gRing->magic, RMV_RING_MAGIC, memory_order_release);
}

int RMVRingOpenWriter(void) {
    if (gRing != NULL && gWriter) {
        return 0;
    }
    int err = rmv_map(1);
    if (err != 0) {
        return err;
    }
    gWriter = 1;
    rmv_publish();
    return 0;
}

void RMVRingCloseWriter(void) {
    gWriter = 0;
    rmv_unmap();
}

int RMVRingOpenReader(void) {
    if (gRing != NULL &&
        atomic_load_explicit(&gRing->magic, memory_order_acquire) == RMV_RING_MAGIC &&
        gRing->structBytes == (uint32_t)sizeof(RMVRing)) {
        return 1;
    }
    if (gRing != NULL) {
        rmv_unmap();
    }
    if (rmv_map(0) != 0) {
        return 0;
    }
    if (atomic_load_explicit(&gRing->magic, memory_order_acquire) != RMV_RING_MAGIC ||
        gRing->structBytes != (uint32_t)sizeof(RMVRing) ||
        gRing->capacityFrames != RMV_RING_CAPACITY_FRAMES) {
        rmv_unmap();
        return 0;
    }
    return 1;
}

static int rmv_ready(void) {
    return gRing != NULL &&
        atomic_load_explicit(&gRing->magic, memory_order_acquire) == RMV_RING_MAGIC;
}

void RMVRingWriteInterleaved(const float *samples, uint32_t frames) {
    if (!rmv_ready() || samples == NULL || frames == 0) {
        return;
    }
    uint32_t cap = gRing->capacityFrames;
    if (frames > cap) {
        samples += (frames - cap) * RMV_RING_CHANNELS;
        frames = cap;
    }
    uint64_t w = atomic_load_explicit(&gRing->writeFrame, memory_order_relaxed);
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t index = (uint32_t)((w + i) % cap);
        gRing->samples[index * 2] = samples[i * 2];
        gRing->samples[index * 2 + 1] = samples[i * 2 + 1];
    }
    atomic_store_explicit(&gRing->writeFrame, w + frames, memory_order_release);
}

int RMVRingReadLatestInterleaved(float *samples, uint32_t frames) {
    if (samples == NULL || frames == 0) {
        return 0;
    }
    if (!rmv_ready()) {
        memset(samples, 0, (size_t)frames * RMV_RING_CHANNELS * sizeof(float));
        return 0;
    }
    // While Siri is held the app selects silence until verified PCM is written
    // and the feed switches to remote. Zeros here are that gap, not a decoded
    // mute packet.
    if (atomic_load_explicit(&gRing->feed, memory_order_acquire) == RMV_FEED_SILENCE) {
        memset(samples, 0, (size_t)frames * RMV_RING_CHANNELS * sizeof(float));
        return 0;
    }
    uint32_t cap = gRing->capacityFrames;
    uint64_t w = atomic_load_explicit(&gRing->writeFrame, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&gRing->readFrame, memory_order_relaxed);
    if (w < r || (w - r) > cap) {
        r = (w > RMVTargetDelayFrames) ? (w - RMVTargetDelayFrames) : 0;
    }
    uint64_t available = w - r;
    if (available > RMVCatchUpFrames) {
        r = w - RMVTargetDelayFrames;
        available = w - r;
    }
    memset(samples, 0, (size_t)frames * RMV_RING_CHANNELS * sizeof(float));
    uint32_t copy = frames;
    uint64_t start = r;
    if (available < frames) {
        copy = (uint32_t)available;
        start = r;
        // Put the frames we do have at the end of this IO buffer.
        samples += (frames - copy) * RMV_RING_CHANNELS;
    }
    for (uint32_t i = 0; i < copy; i++) {
        uint32_t index = (uint32_t)((start + i) % cap);
        samples[i * 2] = gRing->samples[index * 2];
        samples[i * 2 + 1] = gRing->samples[index * 2 + 1];
    }
    atomic_store_explicit(&gRing->readFrame, r + copy, memory_order_release);
    return copy > 0 ? 1 : 0;
}

void RMVRingFlush(void) {
    if (!rmv_ready()) {
        return;
    }
    uint64_t w = atomic_load_explicit(&gRing->writeFrame, memory_order_acquire);
    atomic_store_explicit(&gRing->readFrame, w, memory_order_release);
}

static void rmv_set_feed(uint32_t feed) {
    if (!rmv_ready()) {
        return;
    }
    atomic_store_explicit(&gRing->feed, feed, memory_order_release);
}

void RMVRingUseMac(void) { rmv_set_feed(RMV_FEED_MAC); }
void RMVRingUseSilence(void) { rmv_set_feed(RMV_FEED_SILENCE); }
void RMVRingUseRemote(void) { rmv_set_feed(RMV_FEED_REMOTE); }

uint32_t RMVRingFeed(void) {
    if (!rmv_ready()) {
        return RMV_FEED_SILENCE;
    }
    return atomic_load_explicit(&gRing->feed, memory_order_acquire);
}
