#import "RMVVoiceCapture.h"

#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>

// Pairing is by HID vendor 0x004C product 0x0315 (Apple TV Siri Remote).
// An optional Bluetooth address from Settings is used when present.
// Serial number is not required.

// Google Android TV voice service. This remote is not that profile.
// If a record matches, it is counted and then ignored.
static const uint8_t RMVAndroidTVVoiceUUID[] = {
    0xAB, 0x5E, 0x00, 0x01, 0x5A, 0x21, 0x4F, 0x05,
    0xBC, 0x7D, 0xAF, 0x01, 0xF6, 0x17, 0xB6, 0x64
};

// Classic SDP audio classes. A match is recorded. No channel is opened.
static const BluetoothSDPUUID16 RMVClassicAudioUUIDs[] = {
    0x1108, // Headset
    0x110A, // Audio Source
    0x110B, // Audio Sink
    0x110D, // Advanced Audio Distribution
    0x111E  // Hands-Free
};

static const CFIndex RMVMaxReportBytes = 512;
static const uint32_t RMVMaxNotedChannels = 8;
static const NSUInteger RMVMaxNotedServices = 6;
static const NSUInteger RMVMaxNotedReportIDs = 8;

static NSString *RMVCanonicalAddress(NSString *raw) {
    if (raw.length == 0) {
        return @"";
    }
    NSCharacterSet *keep = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([keep characterIsMember:c]) {
            NSString *one = [NSString stringWithCharacters:&c length:1];
            [hex appendString:one.uppercaseString];
        }
    }
    return hex;
}

@interface RMVReportSlot : NSObject
@property (nonatomic, assign) IOHIDDeviceRef device;
@property (nonatomic, assign) uint8_t *buffer;
@property (nonatomic, assign) CFIndex capacity;
@property (nonatomic, assign) uint64_t registry;
@end

@implementation RMVReportSlot
- (void)dealloc {
    if (_buffer != NULL) {
        free(_buffer);
        _buffer = NULL;
    }
    if (_device != NULL) {
        CFRelease(_device);
        _device = NULL;
    }
}
@end

@interface RMVVoiceCapture ()
@property (nonatomic, assign) BOOL holding;
@property (nonatomic, assign) BOOL deviceFound;
@property (nonatomic, assign) BOOL deviceConnected;
@property (nonatomic, assign) BOOL matchedBySerial;
@property (nonatomic, copy, nullable) NSString *deviceName;
@property (nonatomic, copy, nullable) NSString *deviceAddress;
@property (nonatomic, assign) BOOL sdpFinished;
@property (nonatomic, assign) BOOL sdpSkipped;
@property (nonatomic, assign) int32_t sdpStatus;
@property (nonatomic, assign) uint32_t sdpServiceCount;
@property (nonatomic, copy) NSString *sdpServiceSummary;
@property (nonatomic, assign) BOOL sawHIDService;
@property (nonatomic, assign) BOOL sawClassicAudioUUID;
@property (nonatomic, assign) BOOL sawAndroidTVVoiceService;
@property (nonatomic, assign) uint32_t l2capCount;
@property (nonatomic, copy) NSString *l2capSummary;
@property (nonatomic, assign) uint32_t hidReportCount;
@property (nonatomic, assign) uint32_t hidMaxBytes;
@property (nonatomic, copy) NSString *hidReportIDs;
@property (nonatomic, assign) int32_t hidOpenStatus;
@property (nonatomic, assign) int32_t hidRegisterStatus;
@property (nonatomic, strong, nullable) IOBluetoothDevice *device;
@property (nonatomic, strong, nullable) IOBluetoothUserNotification *channelNote;
@property (nonatomic, copy) NSString *wantedAddress;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, strong) NSMutableArray<RMVReportSlot *> *slots;
@property (nonatomic, strong) NSMutableOrderedSet<NSNumber *> *reportIDs;
@property (nonatomic, strong) NSMutableData *longestReport;
@end

