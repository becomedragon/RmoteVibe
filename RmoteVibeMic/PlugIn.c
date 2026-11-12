// Original AudioServerPlugIn for one input device named "RmoteVibe Mic".
// Written against Apple's public AudioServerPlugIn.h. This is not a copy of
// BlackHole, Background Music, or any other virtual-device project.
//
// The plug-in does not decode the Siri Remote. It plays whatever the menu-bar
// app writes into the shared ring. While that app is on the remote path and
// no reader exists, the ring stays empty and this device plays silence.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#include "RingBuffer.h"

enum {
    kRMVDeviceObjectID = 2,
    kRMVStreamObjectID = 3,
    kRMVZeroTimeStampPeriod = 4096,
    kRMVMaxChunk = 8192
};

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInHostRef gHost = NULL;
static _Atomic uint32_t gClients = 0;
static Float64 gTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gClockSeed = 1;
static float gChunk[kRMVMaxChunk * RMV_RING_CHANNELS];
static int gLoggedMissingRing = 0;

static os_log_t RMVLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("dev.rmotevibe.RmoteVibeMic", "hal");
    });
    return log;
}

static CFStringRef RMVMakeString(const char *utf8) {
    return CFStringCreateWithCString(kCFAllocatorDefault, utf8, kCFStringEncodingUTF8);
}

static CFStringRef RMVDeviceName(void) {
    static CFStringRef value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        value = RMVMakeString("RmoteVibe Mic");
    });
    return value;
}

static CFStringRef RMVManufacturer(void) {
    static CFStringRef value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        value = RMVMakeString("RmoteVibe");
    });
    return value;
}

static CFStringRef RMVUID(void) {
    static CFStringRef value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        value = RMVMakeString(RMVDeviceUID);
    });
    return value;
}

static CFStringRef RMVModelUID(void) {
    static CFStringRef value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        value = RMVMakeString("dev.rmotevibe.mic.model");
    });
    return value;
}

static AudioStreamBasicDescription RMVFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = RMV_RING_SAMPLE_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    format.mBytesPerPacket = sizeof(Float32) * RMV_RING_CHANNELS;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32) * RMV_RING_CHANNELS;
    format.mChannelsPerFrame = RMV_RING_CHANNELS;
    format.mBitsPerChannel = 32;
    return format;
}

static Boolean RMVOutputScope(const AudioObjectPropertyAddress *address) {
    return address->mScope == kAudioObjectPropertyScopeOutput;
}

