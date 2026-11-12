#import "RMVBluetooth.h"
#import <IOBluetooth/IOBluetooth.h>

@interface RMVDiscoveredRemote ()
- (instancetype)initWithName:(NSString *)name address:(NSString *)address looksLikeRemote:(BOOL)looks;
@end

@implementation RMVDiscoveredRemote
- (instancetype)initWithName:(NSString *)name address:(NSString *)address looksLikeRemote:(BOOL)looks {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _address = [address copy];
        _nameLooksLikeRemote = looks;
    }
    return self;
}
@end

@interface RMVBluetooth () <IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate>
@property (nonatomic, strong) IOBluetoothDeviceInquiry *inquiry;
@property (nonatomic, strong) IOBluetoothDevicePair *pair;
@property (nonatomic, strong) NSMutableDictionary<NSString *, IOBluetoothDevice *> *devices;
@property (nonatomic, assign) BOOL pairInFlight;
- (IOBluetoothDevice *)lookupAddress:(NSString *)address;
@end

@implementation RMVBluetooth

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _devices = [NSMutableDictionary dictionary];
    }
    return self;
}

- (int32_t)startSearch {
    [self stopSearch];
    [self.devices removeAllObjects];
    [self publish];
    IOBluetoothDeviceInquiry *inquiry = [[IOBluetoothDeviceInquiry alloc] initWithDelegate:self];
    if (inquiry == nil) {
        return (int32_t)kIOReturnNoMemory;
    }
    inquiry.searchType = kIOBluetoothDeviceSearchLE;
    inquiry.updateNewDeviceNames = YES;
    inquiry.inquiryLength = 8;
    self.inquiry = inquiry;
    IOReturn status = [inquiry start];
    return (int32_t)status;
}

- (void)stopSearch {
    [self.inquiry stop];
    self.inquiry = nil;
}

- (int32_t)pairAddress:(NSString *)address {
    IOBluetoothDevice *device = self.devices[address];
    if (device == nil) {
        return (int32_t)kIOReturnNotFound;
    }
    [self cancelPairing];
    IOBluetoothDevicePair *pair = [[IOBluetoothDevicePair alloc] init];
    if (pair == nil) {
        return (int32_t)kIOReturnNoMemory;
    }
    [pair setDevice:device];
    pair.delegate = self;
    self.pair = pair;
    self.pairInFlight = YES;
    IOReturn status = [pair start];
    if (status != kIOReturnSuccess) {
        self.pairInFlight = NO;
    }
    return (int32_t)status;
}

- (void)cancelPairing {
    self.pairInFlight = NO;
    [self.pair stop];
    self.pair = nil;
}

- (int32_t)reconnectAddress:(NSString *)address {
    IOBluetoothDevice *device = [self lookupAddress:address];
    if (device == nil) {
        return (int32_t)kIOReturnNotFound;
    }
    if (device.isConnected) {
        return (int32_t)kIOReturnSuccess;
    }
    return (int32_t)[device openConnection];
}

- (BOOL)isAddressConnected:(NSString *)address {
    IOBluetoothDevice *device = [self lookupAddress:address];
    return device != nil && device.isConnected;
}

- (BOOL)isAddressPaired:(NSString *)address {
    IOBluetoothDevice *device = [self lookupAddress:address];
    return device != nil && device.isPaired;
}

static NSString *RMVCanonicalAddress(NSString *raw);

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

