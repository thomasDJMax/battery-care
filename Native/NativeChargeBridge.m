#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
#include "NativeCharge.h"

/*
 This optional bridge uses a private Apple framework at runtime. On macOS
 27.0.1 the selectors and ABI were verified; 80% set/readback and restoration
 to the original 100% default state were also tested without privileges.
 The framework can change; a missing selector or ABI mismatch disables the
 bridge. Nothing here accesses SMC keys, installs helpers, or requests root.
 */

#if __has_feature(objc_arc)
#define IA_RETAIN_CLIENT(value) (value)
#else
#define IA_RETAIN_CLIENT(value) [(value) retain]
#endif

typedef id (*IAInitCall)(id, SEL, id);
typedef BOOL (*IABoolCall)(id, SEL);
typedef id (*IAArrayCall)(id, SEL, NSError *__autoreleasing *);
typedef unsigned char (*IALimitCall)(id, SEL, NSError *__autoreleasing *);
typedef unsigned long long (*IAEnabledCall)(id, SEL, NSError *__autoreleasing *);
typedef BOOL (*IASetCall)(id, SEL, unsigned char, NSError *__autoreleasing *);
typedef BOOL (*IADisableCall)(id, SEL, NSError *__autoreleasing *);

static id iaClient;
static NSLock *iaLock;
static NSString *iaUnavailableReason;

static BOOL IAHasABI(Class cls, const char *name, const char *expected) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    const char *actual = method == NULL ? NULL : method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, expected) == 0;
}

static void IAInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iaLock = [[NSLock alloc] init];
        @try {
            void *framework = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW | RTLD_LOCAL);
            if (framework == NULL) {
                iaUnavailableReason = @"系统充电接口暂不可用，请在系统设置中调整充电上限。";
                return;
            }
            Class cls = NSClassFromString(@"PowerUISmartChargeClient");
            if (cls == Nil ||
                !IAHasABI(cls, "initWithClientName:", "@24@0:8@16") ||
                !IAHasABI(cls, "isMCLSupported", "B16@0:8") ||
                !IAHasABI(cls, "availableChargeLimitsWithError:", "@24@0:8^@16") ||
                !IAHasABI(cls, "getMCLLimitWithError:", "C24@0:8^@16") ||
                !IAHasABI(cls, "isMCLCurrentlyEnabled:", "Q24@0:8^@16") ||
                !IAHasABI(cls, "setMCLLimit:error:", "B28@0:8C16^@20") ||
                !IAHasABI(cls, "disableMCL:", "B24@0:8^@16")) {
                iaUnavailableReason = @"当前系统的充电接口版本不兼容，请在系统设置中调整充电上限。";
                return;
            }
            id allocated = [cls alloc];
            id initialized = ((IAInitCall)objc_msgSend)(allocated, sel_registerName("initWithClientName:"), @"iAdente");
            if (initialized == nil) {
                iaUnavailableReason = @"无法连接系统充电服务。";
                return;
            }
            iaClient = IA_RETAIN_CLIENT(initialized);
        } @catch (NSException *exception) {
            iaClient = nil;
            iaUnavailableReason = @"系统充电接口初始化失败，请在系统设置中调整充电上限。";
        }
    });
}

static BOOL IAKnownLimit(int value) {
    return value == 80 || value == 85 || value == 90 || value == 95 || value == 100;
}

/* All callers hold iaLock and catch any Objective-C exception. */
static NSArray<NSNumber *> *IAAvailableLimits(NSString **reason) {
    if (iaClient == nil) {
        if (reason != NULL) *reason = iaUnavailableReason ?: @"系统充电接口暂不可用。";
        return nil;
    }
    if (!((IABoolCall)objc_msgSend)(iaClient, sel_registerName("isMCLSupported"))) {
        if (reason != NULL) *reason = @"这台 Mac 暂不支持系统充电上限。";
        return nil;
    }
    NSError *failure = nil;
    id result = ((IAArrayCall)objc_msgSend)(iaClient, sel_registerName("availableChargeLimitsWithError:"), &failure);
    if (failure != nil || ![result isKindOfClass:[NSArray class]]) {
        if (reason != NULL) *reason = failure.localizedDescription ?: @"无法读取系统支持的充电上限。";
        return nil;
    }
    NSMutableArray<NSNumber *> *valid = [NSMutableArray array];
    for (id number in (NSArray *)result) {
        if ([number isKindOfClass:[NSNumber class]] && IAKnownLimit([number intValue]) &&
            [number doubleValue] == (double)[number intValue]) {
            [valid addObject:number];
        }
    }
    if (valid.count == 0) {
        if (reason != NULL) *reason = @"系统没有返回兼容的充电上限。";
        return nil;
    }
    return valid;
}

