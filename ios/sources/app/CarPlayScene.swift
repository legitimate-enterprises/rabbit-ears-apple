import CarPlay
import Network
import RabbitEarsKit

/// The CarPlay scene. It shares the phone's sign-in, active profile and
/// music player through AppContext, and may run with no phone window.
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var car: CarPlayController?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController
    ) {
        car = CarPlayController(interface: interfaceController, context: .shared)
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        car?.disconnect()
        car = nil
    }
}

/// Keeps the car's templates in step with the sign-in, the network and the
/// music player. The templates' content comes from CarPlayLibrary.
@MainActor
final class CarPlayController: NSObject {
    let interface: CPInterfaceController
    let context: AppContext
    private(set) var library: CarPlayLibrary?
    private(set) var player: MusicPlayer?
    let templates = CarPlayTemplates()

    private var session: CPSessionConfiguration?
    private let monitor = NWPathMonitor()
    private var online = true
    /// False after a music read found the server gone, until a retry.
    private var reachable = true
    private var gate: CarPlayGate?
    private var buttonsTuned: Bool?
    private var tabs: [CPListTemplate] = []
    private var shown = CarPlayTabs<ObjectIdentifier>([])
    private weak var upNext: CPListTemplate?
    private var retry: Task<Void, Never>?
    private var alertShown = false
    private var connected = true
    /// Rises with every observe(), so only the newest observation re-arms.
    private var observation = 0

