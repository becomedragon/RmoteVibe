#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RMVDiscoveredRemote : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *address;
@property (nonatomic, readonly) BOOL nameLooksLikeRemote;
@end

// LE inquiry plus IOBluetooth pairing. Blocks are invoked on the main queue.
// A paired HID device is only confirmed later, when IOHID sees product 0x0315.
@interface RMVBluetooth : NSObject
@property (nonatomic, copy, nullable) void (^devicesChanged)(NSArray<RMVDiscoveredRemote *> *devices);
@property (nonatomic, copy, nullable) void (^searchFinished)(int32_t status);
@property (nonatomic, copy, nullable) void (^pairFinished)(int32_t status);

- (int32_t)startSearch;
- (void)stopSearch;
- (int32_t)pairAddress:(NSString *)address;
- (void)cancelPairing;
/// Opens a Bluetooth ACL/LE link to an already-paired remote. Does not open
/// L2CAP or HID. HID product 0x0315 is still the connected signal.
- (int32_t)reconnectAddress:(NSString *)address;
- (BOOL)isAddressConnected:(NSString *)address;
- (BOOL)isAddressPaired:(NSString *)address;
- (nullable NSString *)deviceNameForAddress:(NSString *)address;
- (nullable NSString *)resolvedAddressForAddress:(NSString *)address;
@end

NS_ASSUME_NONNULL_END
