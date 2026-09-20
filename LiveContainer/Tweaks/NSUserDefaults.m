//
//  NSUserDefaults.m
//  LiveContainer
//
//  Created by s s on 2024/11/29.
//

#import "FoundationPrivate.h"
#import "LCMachOUtils.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "../../litehook/src/litehook.h"
#include "Tweaks.h"
#include <signal.h>
@import ObjectiveC;
@import MachO;

BOOL hook_return_false(void) {
    return NO;
}

void swizzle2(Class class, SEL originalAction, Class class2, SEL swizzledAction) {
    Method m1 = class_getInstanceMethod(class2, swizzledAction);
    class_addMethod(class, swizzledAction, method_getImplementation(m1), method_getTypeEncoding(m1));
    method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
}

NSURL* appContainerURL = 0;
NSString* appContainerPath = 0;

void NUDGuestHooksInit(void) {
    appContainerPath = [NSString stringWithUTF8String:getenv("HOME")];
    appContainerURL = [NSURL URLWithString:appContainerPath];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    // fix for macOS host
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"CFPrefsPlistSource"), @selector(_isSharedInTheiOSSimulator)), (IMP)hook_return_false);
#endif

    Class CFPrefsPlistSourceClass = NSClassFromString(@"CFPrefsPlistSource");

    swizzle2(CFPrefsPlistSourceClass, @selector(initWithDomain:user:byHost:containerPath:containingPreferences:), CFPrefsPlistSource2.class, @selector(hook_initWithDomain:user:byHost:containerPath:containingPreferences:));
#pragma clang diagnostic pop
    
    Class CFXPreferencesClass = NSClassFromString(@"_CFXPreferences");
    NSMutableDictionary* sources = object_getIvar([CFXPreferencesClass copyDefaultPreferences], class_getInstanceVariable(CFXPreferencesClass, "_sources"));

    [sources removeObjectForKey:@"C/A//B/L"];
    [sources removeObjectForKey:@"C/C//*/L"];
    
    // replace _CFPrefsCurrentAppIdentifierCache so kCFPreferencesCurrentApplication refers to the guest app
    const char* coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    mach_header_u* coreFoundationHeader = LCGetLoadedImageHeader(2, coreFoundationPath);
    
#if !TARGET_OS_SIMULATOR
    CFStringRef* _CFPrefsCurrentAppIdentifierCache = getCachedSymbol(@"__CFPrefsCurrentAppIdentifierCache", coreFoundationHeader);
    if(!_CFPrefsCurrentAppIdentifierCache) {
        _CFPrefsCurrentAppIdentifierCache = litehook_find_dsc_symbol(coreFoundationPath, "__CFPrefsCurrentAppIdentifierCache");
        uint64_t offset = (uint64_t)((void*)_CFPrefsCurrentAppIdentifierCache - (void*)coreFoundationHeader);
        saveCachedSymbol(@"__CFPrefsCurrentAppIdentifierCache", coreFoundationHeader, offset);
    }
    [NSUserDefaults.lcUserDefaults _setIdentifier:(__bridge NSString*)CFStringCreateCopy(nil, *_CFPrefsCurrentAppIdentifierCache)];
    *_CFPrefsCurrentAppIdentifierCache = (__bridge CFStringRef)NSUserDefaults.lcGuestAppId;
#else
    // FIXME: for now we skip overwriting _CFPrefsCurrentAppIdentifierCache on simulator, since there is no way to find private symbol
#endif
    
    NSUserDefaults* newStandardUserDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"whatever"];
    [newStandardUserDefaults _setIdentifier:NSUserDefaults.lcGuestAppId];
    NSUserDefaults.standardUserDefaults = newStandardUserDefaults;

#if !TARGET_OS_SIMULATOR
    NSString* selectedLanguage = NSUserDefaults.guestAppInfo[@"LCSelectedLanguage"];
    if(selectedLanguage) {
        [newStandardUserDefaults setObject:@[selectedLanguage] forKey:@"AppleLanguages"];
        CFMutableArrayRef* _CFBundleUserLanguages = getCachedSymbol(@"__CFBundleUserLanguages", coreFoundationHeader);
        if(!_CFBundleUserLanguages) {
            _CFBundleUserLanguages = litehook_find_dsc_symbol(coreFoundationPath, "__CFBundleUserLanguages");
            uint64_t offset = (uint64_t)((void*)_CFBundleUserLanguages - (void*)coreFoundationHeader);
            saveCachedSymbol(@"__CFBundleUserLanguages", coreFoundationHeader, offset);
        }
        // set _CFBundleUserLanguages to selected languages
        NSMutableArray* newUserLanguages = [NSMutableArray arrayWithObjects:selectedLanguage, nil];
        *_CFBundleUserLanguages = (__bridge CFMutableArrayRef)newUserLanguages;
    } else {
        [newStandardUserDefaults removeObjectForKey:@"AppleLanguages"];
    }
