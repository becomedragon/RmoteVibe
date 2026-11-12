#import "RMVInputSources.h"
#import <Carbon/Carbon.h>

static NSString *RMVCopyID(TISInputSourceRef source) {
    CFTypeRef value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return nil;
    }
    return [(__bridge NSString *)value copy];
}

static BOOL RMVWithSources(BOOL (^body)(TISInputSourceRef source)) {
    CFArrayRef list = TISCreateInputSourceList(NULL, false);
    if (list == NULL) {
        return NO;
    }
    BOOL result = NO;
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex index = 0; index < count; index++) {
        TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(list, index);
        if (body(source)) {
            result = YES;
            break;
        }
    }
    CFRelease(list);
    return result;
}

NSString *RMVCurrentInputSourceID(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (current == NULL) {
        return nil;
    }
    NSString *identifier = RMVCopyID(current);
    CFRelease(current);
    return identifier;
}

BOOL RMVInputSourceExists(NSString *identifier) {
    if (identifier.length == 0) {
        return NO;
    }
    return RMVWithSources(^BOOL(TISInputSourceRef source) {
        NSString *found = RMVCopyID(source);
        return [found isEqualToString:identifier];
    });
}

BOOL RMVSelectInputSourceID(NSString *identifier) {
    if (identifier.length == 0) {
        return NO;
    }
    return RMVWithSources(^BOOL(TISInputSourceRef source) {
        NSString *found = RMVCopyID(source);
        if (![found isEqualToString:identifier]) {
            return NO;
        }
        return TISSelectInputSource(source) == noErr;
    });
}
