//
//  AppSceneView.h
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "UIKitPrivate+MultitaskSupport.h"
#import "FoundationPrivate.h"
#import "LCGuestVolume.h"
@import UIKit;
@import Foundation;


@class AppSceneViewController;

/// The files a private app is staged into the app group with, for as long as it
/// runs in a window. Only closing the window brings them back, so a FlekDeck
/// killed with windows open leaves them behind.
@interface LCWindowStaging : NSObject
/// Settles the data containers those windows left staged, keeping whichever copy
/// holds the later session, and drops the staged bundle and tweak copies. Also
/// clears the copies builds before the staging folder left among the shared
/// apps, where they were listed as a second, shared copy of the app. Call once
/// at launch, before the app list is read.
+ (void)recoverAfterLaunch;
@end

API_AVAILABLE(ios(16.0))
@protocol AppSceneViewControllerDelegate <NSObject>
- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc;
- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError*)error;
@optional
- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType;
- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc;
/// The guest's scene is about to be created from these settings. The window owns
/// the geometry they carry — its own frame, the drawable the guest is handed and
/// the insets the guest keeps clear — and this is the last moment to put the
/// current answer in. A window is built long before its guest starts, and what was
/// true then is not always still true now.
- (void)appSceneVC:(AppSceneViewController*)vc willPresentSceneWithSettings:(UIMutableApplicationSceneSettings *)settings;
/// The guest's scene has been presented — its content is now on screen as fast as
/// the guest can draw it, which for an app still starting up means its own launch
/// screen. Unlike a settings update, which only arrives if the guest changes
/// something, this happens for every guest exactly once.
- (void)appSceneVCDidPresentScene:(AppSceneViewController*)vc;
@end

API_AVAILABLE(ios(16.0))
@interface AppSceneViewController : UIViewController<_UISceneSettingsDiffAction>
@property(nonatomic) NSString* bundleId;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) id<AppSceneViewControllerDelegate> delegate;
@property(nonatomic) BOOL isAppRunning;
@property(nonatomic) BOOL shouldIgnoreSceneUpdates, shouldSkipDebounceOnce;
@property(nonatomic) CGFloat scaleRatio;
/// Volume control for this window's guest.
@property(nonatomic, readonly) LCGuestVolume *audio;
@property(nonatomic) UIView* contentView;
@property(nonatomic) _UIScenePresenter *presenter;
@property(nonatomic) UIMutableApplicationSceneSettings *settings;
/// Applied to the scene the next time this window lays out. Set by the window
/// when geometry changes while the guest is not in a position to be told yet.
@property(nonatomic) void(^nextUpdateSettingsBlock)(UIMutableApplicationSceneSettings *settings);
/// Whether the teardown has already run, so a caller closing this window can
/// tell a guest that exited on its own from one that never got to start.
@property(nonatomic, readonly) bool isAppTerminationCleanUpCalled;
@property(nonatomic) _UISceneHostingController *hostingController API_AVAILABLE(ios(17.0));
- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block;
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))block;
- (void)appTerminationCleanUp;
- (void)terminate;
- (void)openURLScheme:(NSString *)urlString;
- (void)handleStatusBarTapAction:(UIAction *)action;
- (BOOL)usesHostingControllerAPI;
/// The CAContext the guest publishes its video into when it asks to float, or 0
/// if it did not manage to. Hosting this rather than the guest's whole scene is
/// what puts the video, and nothing around it, in the PiP window.
@property(nonatomic) uint32_t guestVideoContextId;
/// The size of the whole published context.
@property(nonatomic) CGSize guestVideoSize;
/// Where the picture sits inside that context. What AVKit hands the guest as its
/// PiP source is a container, with the video somewhere below it at whatever size
/// the app's layout gave it — so hosting the context whole puts a small picture
/// in the corner of a large empty window. The host clips to this instead.
@property(nonatomic) CGRect guestVideoRect;
/// Tells the guest to take its video layer back. It is out of the app's own tree
/// for as long as the window is floating, and PiP usually ends by a route the app
/// hears nothing about.
- (void)notifyGuestPiPEnded;
/// Tells the guest the float has actually begun, which is when the app may be
/// told its PiP started. Told any earlier, the app replaces its video with a
/// placeholder for a window that may never appear.
- (void)notifyGuestPiPStarted;
/// Asks the guest to publish its video and float, for a window that is leaving
/// the stage while LiveContainer itself stays in front.
- (void)requestGuestFloat;
/// Whether the guest has a video it could float, and how big. Known well before
/// anything floats, because AVKit only starts a controller that already existed
/// when the app backgrounded — so the armed controller has to be the
/// video-shaped one from the moment the guest has a video at all.
@property(nonatomic) BOOL guestHasVideo;
@end

