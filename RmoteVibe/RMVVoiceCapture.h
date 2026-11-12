#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Watches the paired A2854 while Siri is held.
// Public IOBluetooth and IOHID only. This object does not decode audio
// and does not write PCM. Raw HID bytes stay inside this object for the
// hold and are discarded on release.
@interface RMVVoiceCapture : NSObject
@property (nonatomic, readonly) BOOL holding;
@property (nonatomic, readonly) BOOL deviceFound;
@property (nonatomic, readonly) BOOL deviceConnected;
@property (nonatomic, readonly) BOOL matchedBySerial;
@property (nonatomic, copy, readonly, nullable) NSString *deviceName;
@property (nonatomic, copy, readonly, nullable) NSString *deviceAddress;
@property (nonatomic, readonly) BOOL sdpFinished;
@property (nonatomic, readonly) BOOL sdpSkipped;
@property (nonatomic, readonly) int32_t sdpStatus;
@property (nonatomic, readonly) uint32_t sdpServiceCount;
@property (nonatomic, copy, readonly) NSString *sdpServiceSummary;
@property (nonatomic, readonly) BOOL sawHIDService;
@property (nonatomic, readonly) BOOL sawClassicAudioUUID;
@property (nonatomic, readonly) BOOL sawAndroidTVVoiceService;
@property (nonatomic, readonly) uint32_t l2capCount;
@property (nonatomic, copy, readonly) NSString *l2capSummary;
@property (nonatomic, readonly) uint32_t hidReportCount;
@property (nonatomic, readonly) uint32_t hidMaxBytes;
@property (nonatomic, copy, readonly) NSString *hidReportIDs;
@property (nonatomic, readonly) int32_t hidOpenStatus;
@property (nonatomic, readonly) int32_t hidRegisterStatus;
@property (nonatomic, copy, nullable) void (^statusChanged)(void);
/// Bluetooth address last paired in Settings. Empty is fine; HID VID/PID
/// 0x004C/0x0315 is enough to treat the remote as connected.
@property (nonatomic, copy) NSString *preferredAddress;

- (void)beginHold;
- (void)endHold;

// Opens a second, non-seizing IOHID manager and appends input report id
// and length until the process quits. Independent of the hold. No payload.
// Does not send an output report.
- (void)startReportLog;
@end

NS_ASSUME_NONNULL_END