static void RMVDeviceMatched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void RMVDeviceRemoved(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void RMVInputReport(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength);
static void RMVLogDeviceMatched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void RMVLogInputReport(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength);
static void RMVAppendLog(NSString *line);
static int RMVDeviceInt(IOHIDDeviceRef device, CFStringRef key);

static NSString *const RMVReportLogPath = @"/tmp/rmv-hid-reports.log";

@implementation RMVVoiceCapture {
    IOHIDManagerRef _manager;
    IOHIDManagerRef _logManager;
    NSMutableArray<RMVReportSlot *> *_logSlots;
    BOOL _logOpen;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _sdpServiceSummary = @"";
        _l2capSummary = @"";
        _hidReportIDs = @"";
        _preferredAddress = @"";
        _wantedAddress = @"";
        _slots = [NSMutableArray array];
        _logSlots = [NSMutableArray array];
        _reportIDs = [NSMutableOrderedSet orderedSet];
        _longestReport = [NSMutableData data];
    }
    return self;
}

- (void)dealloc {
    [self endHold];
}

- (void)beginHold {
    if (self.holding) {
        return;
    }
    self.generation += 1;
    self.holding = YES;
    [self resetObservations];
    [self resolveDevice];
    if (self.deviceFound && self.deviceConnected && self.device != nil) {
        self.sdpSkipped = NO;
        self.sdpFinished = NO;
        IOReturn status = [self.device performSDPQuery:self];
        if (status != kIOReturnSuccess) {
            self.sdpFinished = YES;
            self.sdpStatus = (int32_t)status;
        }
    } else {
        self.sdpSkipped = YES;
        self.sdpFinished = YES;
        self.sdpStatus = 0;
    }
    self.channelNote = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
                                                                           selector:@selector(l2capChannelOpened:channel:)];
    [self openHID];
    [self publish];
}

- (void)endHold {
    if (!self.holding && self.channelNote == nil && _manager == NULL) {
        return;
    }
    self.holding = NO;
    self.generation += 1;
    [self.channelNote unregister];
    self.channelNote = nil;
    [self closeHID];
    // The bytes were not decoded. Drop them with the hold.
    self.longestReport = [NSMutableData data];
}

- (void)resetObservations {
    self.sdpFinished = NO;
    self.sdpSkipped = NO;
    self.sdpStatus = 0;
    self.sdpServiceCount = 0;
    self.sdpServiceSummary = @"";
    self.sawHIDService = NO;
    self.sawClassicAudioUUID = NO;
    self.sawAndroidTVVoiceService = NO;
    self.l2capCount = 0;
    self.l2capSummary = @"";
    self.hidReportCount = 0;
    self.hidMaxBytes = 0;
    self.hidReportIDs = @"";
    self.hidOpenStatus = 0;
    self.hidRegisterStatus = 0;
    [self.reportIDs removeAllObjects];
    self.longestReport = [NSMutableData data];
}

static BOOL RMVNameLooksLikeRemote(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"siri"] ||
        [lower containsString:@"apple tv"] ||
        [lower containsString:@"remote"] ||
        [lower containsString:@"a2854"];
}

static NSString *RMVColonAddressFromHex(NSString *hex) {
    if (hex.length != 12) {
        return nil;
    }
    NSMutableString *colon = [NSMutableString string];
    for (NSUInteger i = 0; i < 12; i += 2) {
        if (i > 0) {
            [colon appendString:@":"];
        }
        [colon appendString:[hex substringWithRange:NSMakeRange(i, 2)]];
    }
    return colon;
}

