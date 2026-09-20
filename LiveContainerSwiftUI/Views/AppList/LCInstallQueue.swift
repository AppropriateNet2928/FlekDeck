//
//  LCInstallQueue.swift
//  LiveContainerSwiftUI
//
//  Manages a queue of app downloads and installations.
//  Downloads run concurrently (up to 3 at a time); installations
//  run serially since extraction and signing touch shared filesystem state.
//

import Combine
import SwiftUI

// MARK: - InstallPhase

enum InstallPhase: Equatable {
    case queued
    case downloading
    case waitingForInstall
    case installing
    case completed
    case failed(String)
    case cancelled
}

// MARK: - InstallItem

@MainActor
final class InstallItem: Identifiable, Equatable {
    let id = UUID()
    let url: String
    let name: String?
    let iconURL: String?
    /// True when the user started this install by hand (Import IPA / Install from
    /// URL) instead of tapping an app in a catalog. Those installs have no row of
    /// their own in the installer list to show progress on, so the installer
    /// surfaces them in its own tray.
    let isManual: Bool
    /// Icon / name / bundle-ID changes chosen on the app's page, applied to the
    /// bundle as it is installed.
    let overrides: FlekInstallOverrides?

    var phase: InstallPhase = .queued
    /// Download progress 0…1
    var downloadProgress: Double = 0
    /// Install (decompress + sign) progress 0…1
    var installProgress: Double = 0

    // Internal download state
    var downloadHelper: DownloadHelper?
    var downloadedFileURL: URL?
    var progressCancellable: AnyCancellable?
    var downloadingCancellable: AnyCancellable?

    init(url: String, name: String?, iconURL: String?, isManual: Bool = false,
         overrides: FlekInstallOverrides? = nil) {
        self.url = url
        self.name = name
        self.iconURL = iconURL
        self.isManual = isManual
        self.overrides = overrides
    }

    /// Snapshot for rendering in the UI (cards, rows, cells).
    var installState: FlekInstallState {
        let fraction: Double
        let indeterminate: Bool
        let isInstalling: Bool
        var failed = false
        var errorMessage: String? = nil

        switch phase {
        case .queued:
            fraction = 0
            indeterminate = true
            isInstalling = false
        case .downloading:
            fraction = 0.8 * downloadProgress
            indeterminate = false
            isInstalling = false
        case .waitingForInstall:
            fraction = 0.8
            indeterminate = true
            isInstalling = true
        case .installing:
            if downloadProgress > 0.01 {
                // Had a download phase → install fills 80%→100%
                fraction = 0.8 + 0.2 * installProgress
            } else {
                // Local-file install → 0%→100%
                fraction = installProgress
            }
            indeterminate = installProgress == 0
            isInstalling = true
        case .completed:
            fraction = 1.0
            indeterminate = false
            isInstalling = false
        case .failed(let message):
            fraction = 0
            indeterminate = false
            isInstalling = false
            failed = true
            errorMessage = message
        case .cancelled:
            fraction = 0
            indeterminate = true
            isInstalling = false
        }

        return FlekInstallState(
            name: name,
            iconURL: iconURL,
            fraction: fraction,
            indeterminate: indeterminate,
            isInstalling: isInstalling,
            installFraction: installProgress,
            failed: failed,
            errorMessage: errorMessage
        )
    }

    nonisolated static func == (lhs: InstallItem, rhs: InstallItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - LCInstallQueue

@MainActor
final class LCInstallQueue: ObservableObject {
    static let shared = LCInstallQueue()

    @Published private(set) var items: [InstallItem] = []

    /// URLs that finished installing successfully (for checkmark animation).
    @Published var completedURLs: Set<String> = []

    private let maxConcurrentDownloads = 3
    private var isInstalling = false

    /// Set by LCAppListView. Called (serially) when an item is ready
    /// for extraction + signing. The file to install is at
    /// `item.downloadedFileURL` (remote) or `URL(string: item.url)` (local).
    var installHandler: ((InstallItem) async throws -> Void)?

    /// Items that should occupy a slot on the home screen: everything still in
    /// flight PLUS failed installs, which stay (shown as a failed icon) until the
    /// user taps them and chooses Delete. Completed/cancelled items are gone.
    var activeItems: [InstallItem] {
        items.filter { item in
            switch item.phase {
            case .completed, .cancelled: return false
            default: return true
            }
        }
    }

    /// Hand-started installs (Import IPA / Install from URL), including ones that
    /// just finished or failed — those linger in `items` for a few seconds so the
    /// UI can show the final state before they disappear.
    var manualItems: [InstallItem] {
        items.filter { $0.isManual }
    }

    // MARK: Public API

    func enqueue(url: String, name: String?, iconURL: String?, isManual: Bool = false,
                 overrides: FlekInstallOverrides? = nil) {
        guard !items.contains(where: { $0.url == url && isActive($0) }) else { return }
        let item = InstallItem(url: url, name: name, iconURL: iconURL, isManual: isManual,
                               overrides: overrides)
        items.append(item)
        // Called from a foreground user action, which is the only point the system
        // accepts a continued-processing submission from.
        LCInstallBackgroundTask.begin(for: item)
        startNextDownloads()
        updateIdleTimer()
    }

    func cancel(_ item: InstallItem) {
        item.downloadHelper?.cancel()
        item.progressCancellable = nil
        item.downloadingCancellable = nil
        let wasInstalling = item.phase == .installing
        item.phase = .cancelled
        items.removeAll { $0.id == item.id }
        if wasInstalling { isInstalling = false }
        objectWillChange.send()
        startNextDownloads()
        processInstallQueue()
        updateIdleTimer()
    }

    func cancel(url: String) {
        guard let item = items.first(where: { $0.url == url && isActive($0) }) else { return }
        cancel(item)
    }

    /// Look up an active item by its install URL.
    func item(for url: String) -> InstallItem? {
        items.first { $0.url == url && isActive($0) }
    }

    /// Called by the install handler to report extraction/signing progress.
    func updateInstallProgress(_ item: InstallItem, fraction: Double) {
        item.installProgress = fraction
        objectWillChange.send()
    }

    /// Called by the install handler when install succeeds.
    func markCompleted(_ item: InstallItem) {
        item.phase = .completed
        completedURLs.insert(item.url)
        cleanupItem(item)
        isInstalling = false
        objectWillChange.send()
        processInstallQueue()
        startNextDownloads()
        updateIdleTimer()
    }

    /// Called by the install handler when install fails. The item is kept on the
    /// home screen as a failed icon (not auto-removed) until the user taps it and
    /// chooses Delete via `dismissFailed`, so only its resources are released here.
    func markFailed(_ item: InstallItem, error: String) {
        item.phase = .failed(error)
        item.progressCancellable = nil
        item.downloadingCancellable = nil
        if let fileURL = item.downloadedFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            item.downloadedFileURL = nil
        }
        item.overrides?.cleanUpStagedIcon()
        isInstalling = false
        objectWillChange.send()
        processInstallQueue()
        startNextDownloads()
        updateIdleTimer()
    }

    /// Remove a failed item from the queue (and thus the home screen) when the
    /// user dismisses it from the failed-install alert.
    func dismissFailed(_ item: InstallItem) {
        item.progressCancellable = nil
        item.downloadingCancellable = nil
        if let fileURL = item.downloadedFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            item.downloadedFileURL = nil
        }
        item.overrides?.cleanUpStagedIcon()
        items.removeAll { $0.id == item.id }
        objectWillChange.send()
        updateIdleTimer()
    }

