//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "LCGuestCaptureNotice.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import <notify.h>
#import <stdio.h>
#import <sys/stdio.h>
#import <sys/clonefile.h>
#import <sys/stat.h>
#import <sys/xattr.h>

#pragma mark - App group staging

// A private app's bundle and data container live in FlekDeck's own
// container, which LiveProcess cannot read, so both are staged into the app
// group before the guest starts and the container is brought back when it
// exits.
//
// Upstream LiveContainer hands LiveProcess security-scoped bookmarks to the
// private files instead, and on iOS 26.4 those stopped opening for most private
// apps (upstream issue #1265). The "Open Private Apps in Windows Without
// Copying" developer switch goes back to bookmarks, to test whether they work
// on a given build and iOS version.
//
// Staged files go under LiveContainer/Staging/<this FlekDeck's URL scheme>,
// never beside the shared apps. A copy in LiveContainer/Applications is
// indistinguishable from a shared app: one left behind by a FlekDeck killed with
// a window open appeared on the home screen as a second, shared copy of the app,
// which could be neither deleted nor converted. A folder per FlekDeck also keeps
// two of them that run the same app from staging over each other's copy, and
// keeps the shared apps' own Tweaks folder out of it.
//
// This used to be remove-then-copy run inline on the main thread. Both halves
// scale with the number of files rather than their size, so an app with a large
// asset tree froze the UI for seconds at each end — which is why big games and
// media-heavy apps felt so much worse to open and close than small ones, and
// why the window animation stuttered. Measured on a 20k-file tree: a recursive
// remove is ~610ms and NSFileManager's copy ~1660ms, against ~140ms to clone
// the tree and ~0.1ms to rename it.
//
// So nothing here removes or copies a tree on the path the user is waiting on:
// trees are cloned into place, displaced by a rename, and deleted later.

// Serial: two windows opening at once would otherwise race on the same staged
// bundle, and each stage is short enough that serialising them costs nothing.
static dispatch_queue_t LCStagingQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.livecontainer.multitask.staging", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Live windows per staged bundle. A bundle is shared by every window running
// that app, so it may only be staged while nobody is using it and may only be
// discarded once the last window has gone. Without this, opening a second
// window re-staged the bundle out from under the running one, and closing
// either window deleted the bundle the other was still executing from.
static NSCountedSet *LCStagedBundleUsers(void) {
    static NSCountedSet *users;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ users = [NSCountedSet new]; });
    return users;
}

static NSURL *LCStagingTrashURL(NSURL *appGroupLC) {
    return [appGroupLC URLByAppendingPathComponent:@".StagingTrash"];
}

// Deleting a large tree is one unlink per file. Renaming it into the trash is a
// single operation, which is all the caller has to wait for; the deletion
// itself happens later, off any path the user can see.
static BOOL LCDiscardTree(NSURL *url, NSURL *appGroupLC) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:url.path]) {
        return YES;
    }
    NSURL *trashDir = LCStagingTrashURL(appGroupLC);
    [fm createDirectoryAtURL:trashDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *grave = [trashDir URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if(rename(url.path.fileSystemRepresentation, grave.path.fileSystemRepresentation) == 0) {
        return YES;
    }
    // Same-volume rename should not fail here, but never leave the caller with
    // a path it believes is clear.
    return [fm removeItemAtURL:url error:nil];
}

static void LCSweepStagingTrash(NSURL *appGroupLC) {
    NSURL *trashDir = LCStagingTrashURL(appGroupLC);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // Its own manager: NSFileManager.defaultManager is not safe to drive
        // from an arbitrary queue while the rest of the app is using it.
        NSFileManager *fm = [NSFileManager new];
        NSArray<NSURL *> *graves = [fm contentsOfDirectoryAtURL:trashDir includingPropertiesForKeys:nil options:0 error:nil];
        for(NSURL *grave in graves) {
            [fm removeItemAtURL:grave error:nil];
        }
    });
}

// clonefile gives an APFS copy-on-write clone of an entire tree in one call: no
// file data is duplicated and no per-file copy work is done, so it costs a
// fraction of NSFileManager's copy and almost no disk.
static BOOL LCCloneTree(NSURL *src, NSURL *dst) {
    if(clonefile(src.path.fileSystemRepresentation, dst.path.fileSystemRepresentation, 0) == 0) {
        return YES;
    }
    // Not APFS, or the two ended up on different volumes. Correctness first.
    // Logged because the copy is orders of magnitude slower: if staging is ever
    // sluggish again, this line is the difference between "the clone stopped
    // working" and "something else is at fault".
    NSLog(@"[LC] staging: clonefile unavailable for %@ (%s), falling back to a full copy",
          src.lastPathComponent, strerror(errno));
    // Clear anything a half-finished clone may have left, or the copy would only
    // fail again on a destination that already exists.
    NSError *error = nil;
    [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    if([NSFileManager.defaultManager copyItemAtURL:src toURL:dst error:&error]) {
        return YES;
    }
    NSLog(@"[LC] staging: failed to stage %@: %@", src.lastPathComponent, error);
    return NO;
}

// Replace whatever is at dst with a clone of src.
static BOOL LCStageTree(NSURL *src, NSURL *dst, NSURL *appGroupLC) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:dst.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    // Cleared even when there is nothing to stage: a container left in the app
    // group by a run that never got to clean up must not be handed to the guest
    // as though it were its own.
    LCDiscardTree(dst, appGroupLC);
    if(![fm fileExistsAtPath:src.path]) {
        return NO;
    }
    return LCCloneTree(src, dst);
}

// Where this FlekDeck's windows stage their files, relative to the app group's
// LiveContainer folder. LiveProcess is handed this path, and looks for a staged
// app there and nowhere else.
static NSString *LCStagingRelativePath(void) {
    NSString *scheme = NSUserDefaults.lcAppUrlScheme;
    return [@"Staging" stringByAppendingPathComponent:scheme.length > 0 ? scheme : @"flekdeck"];
}

static NSURL *LCStagingRootURL(NSURL *appGroupLC) {
    return [appGroupLC URLByAppendingPathComponent:LCStagingRelativePath() isDirectory:YES];
}