static OSStatus RMVWrite(const void *src, UInt32 size, UInt32 *ioSize, void *outData) {
    if (ioSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (outData == NULL) {
        *ioSize = size;
        return noErr;
    }
    if (*ioSize < size) {
        *ioSize = size;
        return kAudioHardwareBadPropertySizeError;
    }
    if (size > 0 && src != NULL) {
        memcpy(outData, src, size);
    }
    *ioSize = size;
    return noErr;
}

static OSStatus RMVWriteString(CFStringRef string, UInt32 *ioSize, void *outData) {
    if (string == NULL) {
        return kAudioHardwareUnspecifiedError;
    }
    CFStringRef retained = (CFStringRef)CFRetain(string);
    OSStatus status = RMVWrite(&retained, (UInt32)sizeof(retained), ioSize, outData);
    if (status != noErr || outData == NULL) {
        CFRelease(retained);
    }
    return status;
}

static OSStatus RMVWriteUInt32(UInt32 value, UInt32 *ioSize, void *outData) {
    return RMVWrite(&value, (UInt32)sizeof(value), ioSize, outData);
}

static OSStatus RMVWriteFloat64(Float64 value, UInt32 *ioSize, void *outData) {
    return RMVWrite(&value, (UInt32)sizeof(value), ioSize, outData);
}

static UInt32 RMVOwnedCount(AudioObjectID objectID, const AudioObjectPropertyAddress *address, AudioClassID wanted) {
    Boolean filter = wanted != 0;
    if (objectID == kAudioObjectPlugInObject) {
        if (filter && wanted != kAudioDeviceClassID) {
            return 0;
        }
        return 1;
    }
    if (objectID == kRMVDeviceObjectID) {
        if (RMVOutputScope(address)) {
            return 0;
        }
        if (filter && wanted != kAudioStreamClassID) {
            return 0;
        }
        return 1;
    }
    return 0;
}

static OSStatus RMVWriteObjectList(AudioObjectID objectID, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 *ioSize, void *outData) {
    AudioClassID wanted = 0;
    if (qualifier != NULL && qualifierSize >= (UInt32)sizeof(AudioClassID)) {
        memcpy(&wanted, qualifier, sizeof(wanted));
    }
    UInt32 count = RMVOwnedCount(objectID, address, wanted);
    AudioObjectID items[2];
    UInt32 n = 0;
    if (count > 0 && objectID == kAudioObjectPlugInObject) {
        items[n++] = kRMVDeviceObjectID;
    } else if (count > 0 && objectID == kRMVDeviceObjectID) {
        items[n++] = kRMVStreamObjectID;
    }
    return RMVWrite(items, n * (UInt32)sizeof(AudioObjectID), ioSize, outData);
}

static OSStatus RMVStreamConfiguration(const AudioObjectPropertyAddress *address, UInt32 *ioSize, void *outData) {
    if (RMVOutputScope(address)) {
        AudioBufferList empty;
        memset(&empty, 0, sizeof(empty));
        return RMVWrite(&empty, (UInt32)offsetof(AudioBufferList, mBuffers), ioSize, outData);
    }
    AudioBufferList list;
    memset(&list, 0, sizeof(list));
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = RMV_RING_CHANNELS;
    return RMVWrite(&list, (UInt32)sizeof(list), ioSize, outData);
}

static OSStatus RMVChannelLayout(UInt32 *ioSize, void *outData) {
    AudioChannelLayout layout;
    memset(&layout, 0, sizeof(layout));
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    return RMVWrite(&layout, (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions), ioSize, outData);
}

static OSStatus RMVFormats(UInt32 *ioSize, void *outData) {
    AudioStreamRangedDescription range;
    memset(&range, 0, sizeof(range));
    range.mFormat = RMVFormat();
    range.mSampleRateRange.mMinimum = RMV_RING_SAMPLE_RATE;
    range.mSampleRateRange.mMaximum = RMV_RING_SAMPLE_RATE;
    return RMVWrite(&range, (UInt32)sizeof(range), ioSize, outData);
}

static Boolean RMVFormatMatches(const AudioStreamBasicDescription *format) {
    AudioStreamBasicDescription ours = RMVFormat();
    return format != NULL &&
        format->mSampleRate == ours.mSampleRate &&
        format->mFormatID == ours.mFormatID &&
        format->mChannelsPerFrame == ours.mChannelsPerFrame &&
        format->mBitsPerChannel == ours.mBitsPerChannel &&
        format->mBytesPerFrame == ours.mBytesPerFrame &&
        (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
}

static OSStatus RMVProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 *ioSize, void *outData) {
    if (address == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    AudioObjectPropertySelector selector = address->mSelector;

    if (selector == kAudioObjectPropertyBaseClass) {
        AudioClassID value = kAudioObjectClassID;
        return RMVWrite(&value, (UInt32)sizeof(value), ioSize, outData);
    }
    if (selector == kAudioObjectPropertyClass) {
        AudioClassID value = kAudioObjectClassID;
        if (objectID == kAudioObjectPlugInObject) {
            value = kAudioPlugInClassID;
        } else if (objectID == kRMVDeviceObjectID) {
            value = kAudioDeviceClassID;
        } else if (objectID == kRMVStreamObjectID) {
            value = kAudioStreamClassID;
        } else {
            return kAudioHardwareBadObjectError;
        }
        return RMVWrite(&value, (UInt32)sizeof(value), ioSize, outData);
    }
    if (selector == kAudioObjectPropertyOwner) {
        AudioObjectID owner = kAudioObjectUnknown;
        if (objectID == kAudioObjectPlugInObject) {
            owner = kAudioObjectUnknown;
        } else if (objectID == kRMVDeviceObjectID) {
            owner = kAudioObjectPlugInObject;
        } else if (objectID == kRMVStreamObjectID) {
            owner = kRMVDeviceObjectID;
        } else {
            return kAudioHardwareBadObjectError;
        }
        return RMVWrite(&owner, (UInt32)sizeof(owner), ioSize, outData);
    }
    if (selector == kAudioObjectPropertyManufacturer) {
        return RMVWriteString(RMVManufacturer(), ioSize, outData);
    }
    if (selector == kAudioObjectPropertyName || selector == kAudioObjectPropertyElementName) {
        if (objectID == kRMVStreamObjectID) {
            static CFStringRef inputName;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                inputName = RMVMakeString("RmoteVibe Mic Input");
            });
            return RMVWriteString(inputName, ioSize, outData);
        }
        return RMVWriteString(RMVDeviceName(), ioSize, outData);
    }
    if (selector == kAudioObjectPropertyOwnedObjects) {
        return RMVWriteObjectList(objectID, address, qualifierSize, qualifier, ioSize, outData);
    }

    if (objectID == kAudioObjectPlugInObject) {
        if (selector == kAudioPlugInPropertyDeviceList) {
            AudioObjectID device = kRMVDeviceObjectID;
            return RMVWrite(&device, (UInt32)sizeof(device), ioSize, outData);
        }
        if (selector == kAudioPlugInPropertyTranslateUIDToDevice) {
            AudioObjectID device = kAudioObjectUnknown;
            if (qualifier != NULL && qualifierSize == (UInt32)sizeof(CFStringRef)) {
                CFStringRef uid = *(CFStringRef *)qualifier;
                if (uid != NULL && CFGetTypeID(uid) == CFStringGetTypeID() && CFEqual(uid, RMVUID())) {
                    device = kRMVDeviceObjectID;
                }
            }
            return RMVWrite(&device, (UInt32)sizeof(device), ioSize, outData);
        }
        if (selector == kAudioPlugInPropertyBoxList || selector == kAudioObjectPropertyControlList) {
            return RMVWrite(NULL, 0, ioSize, outData);
        }
        if (selector == kAudioPlugInPropertyTranslateUIDToBox) {
            AudioObjectID box = kAudioObjectUnknown;
            return RMVWrite(&box, (UInt32)sizeof(box), ioSize, outData);
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (objectID == kRMVDeviceObjectID) {
        if (selector == kAudioDevicePropertyDeviceUID) {
            return RMVWriteString(RMVUID(), ioSize, outData);
        }
        if (selector == kAudioDevicePropertyModelUID) {
            return RMVWriteString(RMVModelUID(), ioSize, outData);
        }
        if (selector == kAudioDevicePropertyTransportType) {
            // Not a USB device. 豆包 has skipped virtual inputs that do not
            // advertise a USB transport. Whether this build lists the device
            // is unverified on the target Mac.
            return RMVWriteUInt32(kAudioDeviceTransportTypeUSB, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyRelatedDevices) {
            AudioObjectID device = kRMVDeviceObjectID;
            return RMVWrite(&device, (UInt32)sizeof(device), ioSize, outData);
        }
        if (selector == kAudioDevicePropertyClockDomain) {
            return RMVWriteUInt32(0, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyDeviceIsAlive) {
            return RMVWriteUInt32(1, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyDeviceIsRunning || selector == kAudioDevicePropertyDeviceIsRunningSomewhere) {
            return RMVWriteUInt32(atomic_load(&gClients) > 0 ? 1 : 0, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyDeviceCanBeDefaultDevice) {
            UInt32 can = RMVOutputScope(address) ? 0 : 1;
            return RMVWriteUInt32(can, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice) {
            return RMVWriteUInt32(0, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyLatency || selector == kAudioDevicePropertySafetyOffset) {
            return RMVWriteUInt32(0, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyStreams) {
            if (RMVOutputScope(address)) {
                return RMVWrite(NULL, 0, ioSize, outData);
            }
            AudioObjectID stream = kRMVStreamObjectID;
            return RMVWrite(&stream, (UInt32)sizeof(stream), ioSize, outData);
        }
        if (selector == kAudioObjectPropertyControlList) {
            return RMVWrite(NULL, 0, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyNominalSampleRate) {
            return RMVWriteFloat64(RMV_RING_SAMPLE_RATE, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyAvailableNominalSampleRates) {
            AudioValueRange range;
            range.mMinimum = RMV_RING_SAMPLE_RATE;
            range.mMaximum = RMV_RING_SAMPLE_RATE;
            return RMVWrite(&range, (UInt32)sizeof(range), ioSize, outData);
        }
        if (selector == kAudioDevicePropertyIsHidden) {
            return RMVWriteUInt32(0, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyPreferredChannelsForStereo) {
            UInt32 channels[2] = { 1, 2 };
            return RMVWrite(channels, (UInt32)sizeof(channels), ioSize, outData);
        }
        if (selector == kAudioDevicePropertyPreferredChannelLayout) {
            return RMVChannelLayout(ioSize, outData);
        }
        if (selector == kAudioDevicePropertyZeroTimeStampPeriod) {
            return RMVWriteUInt32(kRMVZeroTimeStampPeriod, ioSize, outData);
        }
        if (selector == kAudioDevicePropertyStreamConfiguration) {
            return RMVStreamConfiguration(address, ioSize, outData);
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (objectID == kRMVStreamObjectID) {
        if (selector == kAudioStreamPropertyIsActive) {
            return RMVWriteUInt32(atomic_load(&gClients) > 0 ? 1 : 0, ioSize, outData);
        }
        if (selector == kAudioStreamPropertyDirection) {
            return RMVWriteUInt32(1, ioSize, outData);
        }
        if (selector == kAudioStreamPropertyTerminalType) {
            return RMVWriteUInt32(kAudioStreamTerminalTypeMicrophone, ioSize, outData);
        }
        if (selector == kAudioStreamPropertyStartingChannel) {
            return RMVWriteUInt32(1, ioSize, outData);
        }
        if (selector == kAudioStreamPropertyLatency) {
            return RMVWriteUInt32(0, ioSize, outData);
        }
        if (selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat) {
            AudioStreamBasicDescription format = RMVFormat();
            return RMVWrite(&format, (UInt32)sizeof(format), ioSize, outData);
        }
        if (selector == kAudioStreamPropertyAvailableVirtualFormats || selector == kAudioStreamPropertyAvailablePhysicalFormats) {
            return RMVFormats(ioSize, outData);
        }
        return kAudioHardwareUnknownPropertyError;
    }

    return kAudioHardwareBadObjectError;
}

static HRESULT RMVQueryInterface(void *driver, REFIID iid, LPVOID *outInterface) {
    (void)driver;
    if (outInterface == NULL) {
        return E_POINTER;
    }
    *outInterface = NULL;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    if (uuid == NULL) {
        return E_INVALIDARG;
    }
    Boolean match = CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);
    if (!match) {
        return E_NOINTERFACE;
    }
    *outInterface = &gInterfacePointer;
    gInterface.AddRef(driver);
    return S_OK;
}

static ULONG RMVAddRef(void *driver) {
    (void)driver;
    return 1;
}

static ULONG RMVRelease(void *driver) {
    (void)driver;
    return 1;
}

static OSStatus RMVInitialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    (void)driver;
    gHost = host;
    os_log(RMVLog(), "RmoteVibeMic loaded. UID %{public}s. Remote audio is not decoded here.", RMVDeviceUID);
    return noErr;
}

static OSStatus RMVCreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo *clientInfo, AudioObjectID *outDeviceObjectID) {
    (void)driver;
    (void)description;
    (void)clientInfo;
    (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus RMVDestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID) {
    (void)driver;
    (void)deviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus RMVAddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientInfo;
    return noErr;
}

static OSStatus RMVRemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, const AudioServerPlugInClientInfo *clientInfo) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientInfo;
    return noErr;
}

static OSStatus RMVPerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo) {
    (void)driver;
    (void)deviceObjectID;
    (void)changeAction;
    (void)changeInfo;
    return noErr;
}

static OSStatus RMVAbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt64 changeAction, void *changeInfo) {
    (void)driver;
    (void)deviceObjectID;
    (void)changeAction;
    (void)changeInfo;
    return noErr;
}

static Boolean RMVHasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address) {
    (void)driver;
    (void)clientProcessID;
    UInt32 size = 0;
    OSStatus status = RMVProperty(objectID, address, 0, NULL, &size, NULL);
    return status != kAudioHardwareUnknownPropertyError && status != kAudioHardwareBadObjectError;
}

static OSStatus RMVIsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, Boolean *outIsSettable) {
    (void)driver;
    (void)clientProcessID;
    if (address == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!RMVHasProperty(driver, objectID, clientProcessID, address)) {
        return kAudioHardwareUnknownPropertyError;
    }
    *outIsSettable = false;
    if (objectID == kRMVDeviceObjectID && address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outIsSettable = true;
    }
    if (objectID == kRMVStreamObjectID &&
        (address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        *outIsSettable = true;
    }
    return noErr;
}

static OSStatus RMVGetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 *outDataSize) {
    (void)driver;
    (void)clientProcessID;
    return RMVProperty(objectID, address, qualifierDataSize, qualifierData, outDataSize, NULL);
}

static OSStatus RMVGetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)driver;
    (void)clientProcessID;
    if (outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    *outDataSize = inDataSize;
    return RMVProperty(objectID, address, qualifierDataSize, qualifierData, outDataSize, outData);
}

static OSStatus RMVSetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID, pid_t clientProcessID, const AudioObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 inDataSize, const void *inData) {
    (void)driver;
    (void)clientProcessID;
    (void)qualifierDataSize;
    (void)qualifierData;
    if (address == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (objectID == kRMVDeviceObjectID && address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inData == NULL || inDataSize < (UInt32)sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }
        Float64 rate = 0;
        memcpy(&rate, inData, sizeof(rate));
        if (rate != (Float64)RMV_RING_SAMPLE_RATE) {
            return kAudioHardwareUnsupportedOperationError;
        }
        return noErr;
    }
    if (objectID == kRMVStreamObjectID &&
        (address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inData == NULL || inDataSize < (UInt32)sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioStreamBasicDescription format;
        memcpy(&format, inData, sizeof(format));
        if (!RMVFormatMatches(&format)) {
            return kAudioHardwareUnsupportedOperationError;
        }
        return noErr;
    }
    Boolean settable = false;
    OSStatus status = RMVIsPropertySettable(driver, objectID, clientProcessID, address, &settable);
    if (status != noErr) {
        return status;
    }
    return settable ? noErr : kAudioHardwareUnsupportedOperationError;
}

static OSStatus RMVStartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientID;
    atomic_fetch_add(&gClients, 1);
    if (!RMVRingOpenReader() && !gLoggedMissingRing) {
        gLoggedMissingRing = 1;
        os_log(RMVLog(), "Shared ring %{public}s is not mapped. The menu-bar app creates it. Until then this device plays silence.", RMV_SHM_NAME);
    }
    return noErr;
}

static OSStatus RMVStopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientID;
    uint32_t current = atomic_load(&gClients);
    if (current > 0) {
        atomic_fetch_sub(&gClients, 1);
    }
    return noErr;
}

static void RMVEnsureClock(void) {
    if (gTicksPerFrame != 0) {
        return;
    }
    struct mach_timebase_info info;
    mach_timebase_info(&info);
    Float64 ticksPerSecond = (1.0e9 * (Float64)info.denom) / (Float64)info.numer;
    gTicksPerFrame = ticksPerSecond / (Float64)RMV_RING_SAMPLE_RATE;
    if (gTicksPerFrame <= 0) {
        gTicksPerFrame = 1;
    }
}

static OSStatus RMVGetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientID;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    RMVEnsureClock();
    UInt64 now = mach_absolute_time();
    if (gAnchorHostTime == 0 || now < gAnchorHostTime) {
        gAnchorHostTime = now;
        gClockSeed += 1;
    }
    Float64 elapsed = (Float64)(now - gAnchorHostTime) / gTicksPerFrame;
    if (elapsed < 0) {
        elapsed = 0;
    }
    UInt64 periodIndex = (UInt64)(elapsed / (Float64)kRMVZeroTimeStampPeriod);
    UInt64 frameTime = periodIndex * (UInt64)kRMVZeroTimeStampPeriod;
    *outSampleTime = (Float64)frameTime;
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)frameTime * gTicksPerFrame);
    *outSeed = gClockSeed;
    return noErr;
}

