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
}

extension AppModel {
    /// What the Downloaded filter keeps while it is on; nil while it is off, as where nothing downloads.
    public var downloadedFilter: Set<UID>? {
        guard let downloads, downloads.downloadedOnly, let profile = activeProfile?.id else { return nil }
        return downloads.playable(profile: profile)
    }
}