// Timestamps that move when an app starts in a data container. The launcher
// recreates the `tmp` symlink at the container's root on every start
// (invokeAppMain in LCBootstrap.m), which moves both the link's own time and the
// folder's. FlekDeck writing the container's settings file moves only the
// folder's, so the link is the one to trust for a container in our Documents.
typedef struct {
    struct timespec tmpLink;   // {0, 0} when there is no link
    struct timespec folder;
} LCContainerStamp;

// Both containers' stamps as they were when the copy was made, kept on the copy.
typedef struct {
    LCContainerStamp staged;
    LCContainerStamp local;
} LCStagingMark;

static const char *const LCStagingMarkName = "com.flekdeck.staging-mark";

static LCContainerStamp LCReadContainerStamp(NSURL *container) {
    LCContainerStamp stamp = {{0, 0}, {0, 0}};
    struct stat st;
    NSString *tmpLink = [container.path stringByAppendingPathComponent:@"tmp"];
    if(lstat(tmpLink.fileSystemRepresentation, &st) == 0) {
        stamp.tmpLink = st.st_mtimespec;
    }
    if(stat(container.path.fileSystemRepresentation, &st) == 0) {
        stamp.folder = st.st_mtimespec;
    }
    return stamp;
}

static BOOL LCTimespecEqual(struct timespec a, struct timespec b) {
    return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec;
}

static BOOL LCTimespecIsLater(struct timespec a, struct timespec b) {
    return a.tv_sec != b.tv_sec ? a.tv_sec > b.tv_sec : a.tv_nsec > b.tv_nsec;
}

static void LCWriteStagingMark(NSURL *staged, NSURL *local) {
    LCStagingMark mark = { LCReadContainerStamp(staged), LCReadContainerStamp(local) };
    if(setxattr(staged.path.fileSystemRepresentation, LCStagingMarkName, &mark, sizeof(mark), 0, 0) != 0) {
        NSLog(@"[LC] staging: could not mark %@: %s", staged.lastPathComponent, strerror(errno));
    }
}

// Whether a staged copy of a data container holds a later session than the
// container in our Documents, and so should replace it.
//
// A copy made by this build carries a mark with both containers' stamps from
// when it was made, so the question is only which of them an app has started in
// since. That compares each container with itself, which moving the device
// clock in between cannot upset, and some games are played with the clock moved
// back and forth. The copy wins if an app started in it and not in the one in
// Documents. An app started in both means the one in Documents was opened in
// single mode after the copy's window was lost with FlekDeck, so it is the later
// of the two.
//
// Copies left by older builds carry no mark, and all there is to compare then is
// when each was last started.
static BOOL LCStagedContainerIsNewer(NSURL *staged, NSURL *local) {
    LCContainerStamp stagedNow = LCReadContainerStamp(staged);
    LCContainerStamp localNow = LCReadContainerStamp(local);
    LCStagingMark mark;
    if(getxattr(staged.path.fileSystemRepresentation, LCStagingMarkName, &mark, sizeof(mark), 0, 0) == sizeof(mark)) {
        BOOL startedInCopy = !LCTimespecEqual(stagedNow.tmpLink, mark.staged.tmpLink) ||
                             !LCTimespecEqual(stagedNow.folder, mark.staged.folder);
        BOOL startedInLocal = !LCTimespecEqual(localNow.tmpLink, mark.local.tmpLink);
        return startedInCopy && !startedInLocal;
    }
    struct timespec stagedStart = stagedNow.tmpLink.tv_sec || stagedNow.tmpLink.tv_nsec ? stagedNow.tmpLink : stagedNow.folder;
    struct timespec localStart = localNow.tmpLink.tv_sec || localNow.tmpLink.tv_nsec ? localNow.tmpLink : localNow.folder;
    return LCTimespecIsLater(stagedStart, localStart);
}

// Whether a process that is still running holds this container. The lock names
// the process that took it and reads as free once that process has gone, so a
// copy left by a FlekDeck that was killed is not mistaken for one in use.
static BOOL LCContainerIsInUse(NSString *folderName) {
    return [LCSharedUtils getContainerUsingLCSchemeWithFolderName:folderName] != nil;
}