#endif
    
    // Create Library/Preferences folder in app's data folder in case it does not exist
    NSFileManager* fm = NSFileManager.defaultManager;
    NSURL* libraryPath = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].lastObject;
    NSURL* preferenceFolderPath = [libraryPath URLByAppendingPathComponent:@"Preferences"];
    if(![fm fileExistsAtPath:preferenceFolderPath.path]) {
        NSError* error;
        [fm createDirectoryAtPath:preferenceFolderPath.path withIntermediateDirectories:YES attributes:@{} error:&error];
    }
    
}

/// Writes the guest's preferences out before it is killed.
///
/// A multitask guest is ended with SIGTERM, from `-[AppSceneViewController
/// terminate]`, and SIGTERM's default action stops the process where it stands.
/// CFPreferences does not persist on every change — it coalesces and flushes on a
/// timer, which is why the same setting came back saved or not depending on when
/// the window happened to be closed.
///
/// Flushing here is what puts the file in the right place, not merely an earlier
/// version of the same write. A guest's container is a staged copy inside the app
/// group, and the host swaps it back once the process is gone, so a write that
/// lands after that goes into the directory that was just swapped out and then
/// discarded. Synchronizing before this process exits happens before the host can
/// even learn it died, which is before the swap.
///
/// A dispatch source rather than a signal handler, because synchronizing
/// preferences is far more than a signal handler may do. SIGTERM is ignored first
/// so its default action cannot get there first, and the process ends with _exit,
/// so this stays what it was — an immediate death, now with the preferences
/// written — rather than starting to run exit handlers that never ran before.
///
/// Only the signalled death is covered. A guest killed outright with the host
/// still loses whatever CFPreferences had not written.
static dispatch_source_t terminationSource;
void NUDGuestFlushOnTerminationInit(void) {
    signal(SIGTERM, SIG_IGN);
    terminationSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if(!terminationSource) {
        signal(SIGTERM, SIG_DFL);
        return;
    }
    dispatch_source_set_event_handler(terminationSource, ^{
        // Closing a window was instant before this, and a wedged preferences
        // daemon must not be able to make it anything else. The host's own
        // SIGKILL is three seconds out, which is far too long to wait to find
        // out that a write is not coming.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            _exit(0);
        });

        [NSUserDefaults.standardUserDefaults synchronize];
        // Everything else the guest opened — suites, app groups — which the call
        // above does not reach. CFPreferences' own entry point for this: it takes
        // the lock that guards its sources and works from a copy made under it,
        // which reaching into `_sources` by hand would not.
        Class CFXPreferencesClass = NSClassFromString(@"_CFXPreferences");
        _CFXPreferences2* preferences = [CFXPreferencesClass copyDefaultPreferences];
        if([preferences respondsToSelector:@selector(synchronizeEverything)]) {
            [preferences synchronizeEverything];
        }
        _exit(0);
    });
    dispatch_resume(terminationSource);
}

NSArray* appleIdentifierPrefixes = @[
    @"com.apple.",
    @"group.com.apple.",
    @"systemgroup.com.apple."
];

bool isAppleIdentifier(NSString* identifier) {
    for(NSString* cur in appleIdentifierPrefixes) {
        if([identifier hasPrefix:cur]) {
            return true;
        }
    }
    return false;
}


@implementation CFPrefsPlistSource2
-(id)hook_initWithDomain:(CFStringRef)domain user:(CFStringRef)user byHost:(bool)host containerPath:(CFStringRef)containerPath containingPreferences:(id)arg5 {
    if(isAppleIdentifier((__bridge NSString*)domain)) {
        return [self hook_initWithDomain:domain user:user byHost:host containerPath:containerPath containingPreferences:arg5];
    }
    if(user == kCFPreferencesAnyUser) {
        user = kCFPreferencesCurrentUser;
    }
    return [self hook_initWithDomain:domain user:user byHost:host containerPath:(__bridge CFStringRef)appContainerPath containingPreferences:arg5];
}
@end