- (IOBluetoothDevice *)lookupAddress:(NSString *)address {
    NSString *wanted = RMVCanonicalAddress(address);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (address.length > 0) {
        [candidates addObject:address];
    }
    NSString *colon = RMVColonAddressFromHex(wanted);
    if (colon.length > 0) {
        [candidates addObject:colon];
    }
    for (NSString *candidate in candidates) {
        IOBluetoothDevice *found = [IOBluetoothDevice deviceWithAddressString:candidate];
        if (found != nil) {
            return found;
        }
    }
    NSArray *paired = [IOBluetoothDevice pairedDevices];
    IOBluetoothDevice *named = nil;
    for (id item in paired) {
        if (![item isKindOfClass:[IOBluetoothDevice class]]) {
            continue;
        }
        IOBluetoothDevice *found = (IOBluetoothDevice *)item;
        if (wanted.length > 0 && [RMVCanonicalAddress(found.addressString) isEqualToString:wanted]) {
            return found;
        }
        if (named == nil && [self looksLikeRemote:found.name ?: @""]) {
            named = found;
        }
    }
    if (wanted.length == 0) {
        return named;
    }
    return nil;
}

static NSString *RMVCanonicalAddress(NSString *raw) {
    if (raw.length == 0) {
        return @"";
    }
    NSCharacterSet *keep = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([keep characterIsMember:c]) {
            [hex appendString:[[NSString stringWithCharacters:&c length:1] uppercaseString]];
        }
    }
    return hex;
}

- (void)publish {
    NSMutableArray<RMVDiscoveredRemote *> *rows = [NSMutableArray array];
    [self.devices enumerateKeysAndObjectsUsingBlock:^(NSString *address, IOBluetoothDevice *device, BOOL *stop) {
        (void)stop;
        NSString *name = device.name;
        if (name.length == 0) {
            name = address;
        }
        BOOL looks = [self looksLikeRemote:name];
        [rows addObject:[[RMVDiscoveredRemote alloc] initWithName:name address:address looksLikeRemote:looks]];
    }];
    [rows sortUsingComparator:^NSComparisonResult(RMVDiscoveredRemote *a, RMVDiscoveredRemote *b) {
        if (a.nameLooksLikeRemote != b.nameLooksLikeRemote) {
            return a.nameLooksLikeRemote ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    void (^changed)(NSArray *) = self.devicesChanged;
    if (changed == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        changed(rows);
    });
}

- (BOOL)looksLikeRemote:(NSString *)name {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"siri"] ||
        [lower containsString:@"apple tv"] ||
        [lower containsString:@"remote"];
}

- (void)remember:(IOBluetoothDevice *)device {
    if (device == nil) {
        return;
    }
    NSString *address = device.addressString;
    if (address.length == 0) {
        return;
    }
    self.devices[address] = device;
    [self publish];
}

- (void)finishPair:(IOReturn)status {
    if (!self.pairInFlight) {
        return;
    }
    self.pairInFlight = NO;
    void (^done)(int32_t) = self.pairFinished;
    if (done == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        done((int32_t)status);
    });
}

#pragma mark Inquiry

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device {
    (void)sender;
    [self remember:device];
}

- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry *)sender
                                 device:(IOBluetoothDevice *)device
                       devicesRemaining:(uint32_t)devicesRemaining {
    (void)sender;
    (void)devicesRemaining;
    [self remember:device];
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
    (void)sender;
    (void)aborted;
    void (^done)(int32_t) = self.searchFinished;
    if (done == nil) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        done((int32_t)error);
    });
}

#pragma mark Pair

- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)numericValue {
    (void)numericValue;
    if ([sender isKindOfClass:[IOBluetoothDevicePair class]]) {
        [(IOBluetoothDevicePair *)sender replyUserConfirmation:YES];
    }
}

- (void)devicePairingPINCodeRequest:(id)sender {
    if ([sender isKindOfClass:[IOBluetoothDevicePair class]]) {
        [(IOBluetoothDevicePair *)sender stop];
    }
    [self finishPair:kIOReturnUnsupported];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    (void)sender;
    [self finishPair:error];
}

- (void)deviceSimplePairingComplete:(id)sender status:(BluetoothHCIEventStatus)status {
    (void)sender;
    if (status == 0) {
        [self finishPair:kIOReturnSuccess];
    } else {
        [self finishPair:kIOReturnError];
    }
}

@end