// Settles a staged copy of a data container against the one in our Documents,
// keeping whichever holds the later session and discarding the other. The caller
// makes sure no running process still holds the copy.
//
// Runs when a window closes, and for a copy whose window never got to close,
// because FlekDeck was killed with it open: at launch, and before the same
// container is staged again. Putting the copy back unconditionally lost data
// both ways round. A copy found at launch can be older than the container in
// Documents if the app has been opened in single mode since. And with "Allow
// Private Data access from LiveProcess" on, a window can run on the container in
// Documents directly, leaving its copy untouched to be swapped back over it.
static void LCReclaimStagedContainer(NSURL *stagedData, NSURL *localData, NSURL *appGroupLC) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:stagedData.path]) {
        return;
    }
    BOOL localExists = [fm fileExistsAtPath:localData.path];
    if(localExists && !LCStagedContainerIsNewer(stagedData, localData)) {
        LCDiscardTree(stagedData, appGroupLC);
        return;
    }
    // Swapped back rather than deleted-and-copied. Besides trading a walk of
    // every file for a single rename, this removes the window in which the
    // local container had been deleted and its replacement not yet written:
    // being killed in there used to lose the guest's data outright.
    //
    // Nothing below clears the local container until its replacement is
    // somewhere safe, so a failure at any step costs the session's changes
    // at worst, never the container.
    if(!localExists) {
        [fm createDirectoryAtURL:localData.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if(localExists &&
       renameatx_np(AT_FDCWD, stagedData.path.fileSystemRepresentation,
                    AT_FDCWD, localData.path.fileSystemRepresentation,
                    RENAME_SWAP) == 0) {
        // The swap left the older copy where the staged one was.
        LCDiscardTree(stagedData, appGroupLC);
    } else if(!localExists &&
              rename(stagedData.path.fileSystemRepresentation, localData.path.fileSystemRepresentation) == 0) {
        // First run of this container, so there was nothing to swap with.
    } else {
        // Swapping is unsupported here. Land a copy beside the container
        // first and only then put it in place.
        NSURL *incoming = [localData URLByAppendingPathExtension:@"incoming"];
        LCDiscardTree(incoming, appGroupLC);
        if(!LCCloneTree(stagedData, incoming)) {
            NSLog(@"[LC] staging: could not copy container %@ back, leaving it staged", localData.lastPathComponent);
            return;
        }
        LCDiscardTree(localData, appGroupLC);
        if(rename(incoming.path.fileSystemRepresentation, localData.path.fileSystemRepresentation) != 0) {
            NSLog(@"[LC] staging: failed to reclaim container %@: %s", localData.lastPathComponent, strerror(errno));
            return;
        }
        LCDiscardTree(stagedData, appGroupLC);
    }
    // The mark describes a copy, and this is the container in Documents now.
    removexattr(localData.path.fileSystemRepresentation, LCStagingMarkName, 0);
}

// Blocking; call on LCStagingQueue. Returns whether the app was claimed and so
// has to be released through LCUnstageAppFromAppGroup later.
static BOOL LCStageAppToAppGroup(NSString *bundleId, NSString *dataUUID) {
    NSURL *appGroupPath = [LCSharedUtils appGroupPath];
    if(!appGroupPath) {
        return NO;
    }
    NSURL *appGroupLC = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
    NSURL *stagingRoot = LCStagingRootURL(appGroupLC);
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:stagingRoot withIntermediateDirectories:YES attributes:nil error:nil];

    // Claim the bundle before touching it. Several windows can run the same app,
    // and they all execute from this one staged copy, so it may only be replaced
    // while nobody is using it — re-staging it under a running guest leaves that
    // guest unable to load anything it had not already mapped.
    NSCountedSet *users = LCStagedBundleUsers();
    BOOL bundleAlreadyInUse;
    @synchronized(users) {
        bundleAlreadyInUse = [users countForObject:bundleId] > 0;
        [users addObject:bundleId];
    }
    if(!bundleAlreadyInUse) {
        NSURL *srcBundle = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Applications/%@", bundleId]];
        NSURL *dstBundle = [stagingRoot URLByAppendingPathComponent:[NSString stringWithFormat:@"Applications/%@", bundleId]];
        LCStageTree(srcBundle, dstBundle, appGroupLC);
    }

    // The data container belongs to this window alone, so it is always staged
    // fresh and handed back when the window closes. A copy still here from a
    // window FlekDeck was killed under is settled first rather than cleared: it
    // may be the only place that session's changes exist.
    NSURL *srcData = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    NSURL *dstData = [stagingRoot URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    LCReclaimStagedContainer(dstData, srcData, appGroupLC);
    if(LCStageTree(srcData, dstData, appGroupLC)) {
        LCWriteStagingMark(dstData, srcData);
    }

    // Tweaks, refreshed every launch like the bundle and the container above.
    // Staging once froze this folder at whatever existed the first time the
    // device ever ran anything in parallel, so a tweak installed or updated
    // afterwards was present in single mode — which reads the live
    // Documents/Tweaks — and silently missing here. A premium check living in a
    // tweak then worked in one mode and not the other.
    //
    // Swapped in rather than overwritten in place: multitask runs several guests
    // at once, and clearing the folder before refilling it leaves a window in
    // which a guest starting concurrently finds no tweaks at all. renameatx_np
    // with RENAME_SWAP exchanges the two directories in one step, so a guest
    // sees either the old set or the new one.
    //
    // Staged beside the bundle, not into the app group's own Tweaks folder. That
    // one holds the shared apps' tweaks, and swapping a copy of ours in over it
    // deleted them every time a private app opened in a window.
    NSURL *srcTweaks = [docURL URLByAppendingPathComponent:@"Tweaks"];
    NSURL *dstTweaks = [stagingRoot URLByAppendingPathComponent:@"Tweaks"];
    if ([fm fileExistsAtPath:srcTweaks.path]) {
        NSURL *stagedTweaks = [stagingRoot URLByAppendingPathComponent:@"Tweaks.staging"];
        LCDiscardTree(stagedTweaks, appGroupLC);
        if (LCCloneTree(srcTweaks, stagedTweaks)) {
            if (renameatx_np(AT_FDCWD, stagedTweaks.path.fileSystemRepresentation,
                             AT_FDCWD, dstTweaks.path.fileSystemRepresentation,
                             RENAME_SWAP) == 0) {
                // The swap left the previous set where the staging copy was.
                LCDiscardTree(stagedTweaks, appGroupLC);
            } else {
                // Nothing to swap with on the first ever parallel launch. Clear
                // the destination first: a plain rename will not replace a
                // non-empty directory, and failing here would leave the guest
                // running against a stale set of tweaks.
                LCDiscardTree(dstTweaks, appGroupLC);
                rename(stagedTweaks.path.fileSystemRepresentation, dstTweaks.path.fileSystemRepresentation);
            }
        }
    }

    LCSweepStagingTrash(appGroupLC);
    return YES;
}

// Blocking; call on LCStagingQueue. reclaimData brings the guest's container
// back over the local one if the guest ran in it — pass NO when the guest never
// started.
static void LCUnstageAppFromAppGroup(NSString *bundleId, NSString *dataUUID, BOOL reclaimData) {
    // Released first, and unconditionally: bailing out below with the claim still
    // held would pin the bundle for the rest of the session, so it would never be
    // re-staged and never cleaned up.
    NSCountedSet *users = LCStagedBundleUsers();
    BOOL wasLastUser;
    @synchronized(users) {
        [users removeObject:bundleId];
        wasLastUser = [users countForObject:bundleId] == 0;
    }

    NSURL *appGroupPath = [LCSharedUtils appGroupPath];
    if(!appGroupPath) {
        return;
    }
    NSURL *appGroupLC = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
    NSURL *stagingRoot = LCStagingRootURL(appGroupLC);
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;

    NSURL *stagedData = [stagingRoot URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    NSURL *localData = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
    if(reclaimData) {
        LCReclaimStagedContainer(stagedData, localData, appGroupLC);
    } else {
        LCDiscardTree(stagedData, appGroupLC);
    }

    // The bundle is shared between every window running this app, so it only
    // goes once the last of them has exited.
    if(wasLastUser) {
        NSURL *stagedBundle = [stagingRoot URLByAppendingPathComponent:[NSString stringWithFormat:@"Applications/%@", bundleId]];
        LCDiscardTree(stagedBundle, appGroupLC);
    }

    LCSweepStagingTrash(appGroupLC);
}

// The data container folder names an app's settings file lists. Container
// folders are named by UUID, so two settings files that share one describe the
// same app.
static NSSet<NSString *> *LCContainerFolderNames(NSDictionary *appInfo) {
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSString *dataUUID = appInfo[@"LCDataUUID"];
    if([dataUUID isKindOfClass:NSString.class] && dataUUID.length > 0) {
        [names addObject:dataUUID];
    }
    NSArray *containers = appInfo[@"LCContainers"];
    if([containers isKindOfClass:NSArray.class]) {
        for(NSDictionary *container in containers) {
            if(![container isKindOfClass:NSDictionary.class]) {
                continue;
            }
            NSString *folderName = container[@"folderName"];
            if([folderName isKindOfClass:NSString.class] && folderName.length > 0) {
                [names addObject:folderName];
            }
        }
    }
    return names;
}

// Whether a bundle among the shared apps is a copy an older build staged for a
// window of the private app with the same folder name, rather than a shared app
// in its own right. The copy carries the app's settings file over as it was, so
// it has the same installation date or, if the app has been updated since, at
// least one data container in common. A separately installed app has neither.
static BOOL LCIsStagedCopyOf(NSDictionary *copyInfo, NSDictionary *appInfo) {
    if(![copyInfo isKindOfClass:NSDictionary.class] || ![appInfo isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDate *copyInstalled = copyInfo[@"installationDate"];
    NSDate *appInstalled = appInfo[@"installationDate"];
    if([copyInstalled isKindOfClass:NSDate.class] && [appInstalled isKindOfClass:NSDate.class] &&
       [copyInstalled isEqualToDate:appInstalled]) {
        return YES;
    }
    return [LCContainerFolderNames(copyInfo) intersectsSet:LCContainerFolderNames(appInfo)];
}

// Brings back what this FlekDeck's windows had staged when it was killed. The
// data containers are settled the way a closing window settles them, and the
// bundle and tweak copies, being only copies, go. Anything a guest that outlived
// its FlekDeck still holds is left for a later launch.
static void LCRecoverStagingRoot(NSURL *appGroupLC, NSURL *docURL) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *stagingRoot = LCStagingRootURL(appGroupLC);
    if(![fm fileExistsAtPath:stagingRoot.path]) {
        return;
    }
    NSURL *stagedDataDir = [stagingRoot URLByAppendingPathComponent:@"Data/Application"];
    NSURL *localDataDir = [docURL URLByAppendingPathComponent:@"Data/Application"];
    BOOL anyInUse = NO;
    for(NSString *folderName in [fm contentsOfDirectoryAtPath:stagedDataDir.path error:nil]) {
        if(LCContainerIsInUse(folderName)) {
            anyInUse = YES;
            continue;
        }
        NSLog(@"[LC] staging: settling container %@, left staged by a window FlekDeck was killed under", folderName);
        LCReclaimStagedContainer([stagedDataDir URLByAppendingPathComponent:folderName],
                                 [localDataDir URLByAppendingPathComponent:folderName], appGroupLC);
    }
    if(anyInUse) {
        return;
    }
    LCDiscardTree([stagingRoot URLByAppendingPathComponent:@"Applications"], appGroupLC);
    LCDiscardTree([stagingRoot URLByAppendingPathComponent:@"Tweaks"], appGroupLC);
    LCDiscardTree([stagingRoot URLByAppendingPathComponent:@"Tweaks.staging"], appGroupLC);
}

// Clears what builds before the staging folder left among the shared apps. They
// staged into LiveContainer/Applications and LiveContainer/Data/Application
// directly, so the copy of a window that never closed was listed as a shared app
// with the same folder name as the private one. On the home screen it took the
// private app's place and could be neither deleted nor converted.
static void LCRecoverLegacyStagedCopies(NSURL *appGroupLC, NSURL *docURL) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *sharedApps = [appGroupLC URLByAppendingPathComponent:@"Applications"];
    NSURL *privateApps = [docURL URLByAppendingPathComponent:@"Applications"];
    NSURL *sharedDataDir = [appGroupLC URLByAppendingPathComponent:@"Data/Application"];
    NSURL *localDataDir = [docURL URLByAppendingPathComponent:@"Data/Application"];
    for(NSString *folderName in [fm contentsOfDirectoryAtPath:sharedApps.path error:nil]) {
        if(![folderName hasSuffix:@".app"]) {
            continue;
        }
        NSURL *copy = [sharedApps URLByAppendingPathComponent:folderName];
        NSURL *app = [privateApps URLByAppendingPathComponent:folderName];
        NSDictionary *copyInfo = [NSDictionary dictionaryWithContentsOfURL:[copy URLByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfURL:[app URLByAppendingPathComponent:@"LCAppInfo.plist"]];
        if(!LCIsStagedCopyOf(copyInfo, appInfo)) {
            continue;
        }
        NSSet<NSString *> *containers = LCContainerFolderNames(copyInfo);
        BOOL inUse = NO;
        for(NSString *container in containers) {
            if(LCContainerIsInUse(container)) {
                inUse = YES;
                break;
            }
        }
        if(inUse) {
            continue;
        }
        NSLog(@"[LC] staging: removing a window copy of %@ left among the shared apps", folderName);
        for(NSString *container in containers) {
            LCReclaimStagedContainer([sharedDataDir URLByAppendingPathComponent:container],
                                     [localDataDir URLByAppendingPathComponent:container], appGroupLC);
        }
        LCDiscardTree(copy, appGroupLC);
    }
    // Only ever there part-way through refreshing the tweaks, which older builds
    // did in the shared folder itself.
    LCDiscardTree([appGroupLC URLByAppendingPathComponent:@"Tweaks.staging"], appGroupLC);
}

@implementation LCWindowStaging

+ (void)recoverAfterLaunch {
    NSURL *appGroupPath = [LCSharedUtils appGroupPath];
    if(!appGroupPath) {
        return;
    }
    NSURL *appGroupLC = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    // On the staging queue like every other move of these folders. Nothing else
    // is queued this early, so this waits for nothing but itself.
    dispatch_sync(LCStagingQueue(), ^{
        LCRecoverStagingRoot(appGroupLC, docURL);
        LCRecoverLegacyStagedCopies(appGroupLC, docURL);
    });
    LCSweepStagingTrash(appGroupLC);
}

@end

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@property bool stagedToAppGroup;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic, readwrite) bool isAppTerminationCleanUpCalled;
/// Registrations on the guest's PiP requests, for as long as the guest is running.
@property(nonatomic) NSNumber *pipStartToken;
@property(nonatomic) NSNumber *pipStopToken;
@property(nonatomic) NSNumber *pipReadyToken;
/// Raises the Single Mode sheet when the guest is refused the microphone.
@property(nonatomic) LCGuestCaptureNotice *captureNotice;
@end

/// The device orientation to hand a guest, derived from the orientation UIKit has
/// actually settled the host into rather than read from the accelerometer.
///
/// `UIDevice.currentDevice.orientation` reports where the *hardware* is pointing,
/// and nothing suppresses it — not the app's supported orientations, and not the
/// user's Portrait Orientation Lock, which is a display setting the sensor knows
/// nothing about. Handing that to a guest tells it the phone turned at moments
/// when the host has been told it may not follow, so the guest turns inside a
/// window that did not, and a rotation the user explicitly locked out happens
/// anyway.
///
/// Taking the host's interface orientation instead makes the guest agree with the
/// window it is drawn into by construction, and inherits every rule UIKit already
/// applied to reach it — Portrait Orientation Lock included. Device and interface
/// landscape names are mirror images: a phone turned so its bottom edge is on the
/// right shows an interface whose top is on the left.
/// Whether guest geometry may currently be re-derived — flat phone or manual
/// lock. See the matching predicate in DecoratedAppSceneViewController.
static BOOL LCRotationIsLocked(void) {
    return LCRotationLock.isLocked;
}

static UIDeviceOrientation LCDeviceOrientationForInterface(UIInterfaceOrientation orientation) {
    switch(orientation) {
        case UIInterfaceOrientationPortrait:           return UIDeviceOrientationPortrait;
        case UIInterfaceOrientationLandscapeLeft:      return UIDeviceOrientationLandscapeRight;
        case UIInterfaceOrientationLandscapeRight:     return UIDeviceOrientationLandscapeLeft;
        case UIInterfaceOrientationPortraitUpsideDown: return UIDeviceOrientationPortraitUpsideDown;
        // Not portrait. `UIInterfaceOrientationUnknown` is zero, and so is the
        // result of asking a view that is momentarily out of a window for its
        // scene's orientation — so folding unknown into a `default` that answers
        // portrait turns "I could not tell" into a positive instruction to stand
        // upright. It can only ever manufacture portrait, never landscape, which
        // is why it showed as landscape collapsing while portrait looked fine.
        default:                                       return UIDeviceOrientationUnknown;
    }
}

@implementation AppSceneViewController

// Readonly with a hand-written getter, so the backing store is not synthesized.
@synthesize audio = _audio;


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIView alloc] init];
    // Black, not clear: the guest's presentation view doesn't always cover this
    // view (aspect mismatch, mid-rotation), and a clear backdrop would let the
    // decorated container's colour show through the gap.
    self.view.backgroundColor = UIColor.blackColor;
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error) {
        [delegate appSceneVC:self didInitializeWithError:error];
        return nil;
    }
    _extension.preferredLanguages = @[];
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray* bookmarks = [NSMutableArray array];
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    BOOL sharePrivateData = [NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"];
    if (sharePrivateData) {
        NSData* bookmarkData = [docURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
        if(bookmarkData) {
            [bookmarks addObject:bookmarkData];
        }
    }

    // A private app is staged into this FlekDeck's folder in the app group (see
    // "App group staging" above), unless the developer switch asks for it to be
    // handed over through bookmarks as upstream does. The guest is told which,
    // so that it never looks for a private app among the shared ones.
    bool isSharedApp = false;
    NSBundle *bundle = [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&isSharedApp];
    BOOL withoutCopying = !isSharedApp && ![bundleId isEqualToString:@"builtinSideStore"] &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"LCOpenPrivateAppsWithoutCopying"];
    if (withoutCopying) {
        if (!sharePrivateData) {
            // The bundle, this window's container and the tweaks, as upstream
            // hands them over. Upstream adds these unchecked; a missing one here
            // is left for the guest to report, rather than crashing the window.
            NSMutableArray<NSURL *> *urls = [NSMutableArray array];
            if (bundle.bundleURL) {
                [urls addObject:bundle.bundleURL];
            }
            [urls addObject:[docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]]];
            [urls addObject:[docURL URLByAppendingPathComponent:@"Tweaks"]];
            for (NSURL *url in urls) {
                NSData *bookmarkData = [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
                if (bookmarkData) {
                    [bookmarks addObject:bookmarkData];
                } else {
                    NSLog(@"[LC] could not make a bookmark for %@", url.path);
                }
            }
        }
        userInfo[@"privateAppViaAccessPasses"] = @YES;
    } else if (!isSharedApp) {
        userInfo[@"stagingPath"] = LCStagingRelativePath();
    }

    item.userInfo = userInfo;

    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        [weakSelf appTerminationCleanUp];
        [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];

    _isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;

    // Staging walks the whole bundle and data container, so it runs on the
    // staging queue and the guest starts once it is finished — the window can be
    // built and animated in while it happens, instead of the main thread sitting
    // on it.
    if (isSharedApp || withoutCopying) {
        [self beginExtensionRequestWithItem:item delegate:delegate];
    } else {
        NSString *stagingBundleId = bundleId;
        NSString *stagingDataUUID = dataUUID;
        dispatch_async(LCStagingQueue(), ^{
            BOOL staged = LCStageAppToAppGroup(stagingBundleId, stagingDataUUID);
            dispatch_async(dispatch_get_main_queue(), ^{
                AppSceneViewController *strongSelf = weakSelf;
                if(!strongSelf || strongSelf.isAppTerminationCleanUpCalled) {
                    // The window was closed while we were staging. Hand the
                    // bundle back rather than pinning it for the whole session.
                    if(staged) {
                        dispatch_async(LCStagingQueue(), ^{
                            LCUnstageAppFromAppGroup(stagingBundleId, stagingDataUUID, NO);
                        });
                    }
                    return;
                }
                strongSelf.stagedToAppGroup = staged;
                [strongSelf beginExtensionRequestWithItem:item delegate:delegate];
            });
        });
    }

    return self;
}