- (void)resolveDevice {
    self.device = nil;
    self.deviceFound = NO;
    self.deviceConnected = NO;
    self.matchedBySerial = NO;
    self.deviceName = nil;
    self.deviceAddress = nil;
    self.wantedAddress = RMVCanonicalAddress(self.preferredAddress);
    if (self.wantedAddress.length > 0) {
        NSString *colon = RMVColonAddressFromHex(self.wantedAddress);
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        if (self.preferredAddress.length > 0) {
            [candidates addObject:self.preferredAddress];
        }
        if (colon.length > 0) {
            [candidates addObject:colon];
        }
        for (NSString *candidate in candidates) {
            IOBluetoothDevice *found = [IOBluetoothDevice deviceWithAddressString:candidate];
            if (found != nil) {
                [self takeDevice:found matchedBySerial:NO];
                return;
            }
        }
    }
    NSArray *paired = [IOBluetoothDevice pairedDevices];
    IOBluetoothDevice *named = nil;
    for (id item in paired) {
        if (![item isKindOfClass:[IOBluetoothDevice class]]) {
            continue;
        }
        IOBluetoothDevice *found = (IOBluetoothDevice *)item;
        if (self.wantedAddress.length > 0 &&
            [RMVCanonicalAddress(found.addressString) isEqualToString:self.wantedAddress]) {
            [self takeDevice:found matchedBySerial:NO];
            return;
        }
        if (named == nil && RMVNameLooksLikeRemote(found.name ?: @"")) {
            named = found;
        }
    }
    if (self.wantedAddress.length == 0 && named != nil) {
        [self takeDevice:named matchedBySerial:NO];
        if (named.addressString.length > 0) {
            self.wantedAddress = RMVCanonicalAddress(named.addressString);
        }
    }
}

- (void)takeDevice:(IOBluetoothDevice *)device matchedBySerial:(BOOL)bySerial {
    self.device = device;
    self.deviceFound = YES;
    self.matchedBySerial = bySerial;
    self.deviceConnected = device.isConnected;
    self.deviceName = device.name;
    self.deviceAddress = device.addressString;
}

- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    NSUInteger token = self.generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (token != self.generation) {
            return;
        }
        self.sdpFinished = YES;
        self.sdpStatus = (int32_t)status;
        if (status == kIOReturnSuccess && device != nil) {
            [self readServices:device];
        }
        [self publish];
    });
}

- (void)readServices:(IOBluetoothDevice *)device {
    NSArray *services = device.services;
    self.sdpServiceCount = (uint32_t)services.count;
    NSData *androidTV = [NSData dataWithBytes:RMVAndroidTVVoiceUUID length:sizeof(RMVAndroidTVVoiceUUID)];
    IOBluetoothSDPUUID *androidUUID = [IOBluetoothSDPUUID uuidWithData:androidTV];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id item in services) {
        if (![item isKindOfClass:[IOBluetoothSDPServiceRecord class]]) {
            continue;
        }
        IOBluetoothSDPServiceRecord *record = (IOBluetoothSDPServiceRecord *)item;
        if ([record matchesUUID16:0x1124]) {
            self.sawHIDService = YES;
        }
        for (size_t i = 0; i < sizeof(RMVClassicAudioUUIDs) / sizeof(RMVClassicAudioUUIDs[0]); i++) {
            if ([record matchesUUID16:RMVClassicAudioUUIDs[i]]) {
                self.sawClassicAudioUUID = YES;
            }
        }
        if (androidUUID != nil && [record matchesUUIDArray:@[androidUUID]]) {
            // Seen, not subscribed. This is not the A2854 microphone.
            self.sawAndroidTVVoiceService = YES;
        }
        if (parts.count >= RMVMaxNotedServices) {
            continue;
        }
        NSString *name = [record getServiceName];
        if (name.length == 0) {
            name = @"unnamed";
        }
        BluetoothL2CAPPSM psm = 0;
        if ([record getL2CAPPSM:&psm] == kIOReturnSuccess) {
            name = [NSString stringWithFormat:@"%@ psm 0x%04X", name, psm];
        }
        [parts addObject:name];
    }
    self.sdpServiceSummary = [parts componentsJoinedByString:@", "];
}