static OSStatus RMVWillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientID;
    if (outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    *outWillDo = (operationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return noErr;
}

static OSStatus RMVBeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientID;
    (void)operationID;
    (void)ioBufferFrameSize;
    (void)ioCycleInfo;
    return noErr;
}

static OSStatus RMVDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)driver;
    (void)deviceObjectID;
    (void)streamObjectID;
    (void)clientID;
    (void)ioCycleInfo;
    (void)ioSecondaryBuffer;
    if (operationID != kAudioServerPlugInIOOperationReadInput || ioMainBuffer == NULL || ioBufferFrameSize == 0) {
        return noErr;
    }
    // ReadInput hands us the interleaved stereo samples themselves: one
    // buffer, 2 channels, 8 bytes per frame. The first sample is zero until
    // we write it, so this pointer is not an AudioBufferList.
    float *dst = (float *)ioMainBuffer;
    UInt32 done = 0;
    while (done < ioBufferFrameSize) {
        UInt32 chunk = ioBufferFrameSize - done;
        if (chunk > kRMVMaxChunk) {
            chunk = kRMVMaxChunk;
        }
        RMVRingReadLatestInterleaved(gChunk, chunk);
        memcpy(dst + ((size_t)done * RMV_RING_CHANNELS), gChunk, (size_t)chunk * RMV_RING_CHANNELS * sizeof(float));
        done += chunk;
    }
    return noErr;
}

