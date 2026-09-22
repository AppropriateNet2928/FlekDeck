//
//  LCPermittedTaskIdentifier.m
//  LiveContainerSwiftUI
//
//  Permits a background-task identifier that can only be known at runtime.
//
//  BGTaskScheduler only accepts a task identifier under an entry in
//  BGTaskSchedulerPermittedIdentifiers that starts with the running bundle
//  identifier. That identifier isn't known when the app is built: every user's
//  copy is re-signed under a bundle ID of its own, so an entry written into the
//  Info.plist at build time matches nobody's install but the developer's.
//
//  The scheduler reads the list from [NSBundle.mainBundle infoDictionary] — the
//  in-memory dictionary, not the file — once, on the first registration, and
//  keeps it for the life of the process. So the right entry can be added to that
//  dictionary before the first registration, and the scheduler sees it as if it
//  had been signed in.
//
//  The dictionary is patched in place the same way LCHostIdentity patches the
//  extension's, for the same reasons.
//

#import "LCPermittedTaskIdentifier.h"
#import "../../LiveContainer/FoundationPrivate.h"

static NSString* const permittedIdentifiersKey = @"BGTaskSchedulerPermittedIdentifiers";

NSString* LCPermitBackgroundTaskIdentifier(NSString* identifier) {
    NSBundle* bundle = NSBundle.mainBundle;
    NSArray* listed = bundle.infoDictionary[permittedIdentifiersKey];
    if(listed && ![listed isKindOfClass:NSArray.class]) {
        return @"permitted identifiers is not an array";
    }
    if([listed containsObject:identifier]) {
        return nil;
    }

    if(![bundle respondsToSelector:@selector(_cfBundle)]) {
        return @"no _cfBundle";
    }
    CFBundleRef bundleRef = (__bridge CFBundleRef)[bundle _cfBundle];
    if(!bundleRef || CFGetTypeID(bundleRef) != CFBundleGetTypeID()) {
        return @"not a CFBundle";
    }
    id info = (__bridge id)CFBundleGetInfoDictionary(bundleRef);
    if(![info isKindOfClass:NSDictionary.class] || ![info respondsToSelector:@selector(setObject:forKey:)]) {
        return @"info dictionary not mutable";
    }

    // Through the ObjC bridge, never CFDictionarySetValue: CF's mutability check
    // aborts the process with nothing to catch, where this path raises an ordinary
    // exception instead.
    NSArray* patched = [(listed ?: @[]) arrayByAddingObject:identifier];
    @try {
        [(NSMutableDictionary*)info setObject:patched forKey:permittedIdentifiersKey];
    } @catch(NSException* exception) {
        return @"info dictionary rejected the write";
    }

    // Believe the read, not the write — and read it exactly the way the scheduler
    // does. A Foundation that hands out a copy would take the write and ignore it.
    NSArray* readBack = bundle.infoDictionary[permittedIdentifiersKey];
    if(![readBack isKindOfClass:NSArray.class] || ![readBack containsObject:identifier]) {
        return @"NSBundle did not read it back";
    }
    return nil;
}