- (void)l2capChannelOpened:(IOBluetoothUserNotification *)notification channel:(IOBluetoothL2CAPChannel *)channel {
    (void)notification;
    if (channel == nil) {
        return;
    }
    // Observation only. Do not setDelegate. That would take a channel
    // this process did not open, including the HID link.
    NSString *address = channel.device.addressString;
    BluetoothL2CAPPSM psm = channel.PSM;
    BOOL incoming = [channel isIncoming];
    NSUInteger token = self.generation;
    NSString *want = self.wantedAddress;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (token != self.generation || !self.holding) {
            return;
        }
        if (want.length == 0 || ![RMVCanonicalAddress(address) isEqualToString:want]) {
            return;
        }
        if (self.l2capCount >= RMVMaxNotedChannels) {
            return;
        }
        self.l2capCount += 1;
        NSString *piece = [NSString stringWithFormat:@"0x%04X %@", psm, incoming ? @"in" : @"out"];
        if (self.l2capSummary.length == 0) {
            self.l2capSummary = piece;
        } else {
            self.l2capSummary = [self.l2capSummary stringByAppendingFormat:@", %@", piece];
        }
        [self publish];
    });
}

- (void)openHID {
    [self closeHID];
    _manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (_manager == NULL) {
        self.hidOpenStatus = (int32_t)kIOReturnNoMemory;
        return;
    }
    NSDictionary *matching = @{
        @kIOHIDVendorIDKey: @0x004C,
        @kIOHIDProductIDKey: @0x0315
    };
    IOHIDManagerSetDeviceMatching(_manager, (__bridge CFDictionaryRef)matching);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager, RMVDeviceMatched, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager, RMVDeviceRemoved, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn opened = IOHIDManagerOpen(_manager, kIOHIDOptionsTypeNone);
    self.hidOpenStatus = (int32_t)opened;
    CFSetRef existing = IOHIDManagerCopyDevices(_manager);
    if (existing != NULL) {
        CFIndex count = CFSetGetCount(existing);
        if (count > 0) {
            IOHIDDeviceRef *list = calloc((size_t)count, sizeof(IOHIDDeviceRef));
            if (list != NULL) {
                CFSetGetValues(existing, (const void **)list);
                for (CFIndex i = 0; i < count; i++) {
                    [self watchDevice:list[i]];
                }
                free(list);
            }
        }
        CFRelease(existing);
    }
}