// The delegate is passed in rather than read from self: -viewDidMoveToWindow:
// clears self.delegate on teardown, and this callback still has to reach the
// object that asked for the launch.
- (void)beginExtensionRequestWithItem:(NSExtensionItem *)item delegate:(id<AppSceneViewControllerDelegate>)delegate {
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        if(identifier) {
            [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
            self.identifier = identifier;
            self.pid = [self.extension pidForRequestIdentifier:self.identifier];
            [delegate appSceneVC:self didInitializeWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setUpAppPresenter];
            });
        } else {
            NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
            [delegate appSceneVC:self didInitializeWithError:error];
        }
    }];
}

- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;
        // Baseline geometry for a windowed scene. A maximized one is re-derived
        // by the delegate at the bottom of this block, which has the last word.
        settings.interfaceOrientation = UIApplication.sharedApplication.statusBarOrientation;
        UIDeviceOrientation guestDevice = LCDeviceOrientationForInterface(settings.interfaceOrientation);
        // Only ever written with a real answer; unknown leaves the guest as it is.
        if(guestDevice != UIDeviceOrientationUnknown) settings.deviceOrientation = guestDevice;
        if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, self.view.frame.size.height, self.view.frame.size.width);
        } else {
            settings.frame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height);
        }
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
        if(!self.usesHostingControllerAPI) {
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets;
        }
        // A native window keeps the real window's insets, which is more specific
        // than the view's and so is applied after it.
        if(self.isNativeWindow) {
            UIEdgeInsets defaultInsets = self.view.window.safeAreaInsets;
            settings.peripheryInsets = defaultInsets;
            settings.safeAreaInsetsPortrait = defaultInsets;
        }
        // The window has the last word on geometry. This settings object was
        // filled in when the window was built, which is long before the guest
        // gets here — early enough that the switcher bar may not have been laid
        // out yet and so had no strip to reserve. Whatever was stale then would
        // otherwise be baked into the scene as it is created, and the guest would
        // lay out for a screen it is not in.
        if([self.delegate respondsToSelector:@selector(appSceneVC:willPresentSceneWithSettings:)]) {
            [self.delegate appSceneVC:self willPresentSceneWithSettings:settings];
        }
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 18.0, *)) {
        // Use new API for iOS 18+. While some of these APIs are available since 17.0, we're only interested in fixing event deferring issue
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not need, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
        NSAssert(deferringComponent, @"Unexpectedly nil _UISceneEventDeferringHostComponent");
        if (@available(iOS 27.0, *)) { // _UIKeyboardArbiterUsesDeferringGraph()
            /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
            /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work
            
            /// Replicate these methods since they are made private
            /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
            [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
            // if (!deferringComponent->_flags.clientIsInChain) return;
            /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
            // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)
            
            deferringComponent.grantBehavior = 2;
            deferringComponent.selectionRequestBehavior = 2;
        }
        /// UIKitCore`-[_UISceneHostingController createSceneWithConfiguration:]
        /// Lower iOS uses _UISceneHostingEventDeferringExtension, no further setup needed
        
        // Now it's time to get the initial settings from decorated VC
        [self.delegate appSceneVCWillActivateScene:self];
        [self addChildViewController:self.hostingController.sceneViewController];
        
        // For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;
        
        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];
        
        self.contentView = [[UIView alloc] init];
        [self.contentView addSubview:self.presenter.presentationView];
    }
    [self.view addSubview:_contentView];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    
    // Black out every layer between us and the guest's rendered content. The
    // host view sits above self.view, so colouring self.view alone still left
    // white showing wherever the guest's drawable is smaller than the container
    // (landscape aspect mismatch, mid-rotation).
    [self applyBackdropColor];

    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];

    [self beginObservingGuestPiPRequests];
    [self beginObservingGuestCaptureRefusals];

    if([self.delegate respondsToSelector:@selector(appSceneVCDidPresentScene:)]) {
        [self.delegate appSceneVCDidPresentScene:self];
    }
}

