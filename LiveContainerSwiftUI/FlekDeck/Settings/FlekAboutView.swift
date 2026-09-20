//
//  FlekAboutView.swift
//  LiveContainerSwiftUI
//
//  The "About & License" page, last in the Settings category list. It names who
//  builds FlekDeck and what it is built on, and carries the notices the AGPL
//  asks a distributed build to put in front of the people running it: the
//  license it is under, the freedom to modify and pass it on, and the absence
//  of any warranty.
//

import SwiftUI

struct FlekAboutView: View {
    private static let licenseURL = "https://github.com/flekstore/FlekDeck/?tab=AGPL-3.0-1-ov-file"

    /// The shipped version, as Xcode wrote it into the bundle. FlekDeck's own,
    /// which no longer follows the LiveContainer release it is built on.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// The LiveContainer release this build was merged up to. Named here because
    /// the page already says FlekDeck is built on LiveContainer; this says which
    /// one. A build whose plist predates the key drops the row.
    private var upstreamVersion: String? {
        LCUtils.getUpstreamVersion()
    }

    /// Configuration, branch and commit, added to the built Info.plist by the
    /// run script phase. Worth showing here for bug reports.
    private var build: String? {
        Bundle.main.infoDictionary?["LCVersionInfo"] as? String
    }

    /// Kept in the Info.plist beside the version so the two are bumped together.
    /// A build whose plist has no date — or one that cannot be read as a date —
    /// drops the row rather than showing a made up one.
    private var releaseDate: Date? {
        guard let raw = Bundle.main.infoDictionary?["LCReleaseDate"] as? String else { return nil }
        let parser = DateFormatter()
        // A fixed locale and zone: this is a written constant, not something the
        // device's calendar settings should reinterpret.
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: raw)
    }

    private var formattedReleaseDate: String? {
        guard let date = releaseDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var body: some View {
        Form {
            Section {
                header
            }
            .listRowBackground(Color.clear)

            // MARK: - Version
            Section {
                infoRow("lc.flek.about.version".loc, version)
                if let released = formattedReleaseDate {
                    infoRow("lc.flek.about.released".loc, released)
                }
                if let upstreamVersion {
                    infoRow("lc.flek.about.liveContainer".loc, upstreamVersion)
                }
                if let build {
                    infoRow("lc.flek.about.build".loc, build)
                }
            }

            // MARK: - About
            Section {
                paragraph("lc.flek.about.body".loc)
            } header: {
                Text("lc.flek.about.section.about".loc)
            }

            // MARK: - License
            Section {
                paragraph("lc.flek.about.license".loc)
                linkRow("lc.flek.about.fullLicense".loc, "AGPL-3.0", url: Self.licenseURL)
            } header: {
                Text("lc.flek.about.section.license".loc)
            }

            // MARK: - Modifying and sharing
            Section {
                paragraph("lc.flek.about.rights".loc)
            } header: {
                Text("lc.flek.about.section.rights".loc)
            }

            // MARK: - No warranty
            Section {
                paragraph("lc.flek.about.warranty".loc)
            } header: {
                Text("lc.flek.about.section.warranty".loc)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("lc.flek.cat.about".loc).font(.headline) } }
    }

    // MARK: - Pieces

    @ViewBuilder private var header: some View {
        VStack(spacing: 8) {
            if let icon = Self.appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            Text("FlekDeck")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                // The build string carries a branch and a commit, so it is long
                // enough to need a second line before it starts shrinking.
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }

    /// Body text inside a section rather than in its footer: these are notices
    /// people are meant to read, not hints under a control.
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }

    /// Opens a URL rather than pushing a view, so there is no NavigationLink to
    /// draw the disclosure indicator — it is added by hand to match the rows on
    /// the Settings page. `.plain` keeps the title in the label colour.
    private func linkRow(_ title: String, _ detail: String, url: String) -> some View {
        Button {
            if let url = URL(string: url) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Text(detail)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The icon the app is installed with. The asset catalog name is not a
    /// reliable lookup key once the catalog is compiled, so the bundle's own
    /// icon file list is tried first and the catalog name only as a fallback.
    private static let appIcon: UIImage? = {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last,
           let image = UIImage(named: name) {
            return image
        }
        return UIImage(named: "AppIcon")
    }()
}