- (void)closeHID {
    if (_manager != NULL) {
        IOHIDManagerRegisterDeviceMatchingCallback(_manager, NULL, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(_manager, NULL, NULL);
        IOHIDManagerUnscheduleFromRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(_manager, kIOHIDOptionsTypeNone);
        CFRelease(_manager);
        _manager = NULL;
    }
    [self.slots removeAllObjects];
}

- (void)watchDevice:(IOHIDDeviceRef)device {
    if (device == NULL) {
        return;
    }
    uint64_t registry = 0;
    io_service_t service = IOHIDDeviceGetService(device);
    if (service != IO_OBJECT_NULL) {
        IORegistryEntryGetRegistryEntryID(service, &registry);
    }
    if (registry != 0) {
        for (RMVReportSlot *slot in self.slots) {
            if (slot.registry == registry) {
                return;
            }
        }
    }
    CFIndex capacity = 64;
    // The property name is MaxInputReportSize. The SDK constant is used when
    // it is already a CFString; the literal matches that key either way.
    CFStringRef sizeKey = CFSTR("MaxInputReportSize");
    CFTypeRef rawSize = IOHIDDeviceGetProperty(device, sizeKey);
    if (rawSize != NULL && CFGetTypeID(rawSize) == CFNumberGetTypeID()) {
        int value = 0;
        if (CFNumberGetValue((CFNumberRef)rawSize, kCFNumberIntType, &value) && value > 0) {
            capacity = value;
        }
    }
    if (capacity < 8) {
        capacity = 8;
    }
    if (capacity > RMVMaxReportBytes) {
        capacity = RMVMaxReportBytes;
    }
    uint8_t *buffer = calloc((size_t)capacity, 1);
    if (buffer == NULL) {
        self.hidRegisterStatus = (int32_t)kIOReturnNoMemory;
        return;
    }
    // This SDK's register call returns void. Failure shows up as no reports.
    IOHIDDeviceRegisterInputReportCallback(
        device,
        buffer,
        capacity,
        RMVInputReport,
        (__bridge void *)self
    );
    self.hidRegisterStatus = 0;
    RMVReportSlot *slot = [[RMVReportSlot alloc] init];
    slot.device = (IOHIDDeviceRef)CFRetain(device);
    slot.buffer = buffer;
    slot.capacity = capacity;
    slot.registry = registry;
    [self.slots addObject:slot];
}

- (void)noteReportID:(uint32_t)reportID data:(NSData *)data reportedLength:(CFIndex)reportedLength {
    if (!self.holding || reportedLength < 0) {
        return;
    }
    self.hidReportCount += 1;
    if (self.reportIDs.count < RMVMaxNotedReportIDs) {
        [self.reportIDs addObject:@(reportID)];
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (NSNumber *number in self.reportIDs) {
            [ids addObject:[NSString stringWithFormat:@"0x%02X", number.unsignedIntValue]];
        }
        self.hidReportIDs = [ids componentsJoinedByString:@","];
    }
    if (reportedLength > 0 && (uint32_t)reportedLength > self.hidMaxBytes) {
        self.hidMaxBytes = (uint32_t)reportedLength;
    }
    // UNVERIFIED REMOTE AUDIO.
    // This is a raw HID input report from product 0x0315. It is not PCM.
    // Button reports arrive here too. Nothing in this buffer is decoded,
    // and it is not passed to the virtual microphone. A longer report is
    // kept only so the length is real. The copy is discarded in endHold.
    if (data.length > self.longestReport.length) {
        self.longestReport = [NSMutableData dataWithData:data];
    }
}

- (void)publish {
    void (^changed)(void) = self.statusChanged;
    if (changed != nil) {
        changed();
    }
}

- (void)startReportLog {
    if (_logOpen) {
        return;
    }
    _logOpen = YES;
    [[NSFileManager defaultManager] createFileAtPath:RMVReportLogPath contents:[NSData data] attributes:nil];
    RMVAppendLog(@"start");
    _logManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (_logManager == NULL) {
        RMVAppendLog(@"open NULL");
        return;
    }
    NSDictionary *matching = @{
        @kIOHIDVendorIDKey: @0x004C,
        @kIOHIDProductIDKey: @0x0315
    };
    IOHIDManagerSetDeviceMatching(_logManager, (__bridge CFDictionaryRef)matching);
    IOHIDManagerRegisterDeviceMatchingCallback(_logManager, RMVLogDeviceMatched, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_logManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn opened = IOHIDManagerOpen(_logManager, kIOHIDOptionsTypeNone);
    RMVAppendLog([NSString stringWithFormat:@"open 0x%08X", (uint32_t)opened]);
    CFSetRef existing = IOHIDManagerCopyDevices(_logManager);
    if (existing != NULL) {
        CFIndex count = CFSetGetCount(existing);
        RMVAppendLog([NSString stringWithFormat:@"devices %ld", (long)count]);
        if (count > 0) {
            IOHIDDeviceRef *list = calloc((size_t)count, sizeof(IOHIDDeviceRef));
            if (list != NULL) {
                CFSetGetValues(existing, (const void **)list);
                for (CFIndex i = 0; i < count; i++) {
                    [self watchLogDevice:list[i]];
                }
                free(list);
            }
        }
        CFRelease(existing);
    }
}

- (void)watchLogDevice:(IOHIDDeviceRef)device {
    if (device == NULL) {
        return;
    }
    uint64_t registry = 0;
    io_service_t service = IOHIDDeviceGetService(device);
    if (service != IO_OBJECT_NULL) {
        IORegistryEntryGetRegistryEntryID(service, &registry);
    }
    for (RMVReportSlot *slot in _logSlots) {
        if (registry != 0 && slot.registry == registry) {
            return;
        }
    }
    int page = 0;
    int usage = 0;
    int maxSize = 0;
    CFTypeRef rawPage = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey));
    CFTypeRef rawUsage = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDPrimaryUsageKey));
    CFTypeRef rawMax = IOHIDDeviceGetProperty(device, CFSTR("MaxInputReportSize"));
    if (rawPage != NULL && CFGetTypeID(rawPage) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)rawPage, kCFNumberIntType, &page);
    }
    if (rawUsage != NULL && CFGetTypeID(rawUsage) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)rawUsage, kCFNumberIntType, &usage);
    }
    if (rawMax != NULL && CFGetTypeID(rawMax) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)rawMax, kCFNumberIntType, &maxSize);
    }
    // Larger than the descriptor max so a report the map calls short is not
    // cut off before its length is known. 512 matches the hold-path cap.
    CFIndex capacity = 512;
    uint8_t *buffer = calloc((size_t)capacity, 1);
    if (buffer == NULL) {
        RMVAppendLog([NSString stringWithFormat:@"watch page 0x%04X usage 0x%04X nomem", page, usage]);
        return;
    }
    IOHIDDeviceRegisterInputReportCallback(
        device,
        buffer,
        capacity,
        RMVLogInputReport,
        (__bridge void *)self
    );
    RMVReportSlot *slot = [[RMVReportSlot alloc] init];
    slot.device = (IOHIDDeviceRef)CFRetain(device);
    slot.buffer = buffer;
    slot.capacity = capacity;
    slot.registry = registry;
    [_logSlots addObject:slot];
    RMVAppendLog([NSString stringWithFormat:@"watch page 0x%04X usage 0x%04X max %d cap %ld", page, usage, maxSize, (long)capacity]);
}

