#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString * _Nullable RMVCurrentInputSourceID(void);
BOOL RMVInputSourceExists(NSString *identifier);
BOOL RMVSelectInputSourceID(NSString *identifier);

NS_ASSUME_NONNULL_END