    init(interface: CPInterfaceController, context: AppContext) {
        self.interface = interface
        self.context = context
        super.init()
        templates.car = self
        interface.delegate = self
        session = CPSessionConfiguration(delegate: self)
        setUpNowPlaying()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.online = satisfied
                self?.update()
            }
        }
        monitor.start(queue: .main)
        observe()
        update()
        Task { await context.start() }
    }

    func disconnect() {
        connected = false
        monitor.cancel()
        retry?.cancel()
        CPNowPlayingTemplate.shared.remove(self)
    }

    /// Re-runs `update` whenever the sign-in, the profile or the player changes.
    private func observe() {
        observation += 1
        let mine = observation
        withObservationTracking {
            _ = context.model.phase
            _ = context.model.serverActiveProfile
            _ = downloadedMusic
            _ = player?.current
            _ = player?.queue
            _ = player?.alert
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.connected, mine == self.observation else { return }
                self.update()
                self.observe()
            }
        }
    }

    private func update() {
        let model = context.model
        let next = CarPlayGate(
            phase: model.phase, profile: model.serverActiveProfile, online: online, reachable: reachable,
            downloadedMusic: downloadedMusic)
        if next != gate {
            gate = next
            Task { await show(next) }
        }
        templates.markPlaying(player?.current)
        showNowPlayingButtons()
        if let upNext, let player {
            templates.fill(upNext, CarPlayLibrary.upNext(player.queue, maxItems: limits.maxItems))
        }
        syncAlert()
    }

    private var downloadedMusic: Bool {
        context.model.serverActiveProfile.map { context.model.downloads?.hasMusic(for: $0.id) ?? false } ?? false
    }

    var limits: CarPlayLimits {
        CarPlayLimits(
            maxItems: Int(CPListTemplate.maximumItemCount), maxSections: Int(CPListTemplate.maximumSectionCount),
            limited: session?.limitedUserInterfaces.contains(.lists) ?? false)
    }

    private func show(_ gate: CarPlayGate) async {
        retry?.cancel()
        guard case .music(let profileId) = gate else {
            library = nil
            player = nil
            setRoot(templates.message(gate.message, title: context.model.serverName))
            if gate == .unreachable || gate == .offline { retryUntilBack() }
            return
        }
        guard let services = await context.services(for: profileId), self.gate == gate else { return }
        library = CarPlayLibrary(music: services.music)
        player = services.player
        observe()
        let tabBar = templates.tabBar()
        tabBar.delegate = self
        tabs = tabBar.templates.compactMap { $0 as? CPListTemplate }
        shown = CarPlayTabs(tabs.map(ObjectIdentifier.init))
        setRoot(tabBar)
        for tab in tabs { Task { await load(tab) } }
    }

    private func setRoot(_ root: CPTemplate) {
        interface.setRootTemplate(root, animated: false, completion: nil)
    }

    /// The server and the network come back on their own; this notices,
    /// and leaves the message showing until the server itself answers.
    private func retryUntilBack() {
        retry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                guard self.online, await self.context.model.serverAnswers(), !Task.isCancelled else { continue }
                if self.context.model.phase == .unreachable {
                    // Detached: restoring flips the phase, and `show` cancels this task.
                    await Task { await self.context.model.restore() }.value
                } else {
                    self.reachable = true
                    self.update()
                }
            }
        }
    }

    func load(_ template: CPListTemplate) async {
        guard let library, let build = templates.source(of: template) else { return }
        do {
            let list =
                switch build {
                case .recent: try await library.recent(limits)
                case .albums: try await library.albums(limits)
                case .artists: try await library.artists(limits)
                case .playlists: try await library.playlists(limits)
                case .destination(.album(let id)): try await library.album(id, limits)
                case .destination(.artist(let id)): try await library.artist(id, limits)
                case .destination(.playlist(let id)): try await library.playlist(id, limits)
                case .destination(.letter(let group, let letter)): try await library.letter(group, letter, limits)
                }
            templates.fill(template, list)
            templates.markPlaying(player?.current)
            shown.answered(ObjectIdentifier(template), rows: !list.sections.isEmpty)
        } catch {
            failed(error, in: template)
        }
    }

    private func failed(_ error: any Error, in template: CPListTemplate) {
        guard (error as? AppError) == .unreachable else {
            return templates.fill(
                template, CarPlayList(sections: [], empty: CarPlayMessage(error.localizedDescription)))
        }
        templates.fill(template, CarPlayList(sections: [], empty: CarPlayGate.unreachable.message))
        shown.unreachable(ObjectIdentifier(template))
        guard shown.nothingAnywhere else { return }
        reachable = false
        update()
    }

    func perform(_ action: CarPlayAction, in list: CarPlayList, title: String) async {
        guard let player else { return }
        switch action {
        case .open(let destination):
            let template = templates.pushed(destination, title: title)
            interface.pushTemplate(template, animated: true, completion: nil)
            await load(template)
        case .play(let playable):
            await play(playable, shuffled: false)
        case .playTrack(let index):
            guard let queue = list.queue else { return }
            await player.play(queue.songs, from: index, source: queue.source, playlistId: queue.playlistId)
            showNowPlaying()
        case .jump(let id):
            await player.jump(to: id)
            interface.pop(to: CPNowPlayingTemplate.shared, animated: true, completion: nil)
        case .tune(let station):
            guard let client = context.model.client else { return }
            await player.tune(StationTuner(client: client, station: station))
            showNowPlaying()
        }
    }

    func play(_ playable: CarPlayPlayable, shuffled: Bool) async {
        guard let library, let player else { return }
        do {
            let queue = try await library.queue(for: playable)
            await player.play(
                queue.songs, source: queue.source, playlistId: queue.playlistId, shuffled: shuffled)
            showNowPlaying()
        } catch {
            if (error as? AppError) == .unreachable {
                reachable = false
                update()
            }
        }
    }

    /// Opens Now Playing once the chosen song plays; one that cannot leaves its alert instead.
    private func showNowPlaying() {
        guard let player, player.stream != nil, player.alert == nil,
            interface.topTemplate !== CPNowPlayingTemplate.shared
        else { return }
        interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    /// The player's alert, one at a time with OK; clearing it anywhere dismisses it here.
    private func syncAlert() {
        if let message = player?.alert, !alertShown {
            alertShown = true
            let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                self?.player?.alert = nil
            }
            interface.presentTemplate(
                CPAlertTemplate(titleVariants: [message], actions: [ok]), animated: true, completion: nil)
        } else if player?.alert == nil, alertShown {
            alertShown = false
            interface.dismissTemplate(animated: true, completion: nil)
        }
    }

    private func setUpNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.upNextTitle = "Up next"
        nowPlaying.isAlbumArtistButtonEnabled = false
        showNowPlayingButtons()
        nowPlaying.add(self)
    }

    /// Replaces the buttons only when a station starts or stops, so a redraw does not flicker them on every update.
    private func showNowPlayingButtons() {
        let tuned = player?.station != nil
        guard tuned != buttonsTuned else { return }
        buttonsTuned = tuned
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(
            CarPlayLibrary.nowPlayingButtons(station: tuned).map { button -> CPNowPlayingButton in
                switch button {
                case .shuffle:
                    CPNowPlayingShuffleButton { [weak self] _ in
                        guard let player = self?.player else { return }
                        player.setShuffle(!player.queue.shuffled)
                    }
                case .repeatMode:
                    CPNowPlayingRepeatButton { [weak self] _ in
                        guard let player = self?.player else { return }
                        player.setRepeat(player.queue.repeatMode.cycled)
                    }
                }
            })
    }
}

extension CarPlayController: CPInterfaceControllerDelegate {
    func templateWillAppear(_ template: CPTemplate, animated: Bool) {
        guard template === CPNowPlayingTemplate.shared else { return }
        let stack = interface.templates
        let depth = stack.count + (stack.last === template ? 0 : 1)
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled =
            CarPlayLibrary.upNextEnabled(depth: depth) && player?.station == nil
            && !(player?.queue.upNext.isEmpty ?? true)
    }
}

extension CarPlayController: @MainActor CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let player else { return }
        let list = CarPlayLibrary.upNext(player.queue, maxItems: limits.maxItems)
        let template = CPListTemplate(title: list.title, sections: [])
        templates.fill(template, list)
        upNext = template
        interface.pushTemplate(template, animated: true, completion: nil)
    }
}

extension CarPlayController: CPSessionConfigurationDelegate {
    /// Albums and Artists change between the full index and the recent twelve.
    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        for tab in tabs where [.albums, .artists].contains(templates.source(of: tab)) {
            Task { await load(tab) }
        }
    }
}

extension CarPlayController: CPTabBarTemplateDelegate {
    /// Recently played changes with every song, so a tab reads again when chosen.
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        guard let list = selectedTemplate as? CPListTemplate else { return }
        Task { await load(list) }
    }
}