static void RMVDeviceMatched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)sender;
    if (context == NULL || result != kIOReturnSuccess) {
        return;
    }
    [(__bridge RMVVoiceCapture *)context watchDevice:device];
}

static void RMVDeviceRemoved(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context;
    (void)result;
    (void)sender;
    (void)device;
}

static void RMVLogDeviceMatched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)sender;
    if (context == NULL || result != kIOReturnSuccess) {
        return;
    }
    [(__bridge RMVVoiceCapture *)context watchLogDevice:device];
}

static int RMVDeviceInt(IOHIDDeviceRef device, CFStringRef key) {
    if (device == NULL) {
        return 0;
    }
    CFTypeRef raw = IOHIDDeviceGetProperty(device, key);
    int value = 0;
    if (raw != NULL && CFGetTypeID(raw) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)raw, kCFNumberIntType, &value);
    }
    return value;
}

static void RMVAppendLog(NSString *line) {
    if (line == nil) {
        return;
    }
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("rmv.hid.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *row = [line copy];
    dispatch_async(queue, ^{
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:RMVReportLogPath];
        if (handle == nil) {
            return;
        }
        [handle seekToEndOfFile];
        NSString *text = [NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), row];
        [handle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

static void RMVLogInputReport(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    (void)context;
    (void)type;
    (void)report;
    if (result != kIOReturnSuccess) {
        RMVAppendLog([NSString stringWithFormat:@"watch err 0x%08X id 0x%02X len %ld", (uint32_t)result, reportID, (long)reportLength]);
        return;
    }
    IOHIDDeviceRef device = (IOHIDDeviceRef)sender;
    int page = RMVDeviceInt(device, CFSTR(kIOHIDPrimaryUsagePageKey));
    int usage = RMVDeviceInt(device, CFSTR(kIOHIDPrimaryUsageKey));
    RMVAppendLog([NSString stringWithFormat:@"watch page 0x%04X usage 0x%04X id 0x%02X len %ld", page, usage, reportID, (long)reportLength]);
}

static void RMVInputReport(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    (void)sender;
    (void)type;
    if (context == NULL || result != kIOReturnSuccess) {
        return;
    }
    RMVVoiceCapture *capture = (__bridge RMVVoiceCapture *)context;
    CFIndex full = reportLength > 0 ? reportLength : 0;
    RMVAppendLog([NSString stringWithFormat:@"hold id 0x%02X len %ld", reportID, (long)full]);
    NSData *copy = nil;
    if (report != NULL && full > 0) {
        CFIndex kept = full > RMVMaxReportBytes ? RMVMaxReportBytes : full;
        copy = [NSData dataWithBytes:report length:(NSUInteger)kept];
    }
    NSUInteger token = capture.generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (token != capture.generation || !capture.holding) {
            return;
        }
        [capture noteReportID:reportID data:copy reportedLength:full];
    });
}

@end