    // MARK: Internal

    private func isActive(_ item: InstallItem) -> Bool {
        switch item.phase {
        case .completed, .failed, .cancelled: return false
        default: return true
        }
    }

    /// Keeps the display awake while any download or install is in flight.
    /// Called on every queue state change: the idle (auto-lock) timer stays
    /// disabled as long as at least one item is still active (queued /
    /// downloading / waiting / installing), and is re-enabled once the queue
    /// drains. Note this only suppresses the *automatic* idle lock — it can't
    /// stop a manual lock (power button) or keep work running once the app is
    /// actually suspended in the background.
    private func updateIdleTimer() {
        let shouldStayAwake = items.contains { isActive($0) }
        if UIApplication.shared.isIdleTimerDisabled != shouldStayAwake {
            UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
        }
    }

    private func cleanupItem(_ item: InstallItem) {
        item.progressCancellable = nil
        item.downloadingCancellable = nil
        if let fileURL = item.downloadedFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            item.downloadedFileURL = nil
        }
        item.overrides?.cleanUpStagedIcon()
        // Remove completed/failed items from the list after a short delay
        // so the UI has time to show the final state.
        let itemId = item.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            self?.items.removeAll { $0.id == itemId }
        }
    }

    private func startNextDownloads() {
        let activeDownloads = items.filter { $0.phase == .downloading }.count
        let slotsAvailable = maxConcurrentDownloads - activeDownloads
        guard slotsAvailable > 0 else { return }

        let queued = items.filter { $0.phase == .queued }
        for item in queued.prefix(slotsAvailable) {
            startDownload(item)
        }
    }

    private func startDownload(_ item: InstallItem) {
        guard let url = URL(string: item.url) else {
            item.phase = .failed("lc.appList.urlInvalidError".loc)
            objectWillChange.send()
            updateIdleTimer()
            return
        }

        // Local file — skip download, go straight to install queue
        if url.isFileURL {
            item.phase = .waitingForInstall
            objectWillChange.send()
            processInstallQueue()
            return
        }

        // Validate file extension
        let lc = url.lastPathComponent.lowercased()
        if !lc.hasSuffix(".ipa") && !lc.hasSuffix(".tipa") {
            // Allow — the server may redirect to a valid IPA
        }

        item.phase = .downloading
        let helper = DownloadHelper()
        item.downloadHelper = helper
        objectWillChange.send()

        // Observe download progress via Combine
        item.progressCancellable = helper.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] progress in
                guard let self, let item else { return }
                item.downloadProgress = Double(progress)
                self.objectWillChange.send()
            }

        Task { [weak self] in
            guard let self else { return }

            let fm = FileManager.default
            let dest = fm.temporaryDirectory
                .appendingPathComponent("\(item.id.uuidString)_\(url.lastPathComponent)")
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }

            do {
                try await helper.download(url: url, to: dest)
                if helper.cancelled {
                    item.phase = .cancelled
                    self.items.removeAll { $0.id == item.id }
                    self.objectWillChange.send()
                    self.startNextDownloads()
                    self.updateIdleTimer()
                    return
                }
                item.downloadedFileURL = dest
                item.phase = .waitingForInstall
                item.progressCancellable = nil
                self.objectWillChange.send()
                self.processInstallQueue()
            } catch {
                item.phase = .failed(error.localizedDescription)
                item.progressCancellable = nil
                self.objectWillChange.send()
            }

            self.startNextDownloads()
            self.updateIdleTimer()
        }
    }

    private func processInstallQueue() {
        guard !isInstalling else { return }
        guard let nextItem = items.first(where: { $0.phase == .waitingForInstall }) else { return }

        isInstalling = true
        nextItem.phase = .installing
        nextItem.installProgress = 0
        objectWillChange.send()

        Task { [weak self] in
            guard let self else { return }

            do {
                try await self.installHandler?(nextItem)
                self.markCompleted(nextItem)
            } catch {
                self.markFailed(nextItem, error: error.localizedDescription)
            }
        }
    }
}