- (void)terminate {
    if(self.isAppRunning) {
        [self.extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.extension _kill:SIGKILL];
        });
    } else {
        // No process to signal yet — most likely the window was closed while its
        // files were still being staged. Tear down anyway: that releases the
        // staged bundle and stops a guest that has not started from outliving
        // the window that asked for it. A no-op if the teardown already ran.
        [self appTerminationCleanUp];
    }
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    [self applyBackdropColor];
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
}

// Re-stamped rather than set once: UIKit can swap or re-style the presentation
// view when the guest flips orientation, which would drop a one-shot colour.
- (void)applyBackdropColor {
    self.view.backgroundColor = UIColor.blackColor;
    self.contentView.backgroundColor = UIColor.blackColor;
    self.presenter.presentationView.backgroundColor = UIColor.blackColor;
}

- (void)viewWillLayoutSubviews {
    [self applyBackdropColor];
    void (^pendingBlock)(UIMutableApplicationSceneSettings *) = self.nextUpdateSettingsBlock;
    self.nextUpdateSettingsBlock = nil;
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:pendingBlock];
    }
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        // HARD LOCK: hold the guest's geometry while the phone is flat. The frame
        // computed below is what reshapes the drawable, and a reshape reads as a
        // rotation to any app that lays out responsively. Gated on the scene
        // already having a frame so first-time setup is never blocked.
        if(LCRotationIsLocked() && self.presenter.scene.settings.frame.size.width > 0) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            // HARD LOCK: leave both alone while the phone is flat.
            //
            // `settings` here is a copy of the guest's own live settings, so not
            // writing means it keeps the orientation it already had. This matters
            // more than it looks: the value written here is not only handed to the
            // guest, it also drives the width/height swap that reshapes the
            // content view in `updateSettingsWithBlock:`. Stamping the host's
            // (upright) orientation on a turned guest re-shapes its drawable even
            // where the orientation itself never reaches the scene.
            if(!LCRotationIsLocked()) {
                settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
                UIDeviceOrientation guestDevice = LCDeviceOrientationForInterface(settings.interfaceOrientation);
                // Only ever written with a real answer; unknown leaves it as it is.
                if(guestDevice != UIDeviceOrientationUnknown) settings.deviceOrientation = guestDevice;
            }
            CGRect frame = self.view.frame;
            if(!self.usesHostingControllerAPI) {
                frame.size.width /= self.scaleRatio;
                frame.size.height /= self.scaleRatio;
            }
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGSize size = frame.size;
                frame.size.width = size.height;
                frame.size.height = size.width;
            }
            settings.frame = frame;
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    if(!_hostingController && self.contentView) {
        // Legacy path
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    
    /// iOS 18.0 path, most are automatically handled by setting values to _UISceneHostingViewController
    /// This is also reachable on legacy path when contentView is nil during early setup
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
    
    if (self.contentView) {
        BOOL isiOS26 = NO;
        if(@available(iOS 19.0, *)) { if(@available(iOS 27.0, *)) {} else isiOS26 = YES; }
        // Discard position
        frame.origin = CGPointZero;
        self.contentView.frame = frame;
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;

    [_audio invalidate];
    [self endObservingGuestPiPRequests];
    [_captureNotice invalidate];
    _captureNotice = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Bring the guest's container back and release the staged bundle. This
        // is off the closing path entirely now: it used to delete the local
        // container and copy thousands of files back over it while the close
        // animation was waiting to run, which is what made large apps take so
        // long to shut.
        //
        // Claimed here rather than above because staging finishes on this queue
        // too. Deciding on the main thread orders the two against each other, so
        // a window closed while it was still staging is released exactly once —
        // by whichever of the two runs second.
        if (self.stagedToAppGroup) {
            self.stagedToAppGroup = false;
            NSString *bundleId = self.bundleId;
            NSString *dataUUID = self.dataUUID;
            dispatch_async(LCStagingQueue(), ^{
                LCUnstageAppFromAppGroup(bundleId, dataUUID, YES);
            });
        }

        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                [self.hostingController invalidate];
                [self.hostingController.sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

#pragma mark - Guest PiP requests

/// Listens for the guest asking to be put into Picture in Picture.
///
/// A guest cannot hold a PiP window of its own: the window's content is a scene
/// SpringBoard creates with the requesting process as its scene client, and
/// FrontBoard refuses to make an app extension one, so the guest's own attempt
/// produces a window that is permanently black. LiveContainer, being an ordinary
/// installed app, has no such trouble. So LCGuestPiP swallows the request inside
/// the guest and posts it here instead, and the window floats the way any other
/// window does when PiP is chosen from its card.
///
/// Registered once the guest is running, which is the earliest anything can ask.
- (void)beginObservingGuestPiPRequests {
    if(self.pipStartToken || self.pipStopToken) return;
    // The same fixed literal keyed by container that LCAudioMute's channel uses,
    // and for the same reason: the two processes each work the app group id out
    // for themselves, and they only have to disagree once for every request to
    // vanish.
    NSString *base = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@", self.dataUUID];
    __weak typeof(self) weakSelf = self;

    int startToken = 0;
    if(notify_register_dispatch([base stringByAppendingString:@".start"].UTF8String, &startToken,
                                dispatch_get_main_queue(), ^(int token) {
        // The request carries the id of the CAContext the guest's video is being
        // rendered into, in the name's 64-bit state. A sample buffer layer holds
        // no pixels — its video is decoded out of process and reaches the layer
        // as a hosted context — so this number is the whole of the video, and
        // the host can host it exactly as the guest does.
        uint64_t state = 0;
        notify_get_state(token, &state);
        [weakSelf handleGuestPiPStartWithPayload:state];
    }) == NOTIFY_STATUS_OK) {
        self.pipStartToken = @(startToken);
    }

    int readyToken = 0;
    if(notify_register_dispatch([base stringByAppendingString:@".videoready"].UTF8String, &readyToken,
                                dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        [weakSelf handleGuestVideoReady:CGSizeMake(state & 0xFFFF, (state >> 16) & 0xFFFF)];
    }) == NOTIFY_STATUS_OK) {
        self.pipReadyToken = @(readyToken);
    }

    int stopToken = 0;
    if(notify_register_dispatch([base stringByAppendingString:@".stop"].UTF8String, &stopToken,
                                dispatch_get_main_queue(), ^(int token) {
        [weakSelf handleGuestPiPStop];
    }) == NOTIFY_STATUS_OK) {
        self.pipStopToken = @(stopToken);
    }
}

/// Listens for the guest being refused the microphone.
///
/// iOS does not let an app extension record, and every multitask guest is one,
/// so a call placed in a window like this is silent in both directions — the
/// Voice Processing unit a VoIP app drives does capture and playback together,
/// and the refusal stops the whole unit rather than just its microphone half.
/// Nothing surfaces: the call connects, the timer runs, and neither side is
/// heard. LCGuestCapture watches for the refusal inside the guest and posts it
/// here, and the window raises a sheet explaining that the microphone needs
/// Single Mode, and how to get there.
///
/// Registered once the guest is running, which is the earliest anything can fail.
- (void)beginObservingGuestCaptureRefusals {
    if(self.captureNotice) return;
    self.captureNotice = [[LCGuestCaptureNotice alloc] initWithDataUUID:self.dataUUID];
    self.captureNotice.hostViewController = self;
}

- (void)endObservingGuestPiPRequests {
    if(self.pipStartToken) {
        notify_cancel(self.pipStartToken.intValue);
        self.pipStartToken = nil;
    }
    if(self.pipStopToken) {
        notify_cancel(self.pipStopToken.intValue);
        self.pipStopToken = nil;
    }
    if(self.pipReadyToken) {
        notify_cancel(self.pipReadyToken.intValue);
        self.pipReadyToken = nil;
    }
}

/// The guest has a video and has said how big it is, long before anything floats.
/// Re-arms, so the controller standing ready is the video-shaped one.
- (void)handleGuestVideoReady:(CGSize)size {
    // Zeroes withdraw it again: the app's own Picture in Picture switch has been
    // turned off, or the player the measurement came from has finished. Several
    // tweaked builds of YouTube put PiP behind a setting, and a window still armed
    // after it is switched off floats a video the user asked not to have.
    if(size.width < 1 || size.height < 1) {
        if(!self.guestHasVideo) return;
        NSLog(@"[LC] %@ has no video to float any more", self.bundleId);
        self.guestHasVideo = NO;
        self.guestVideoSize = CGSizeZero;
        self.guestVideoRect = CGRectZero;
        [PiPManager.shared disarmIfInactiveForVC:self];
        return;
    }
    if(self.guestHasVideo && CGSizeEqualToSize(self.guestVideoSize, size)) return;
    NSLog(@"[LC] %@ has a video, %dx%d", self.bundleId, (int)size.width, (int)size.height);
    self.guestHasVideo = YES;
    self.guestVideoSize = size;
    self.guestVideoRect = CGRectMake(0, 0, size.width, size.height);
    [PiPManager.shared rearmForVC:self];
}

- (void)notifyGuestPiPStarted {
    NSString *name = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@.started", self.dataUUID];
    notify_post(name.UTF8String);
}

- (void)requestGuestFloat {
    if(!self.guestHasVideo) return;
    NSString *name = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@.float", self.dataUUID];
    notify_post(name.UTF8String);
}

- (void)notifyGuestPiPEnded {
    // The guest has its video layer out of its own tree for as long as the window
    // is floating, so it has to be told the moment that is over — including when
    // PiP was ended by the PiP window's own buttons, which the app never sees.
    NSString *name = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@.ended", self.dataUUID];
    notify_post(name.UTF8String);
}

- (void)handleGuestPiPStartWithPayload:(uint64_t)payload {
    if((uint32_t)payload == 0) {
        // The guest asked to float but could not find its video, so the whole
        // window is floated instead — the old behaviour, and better than a PiP
        // button that does nothing. Its claim to have a video is dropped too:
        // whatever it reported the shape of, it cannot publish it.
        NSLog(@"[LC] %@ asked to float but has no video to publish; floating the window", self.bundleId);
        self.guestHasVideo = NO;
        self.guestVideoContextId = 0;
        if(PiPManager.hasShared && [PiPManager.shared isPiPWithVC:self]) return;
        [PiPManager.shared disarmIfInactiveForVC:self];
        [PiPManager.shared startPiPWithVC:self];
        return;
    }

    // Packed by LCGuestPiP: the context id in the low 32 bits, then the video's
    // width and height in the two 16-bit fields above it.
    self.guestVideoContextId = (uint32_t)payload;
    self.guestVideoSize = CGSizeMake((payload >> 32) & 0xFFFF, (payload >> 48) & 0xFFFF);

    // Set by the guest before it posted the request, so it is already there. A
    // field to a quarter of the state: x, y, width, height.
    uint64_t rect = 0;
    int rectToken = 0;
    NSString *rectName = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@.videorect", self.dataUUID];
    if(notify_register_check(rectName.UTF8String, &rectToken) == NOTIFY_STATUS_OK) {
        notify_get_state(rectToken, &rect);
        notify_cancel(rectToken);
    }
    CGRect videoRect = CGRectMake(rect & 0xFFFF, (rect >> 16) & 0xFFFF,
                                  (rect >> 32) & 0xFFFF, (rect >> 48) & 0xFFFF);
    // Nothing usable reported: show the context whole rather than nothing at all.
    if(videoRect.size.width < 1 || videoRect.size.height < 1) {
        videoRect = CGRectMake(0, 0, self.guestVideoSize.width, self.guestVideoSize.height);
    }
    self.guestVideoRect = videoRect;
    NSLog(@"[LC] %@ asked to float, video context %u (%dx%d), picture at %d,%d %dx%d",
          self.bundleId, self.guestVideoContextId,
          (int)self.guestVideoSize.width, (int)self.guestVideoSize.height,
          (int)videoRect.origin.x, (int)videoRect.origin.y,
          (int)videoRect.size.width, (int)videoRect.size.height);
    // Already floating: the app asked twice, or asked for something it is
    // already getting. Starting again would take the window down and put it
    // back up for no visible reason.
    if(PiPManager.hasShared && [PiPManager.shared isPiPWithVC:self]) return;
    [PiPManager.shared startPiPWithVC:self];
}

- (void)handleGuestPiPStop {
    // Asked through hasShared first, as everywhere else: no manager, no PiP to
    // leave. A guest asking to stop one it was never in is an ordinary case —
    // the hook posts whatever the app asks for.
    if(PiPManager.hasShared && [PiPManager.shared isPiPWithVC:self]) {
        [PiPManager.shared stopPiP];
    }
}

// Created on first use rather than at init: a window that is never touched
// never registers a notification token, and most never are.
- (LCGuestVolume *)audio {
    if(!_audio) {
        _audio = [[LCGuestVolume alloc] initWithDataUUID:self.dataUUID];
    }
    return _audio;
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(self.usesHostingControllerAPI) {
        /// Issue with new API: FBSSceneObserver takes priority over to send UIApplicationWillResignActiveNotification regressed #942,
        /// so here we make it foreground (UIApplicationDidBecomeActiveNotification) again.
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.foreground = YES;
            settings.deactivationReasons = 0;
        }];
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [center addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApp];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.sceneID) {
            [self.view.window.windowScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

- (BOOL)usesHostingControllerAPI {
    return _hostingController != nil;
}

@end
 
