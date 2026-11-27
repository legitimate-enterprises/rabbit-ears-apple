import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// One per process. The phone's window and the CarPlay scene share the
/// sign-in, the Now Playing center and the active profile's services, so
/// both drive the same music player. CarPlay can launch the app with no
/// window, so neither scene owns these.
@MainActor
final class AppContext {
    static let shared = AppContext()

    let model: AppModel
    /// The system's Now Playing and remote commands are process-wide, so the app makes one for every profile's player.
    let center: SystemNowPlayingCenter
    /// One for the process: a new one knows no network path until its monitor first reports.
    let capabilities: SystemCapabilities
    /// Downloads go on in a background session, so they finish with the app suspended.
    let downloader = URLSessionDownloader(background: "enterprises.legitimate.rabbit-ears.downloads")
    private(set) var services: Services?
    /// AppModel makes a new ArtworkStore for every sign-in, so services made for an older one are never reused.
    private var servicesSignIn: ObjectIdentifier?
    private var launch: Task<Void, Never>?

    private init() {
        // Artwork revalidates by ETag from here across launches; the default is too small to hold a library.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        // No audio session here: opening the app must not interrupt other audio. Music and video start theirs at play.
        let capabilities = SystemCapabilities()
        self.capabilities = capabilities
        let downloads = DownloadStore(downloader: downloader, facts: { capabilities.facts() })
        let model = AppModel(
            store: KeychainCredentialStore(), deviceName: UIDevice.current.name, platform: .ios, downloads: downloads,
            replicaDirectory: Replica.defaultDirectory)
        self.model = model
        center = SystemNowPlayingCenter(artwork: { await model.artwork?.data($0, .poster) })
    }

    /// Resumes the stored session once per launch, for whichever scene connects first.
    func start() async {
        if launch == nil { launch = Task { await model.restore() } }
        await launch?.value
    }

    /// The profile's services, made once and shared; another profile's music stops.
    func services(for profileId: Int64) async -> Services? {
        guard let client = model.client, let sync = model.sync, let endpoint = model.endpoint,
            let artwork = model.artwork
        else { return nil }
        let signIn = ObjectIdentifier(artwork)
        if let services, services.profileId == profileId, servicesSignIn == signIn { return services }
        let previous = services
        let made = Services(
            client: client, sync: sync, endpoint: endpoint, profileId: profileId,
            adult: model.activeProfile?.kind != .kid, center: center, capabilities: capabilities)
        services = made
        servicesSignIn = signIn
        await previous?.stop()
        return made
    }
}

/// What the signed-in profile reads and plays beyond Movies and TV: one per
/// profile, built when browsing starts. The music player is the app's only
/// one, so the mini player, Now playing and the lock screen share it.
@MainActor
@Observable
final class Services {
    let music: MusicModel
    let youtube: YouTubeModel
    let playlists: PlaylistsModel
    /// Kids see collections too, and only the playlists shared with them.
    let collections: CollectionsModel
    let stations: StationsModel
    let player: MusicPlayer
    let profileId: Int64

    init(
        client: Client, sync: SyncSession, endpoint: ServerEndpoint, profileId: Int64, adult: Bool,
        center: any NowPlayingCenter, capabilities: SystemCapabilities
    ) {
        self.profileId = profileId
        music = MusicModel(client: client, replica: sync.replica, profileId: profileId)
        youtube = YouTubeModel(client: client, replica: sync.replica, queue: sync.queue, profileId: profileId)
        playlists = PlaylistsModel(
            client: client, replica: sync.replica, queue: sync.queue, engine: sync.engine, profileId: profileId,
            adult: adult)
        collections = CollectionsModel(
            client: client, replica: sync.replica, queue: sync.queue, engine: sync.engine, profileId: profileId)
        stations = StationsModel(
            client: client, replica: sync.replica, queue: sync.queue, engine: sync.engine, profileId: profileId)
        player = MusicPlayer(
            client: client, endpoint: endpoint, profileId: profileId, output: AVAudioOutput(),
            capabilities: capabilities)
        player.attach(center)
    }

    /// Ends playback and the queue; a profile switch or sign-out must not leave the last profile's music playing.
    func stop() async { await player.stop() }
}
