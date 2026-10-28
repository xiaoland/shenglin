#import "LockButton.h"
#import <XCTest/XCTest.h>
#import <notify.h>

// XCTest has no public lock button. These test-only calls are checked at runtime.
BOOL SLPressLockButton(void) {
    id device = XCUIDevice.sharedDevice;
    SEL selector = NSSelectorFromString(@"pressLockButton");
    if (![device respondsToSelector:selector]) return NO;
    ((void (*)(id, SEL))[device methodForSelector:selector])(device, selector);
    return YES;
}

uint64_t SLLockState(void) {
    int token;
    uint64_t state = UINT64_MAX;
    if (notify_register_check("com.apple.springboard.lockstate", &token) == NOTIFY_STATUS_OK) {
        notify_get_state(token, &state);
        notify_cancel(token);
    }
    return state;
}
