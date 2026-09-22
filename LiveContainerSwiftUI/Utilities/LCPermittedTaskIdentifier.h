//
//  LCPermittedTaskIdentifier.h
//  LiveContainerSwiftUI
//
//  Permits a background-task identifier that can only be known at runtime.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Adds `identifier` to `BGTaskSchedulerPermittedIdentifiers` in the main bundle's
/// in-memory Info.plist. Returns nil when the identifier is permitted — already,
/// or now — and a short reason otherwise.
NSString* _Nullable LCPermitBackgroundTaskIdentifier(NSString* identifier);

NS_ASSUME_NONNULL_END
