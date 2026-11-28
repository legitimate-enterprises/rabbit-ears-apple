import Foundation
import RabbitEarsAPI

extension DownloadStore {
    /// What the profile can play from this device: each title on it, and each
    /// season, show, album, artist and channel that holds one. A title kept
    /// before its holders were recorded counts alone until the next sync.
    public func playable(profile: UID) -> Set<UID> {
        var ids = Set<UID>()
        for id in Set(requests(for: profile).flatMap(\.titles)) {
            guard let title = ledger.titles[id], title.state == .onDevice else { continue }
            ids.insert(id)
            ids.formUnion(title.above ?? [])
        }
        return ids
    }

    public func isPlayable(_ id: UID, profile: UID) -> Bool { playable(profile: profile).contains(id) }

    /// Since a call found no server, until one reaches it.
    public var offline: Bool { offlineFilter.offline }

    /// The library grids' Downloaded filter, one for every grid. Going
    /// offline switches it on and the server's return off again, unless it
    /// was switched by hand in between.
    public var downloadedOnly: Bool {
        get { offlineFilter.on }
        set { offlineFilter = OfflineFilter(offline: offline, on: newValue, automatic: false) }
    }

    /// Writes only a change, as every call that reaches the server says so.
    func setOffline(_ offline: Bool) {
        guard offline != self.offline else { return }
        offlineFilter.offline = offline
        if offline, !offlineFilter.on {
            (offlineFilter.on, offlineFilter.automatic) = (true, true)
        } else if !offline, offlineFilter.automatic {
            (offlineFilter.on, offlineFilter.automatic) = (false, false)
        }
    }

    /// Whether `action` is certain to fail now: any of them offline, but
    /// Play only of an `id` nothing of which plays from this device.
    public func blocks(_ action: ServerAction, _ id: UID? = nil, profile: UID?) -> Bool {
        guard offline else { return false }
        guard action == .play else { return true }
        guard let id, let profile else { return false }
        return !isPlayable(id, profile: profile)
    }
}

struct OfflineFilter {
    var offline = false
    var on = false
    /// Switched on by going offline, so the server's return switches it off.
    var automatic = false
}

/// What cannot work without the server, which the apps disable while offline.
/// What the action queue replays later is not here.
public enum ServerAction: CaseIterable, Sendable {
    /// Play, Resume and Start over.
    case play
    case download
    /// The smart-list rule editor: a new list's Smart toggle, Edit rules and Use rules.
    case smartRules
    case friends
}

extension AppModel {
    /// Whether `action` is certain to fail now for the active profile.
    public func needsServer(_ action: ServerAction, _ id: UID? = nil) -> Bool {
        downloads?.blocks(action, id, profile: activeProfile?.id) == true
    }

    /// What the Downloaded filter keeps while it is on; nil while it is off, as where nothing downloads.
    public var downloadedFilter: Set<UID>? {
        guard let downloads, downloads.downloadedOnly, let profile = activeProfile?.id else { return nil }
        return downloads.playable(profile: profile)
    }
}