static OSStatus RMVEndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID, UInt32 clientID, UInt32 operationID, UInt32 ioBufferFrameSize, const AudioServerPlugInIOCycleInfo *ioCycleInfo) {
    (void)driver;
    (void)deviceObjectID;
    (void)clientID;
    (void)operationID;
    (void)ioBufferFrameSize;
    (void)ioCycleInfo;
    return noErr;
}

__attribute__((visibility("default")))
void *RmoteVibeMic_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    (void)allocator;
    if (typeUUID == NULL || !CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    gInterface = (AudioServerPlugInDriverInterface) {
        ._reserved = NULL,
        .QueryInterface = RMVQueryInterface,
        .AddRef = RMVAddRef,
        .Release = RMVRelease,
        .Initialize = RMVInitialize,
        .CreateDevice = RMVCreateDevice,
        .DestroyDevice = RMVDestroyDevice,
        .AddDeviceClient = RMVAddDeviceClient,
        .RemoveDeviceClient = RMVRemoveDeviceClient,
        .PerformDeviceConfigurationChange = RMVPerformDeviceConfigurationChange,
        .AbortDeviceConfigurationChange = RMVAbortDeviceConfigurationChange,
        .HasProperty = RMVHasProperty,
        .IsPropertySettable = RMVIsPropertySettable,
        .GetPropertyDataSize = RMVGetPropertyDataSize,
        .GetPropertyData = RMVGetPropertyData,
        .SetPropertyData = RMVSetPropertyData,
        .StartIO = RMVStartIO,
        .StopIO = RMVStopIO,
        .GetZeroTimeStamp = RMVGetZeroTimeStamp,
        .WillDoIOOperation = RMVWillDoIOOperation,
        .BeginIOOperation = RMVBeginIOOperation,
        .DoIOOperation = RMVDoIOOperation,
        .EndIOOperation = RMVEndIOOperation
    };
    gInterfacePointer = &gInterface;
    return &gInterfacePointer;
}
