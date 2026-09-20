//
//  LCInstallBackgroundTask.swift
//  LiveContainerSwiftUI
//
//  Keeps queued downloads and installs running once the user leaves the app.
//

import BackgroundTasks
import Combine
import SwiftUI

/// Asks the system to keep an install running while the app is in the background.
///
/// Call this when the user starts an install, from the foreground; everything after
/// that is automatic. On anything older than iOS 26 — and on Mac Catalyst and the
/// simulator, where the API doesn't exist — this does nothing and the queue behaves
/// exactly as it always has.
enum LCInstallBackgroundTask {
    @MainActor
    static func begin(for item: InstallItem) {
        #if targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        record("Unsupported", detail: "No continued-processing scheduler on this platform")
        #else
        if #available(iOS 26.0, *) {
            LCInstallBackgroundTaskManager.shared.begin(for: item)
        } else {
            record("Unsupported", detail: "Needs iOS 26 or later")
        }
        #endif
    }

    /// Records the last outcome for the Settings row. Logging alone isn't enough:
    /// this only ever fails on someone else's phone, with no Mac attached to read
    /// the console from — the same reason `LCHostIdentity` reports this way.
    static func record(_ status: String, detail: String = "") {
        let defaults = LCUtils.appGroupUserDefault
        defaults.set(status, forKey: "LCBackgroundInstallStatus")
        defaults.set(detail, forKey: "LCBackgroundInstallDetail")
        defaults.set(Date(), forKey: "LCBackgroundInstallDate")
        NSLog("[LC] background install task: \(status)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

#if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)

/// Bridges `LCInstallQueue` to the system's continued-processing scheduler.
///
/// `BGContinuedProcessingTask` is built for this exact shape of work: the user taps
/// Install in the foreground, the job takes minutes, and the system shows its own
/// Live Activity — the app's name, the current phase, a progress bar and a Cancel
/// button — for as long as the app is away. Without it the queue only has
/// `isIdleTimerDisabled`, which holds off auto-lock but can't keep anything running
/// once the app is actually suspended.
///
/// The system task *adopts* work the queue is already doing rather than containing
/// it: a submission can be refused, or sit queued for a while, so the download has
/// to run either way. The launch handler binds the task to an existing
/// `InstallItem`, mirrors its progress and reports the outcome; nothing in the
/// queue's own flow moves inside it.
@available(iOS 26.0, *)
@MainActor
private final class LCInstallBackgroundTaskManager {
    static let shared = LCInstallBackgroundTaskManager()

    /// Resolution of the progress bar the system draws. The queue reports a
    /// fraction, so pick something finer than a percent.
    private static let progressUnits: Int64 = 1000

    private struct Entry {
        let identifier: String
        weak var item: InstallItem?
        var task: BGContinuedProcessingTask?
        /// Last subtitle pushed, so `updateTitle` only fires on a real change.
        var subtitle: String?
    }

    /// Live tasks keyed by `InstallItem.id`, plus the reverse lookup the launch
    /// handler needs — it's handed back only the identifier it registered with.
    private var entries: [UUID: Entry] = [:]
    private var itemIDs: [String: UUID] = [:]
    private var queueObserver: AnyCancellable?

    private static var permittedIdentifiers: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    /// The prefix every submitted identifier is composed from, applying the two
    /// rules the scheduler itself applies to `BGTaskSchedulerPermittedIdentifiers`:
    /// an entry has to end in `.*`, and the *running* bundle identifier has to be a
    /// prefix of it. The second is the one that bites. The entry is substituted at
    /// build time from `PRODUCT_BUNDLE_IDENTIFIER`, but the app ships re-signed
    /// under the distribution identity, and an entry that doesn't prefix-match the
    /// identifier the app is actually running as is dropped — leaving no base to
    /// compose against, and every registration refused with no other symptom. The
    /// Info.plist therefore lists one entry per identity the app ships under, and
    /// this picks whichever one fits the running build. The scheduler turns `a.b.*`
    /// into the base `a.b.` and prefix-matches; mirror that exactly.
    private static func identifierPrefix(for bundleID: String) -> String? {
        guard let wildcard = permittedIdentifiers.first(where: {
            $0.hasSuffix(".*") && $0.hasPrefix(bundleID)
        }) else { return nil }
        return wildcard.replacingOccurrences(of: ".*", with: ".")
    }

    /// Both halves of that rule, for the diagnostics row — a refusal is unreadable
    /// without them.
    private static func inputs(for bundleID: String) -> String {
        let listed = permittedIdentifiers.isEmpty ? "—" : permittedIdentifiers.joined(separator: " ")
        return "bundle \(bundleID.isEmpty ? "—" : bundleID) · plist \(listed)"
    }

    private init() {}

    // MARK: Starting

    func begin(for item: InstallItem) {
        guard entries[item.id] == nil else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard let prefix = Self.identifierPrefix(for: bundleID) else {
            LCInstallBackgroundTask.record("No permitted identifier", detail: Self.inputs(for: bundleID))
            return
        }
        // The scheduler only takes a submission made from the foreground on behalf
        // of something the user just did. An install kicked off by a URL the app was
        // launched with doesn't qualify; skipping it is the whole handling needed.
        guard UIApplication.shared.applicationState == .active else {
            LCInstallBackgroundTask.record("Not started", detail: "App was not foreground when the install began")
            return
        }

        // An identifier can never be reused: registering the same one twice kills
        // the app, and there is no way to unregister. Hence a fresh one per install.
        let identifier = prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // Runs on a scheduler-owned queue. The registration outlives the install
            // for good, so this captures nothing heavier than the identifier.
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                LCInstallBackgroundTaskManager.shared.adopt(task, identifier: identifier)
            }
        }
        guard registered else {
            LCInstallBackgroundTask.record("Registration refused",
                                           detail: "\(identifier) · \(Self.inputs(for: bundleID))")
            return
        }

        entries[item.id] = Entry(identifier: identifier, item: item, task: nil, subtitle: nil)
        itemIDs[identifier] = item.id

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: Self.title(for: item),
            subtitle: Self.subtitle(for: item)
        )
        // .queue rather than .fail: the install runs either way, so a task that only
        // gets going once the system has room for it is still worth having.
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            LCInstallBackgroundTask.record("Submitted", detail: identifier)
            startObservingQueue()
        } catch {
            let nsError = error as NSError
            // The code is the whole diagnosis: 1 unavailable, 2 too many pending,
            // 3 not permitted, 4 no room to start right now.
            LCInstallBackgroundTask.record("Submit failed",
                                           detail: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            forget(itemID: item.id)
        }
    }

    /// Binds a task the system just launched to the install it was submitted for.
    private func adopt(_ task: BGContinuedProcessingTask, identifier: String) {
        guard let itemID = itemIDs[identifier], let entry = entries[itemID], let item = entry.item else {
            // The install finished, failed or was cancelled before the system got
            // round to launching the task.
            task.setTaskCompleted(success: true)
            if let itemID = itemIDs.removeValue(forKey: identifier) {
                entries.removeValue(forKey: itemID)
            }
            return
        }

        task.progress.totalUnitCount = Self.progressUnits
        task.expirationHandler = {
            Task { @MainActor in
                LCInstallBackgroundTaskManager.shared.expire(identifier: identifier)
            }
        }
        entries[itemID]?.task = task
        LCInstallBackgroundTask.record("Running", detail: Self.title(for: item))
        update(item)
    }

    // MARK: Tracking the queue

    private func startObservingQueue() {
        guard queueObserver == nil else { return }
        // Every queue mutation funnels through objectWillChange — progress ticks and
        // phase changes alike — so a single subscription can't miss a transition the
        // way hand-placed calls would. It fires just *before* the change lands,
        // hence reading the state one hop later.
        queueObserver = LCInstallQueue.shared.objectWillChange.sink { _ in
            DispatchQueue.main.async {
                LCInstallBackgroundTaskManager.shared.refresh()
            }
        }
    }

    private func refresh() {
        for (itemID, entry) in entries {
            guard let item = entry.item else {
                end(itemID: itemID, success: false)
                continue
            }
            switch item.phase {
            case .completed:
                end(itemID: itemID, success: true)
            case .failed, .cancelled:
                end(itemID: itemID, success: false)
            default:
                update(item)
            }
        }
        if entries.isEmpty {
            queueObserver = nil
        }
    }

    private func update(_ item: InstallItem) {
        guard let entry = entries[item.id], let task = entry.task else { return }
        // Accurate progress isn't cosmetic: the system expires tasks that look
        // stalled before it expires ones that are visibly moving.
        let fraction = item.installState.fraction
        task.progress.completedUnitCount = Int64((fraction * Double(Self.progressUnits)).rounded())

        let subtitle = Self.subtitle(for: item)
        guard subtitle != entry.subtitle else { return }
        entries[item.id]?.subtitle = subtitle
        task.updateTitle(Self.title(for: item), subtitle: subtitle)
    }

    // MARK: Finishing

    private func end(itemID: UUID, success: Bool) {
        guard let entry = entries[itemID] else { return }
        let hadTask = entry.task != nil
        forget(itemID: itemID)
        entry.task?.setTaskCompleted(success: success)
        if hadTask {
            LCInstallBackgroundTask.record(success ? "Finished" : "Install failed")
        }
    }

    /// The user tapped Cancel in the Live Activity, or the system reclaimed the task
    /// under load.
    private func expire(identifier: String) {
        guard let itemID = itemIDs[identifier], let entry = entries[itemID] else { return }
        forget(itemID: itemID)
        entry.task?.setTaskCompleted(success: false)

        // There's no background time left. If the app is still on screen the install
        // can simply carry on without a task; if it isn't, the install can't make
        // progress, and stopping it beats leaving it wedged at 40% until the user
        // comes back.
        guard UIApplication.shared.applicationState != .active, let item = entry.item else {
            LCInstallBackgroundTask.record("Expired", detail: "App was on screen — install left running")
            return
        }
        LCInstallBackgroundTask.record("Expired", detail: "Cancelled while backgrounded")
        LCInstallQueue.shared.cancel(item)
    }

    private func forget(itemID: UUID) {
        if let entry = entries.removeValue(forKey: itemID) {
            itemIDs.removeValue(forKey: entry.identifier)
        }
    }

    // MARK: Text shown by the system

    private static func title(for item: InstallItem) -> String {
        if let name = item.name, !name.isEmpty {
            return name
        }
        return "lc.appList.installation".loc
    }

    private static func subtitle(for item: InstallItem) -> String {
        switch item.phase {
        case .queued, .cancelled:
            return "lc.flek.install.waiting".loc
        case .downloading:
            return "lc.flek.install.downloading".loc
        case .waitingForInstall:
            return "lc.flek.install.preparing".loc
        case .installing:
            return "lc.flek.installing".loc
        case .completed:
            return "lc.flek.installed".loc
        case .failed:
            return "lc.flek.installFailedGeneric".loc
        }
    }
}

#endif