static void IACopyError(char *buffer, int capacity, NSString *reason) {
    if (buffer != NULL && capacity > 0) {
        const char *description = reason.UTF8String;
        snprintf(buffer, (size_t)capacity, "%s", description != NULL ? description : "System charging service unavailable.");
    }
}

int IAChargeSupported(void) {
    @autoreleasepool {
        IAInitialize();
        [iaLock lock];
        int supported = 0;
        @try { supported = IAAvailableLimits(NULL) != nil ? 1 : 0; }
        @catch (NSException *exception) { supported = 0; }
        @finally { [iaLock unlock]; }
        return supported;
    }
}

int IAChargeCurrentLimit(void) {
    @autoreleasepool {
        IAInitialize();
        [iaLock lock];
        int limit = -1;
        @try {
            NSArray<NSNumber *> *available = IAAvailableLimits(NULL);
            if (available != nil) {
                NSError *failure = nil;
                int value = ((IALimitCall)objc_msgSend)(iaClient, sel_registerName("getMCLLimitWithError:"), &failure);
                if (failure == nil && [available containsObject:@(value)]) limit = value;
            }
        } @catch (NSException *exception) { limit = -1; }
        @finally { [iaLock unlock]; }
        return limit;
    }
}

int IAChargeEnabled(void) {
    @autoreleasepool {
        IAInitialize();
        [iaLock lock];
        int enabled = -1;
        @try {
            if (IAAvailableLimits(NULL) != nil) {
                NSError *failure = nil;
                unsigned long long value = ((IAEnabledCall)objc_msgSend)(iaClient, sel_registerName("isMCLCurrentlyEnabled:"), &failure);
                if (failure == nil) enabled = value != 0 ? 1 : 0;
            }
        } @catch (NSException *exception) { enabled = -1; }
        @finally { [iaLock unlock]; }
        return enabled;
    }
}

int IAChargeSetLimit(int limit, char *error, int capacity) {
    IACopyError(error, capacity, @"");
    if (!IAKnownLimit(limit)) {
        IACopyError(error, capacity, @"系统充电上限仅支持 80%、85%、90%、95% 和 100%。");
        return 0;
    }
    @autoreleasepool {
        IAInitialize();
        [iaLock lock];
        int accepted = 0;
        @try {
            NSString *reason = nil;
            NSArray<NSNumber *> *available = IAAvailableLimits(&reason);
            if (![available containsObject:@(limit)]) {
                IACopyError(error, capacity, reason ?: @"当前系统不支持所选充电上限。");
            } else {
                NSError *failure = nil;
                BOOL ok = ((IASetCall)objc_msgSend)(iaClient, sel_registerName("setMCLLimit:error:"), (unsigned char)limit, &failure);
                accepted = ok && failure == nil ? 1 : 0;
                if (!accepted) IACopyError(error, capacity, failure.localizedDescription ?: @"系统未接受充电上限，请在系统设置中调整。");
            }
        } @catch (NSException *exception) {
            IACopyError(error, capacity, @"系统充电接口发生错误，请在系统设置中调整充电上限。");
        } @finally { [iaLock unlock]; }
        return accepted;
    }
}

int IAChargeDisable(char *error, int capacity) {
    IACopyError(error, capacity, @"");
    @autoreleasepool {
        IAInitialize();
        [iaLock lock];
        int accepted = 0;
        @try {
            NSString *reason = nil;
            if (IAAvailableLimits(&reason) == nil) {
                IACopyError(error, capacity, reason);
            } else {
                NSError *failure = nil;
                BOOL ok = ((IADisableCall)objc_msgSend)(iaClient, sel_registerName("disableMCL:"), &failure);
                accepted = ok && failure == nil ? 1 : 0;
                if (!accepted) IACopyError(error, capacity, failure.localizedDescription ?: @"系统未接受关闭充电上限的请求。");
            }
        } @catch (NSException *exception) {
            IACopyError(error, capacity, @"系统充电接口发生错误，请在系统设置中关闭充电上限。");
        } @finally { [iaLock unlock]; }
        return accepted;
    }
}
