import Foundation
import Observation
import OpenAPIRuntime
import RabbitEarsAPI

public typealias Account = Components.Schemas.Account
public typealias Item = Components.Schemas.Item
public typealias DeviceLink = Components.Schemas.DeviceLinkCreated
public typealias DeviceLinkStatus = Components.Schemas.DeviceLinkStatus

/// The signed-in state of this device: which server, which household, which
/// profile is watching.
@MainActor
@Observable
public final class AppModel {
    /// `unreachable` keeps the stored session: only the server saying the token is dead signs this device out.
    /// `choosingHousehold` follows a sign-in of an adult in several households, before Who's watching.
    public enum Phase: Equatable, Sendable {
        case starting, unreachable, signedOut, choosingHousehold, choosingProfile, browsing
    }

    public private(set) var phase = Phase.starting
    /// The signed-in adult's households, their own first, while `choosingHousehold`.
    public private(set) var households: [Components.Schemas.HouseholdChoice] = []
    /// Kept as it changes, for the next launch to open with before the server answers.
    public private(set) var me: Components.Schemas.Me? {
        didSet {
            guard let me, let endpoint, store.token != nil else { return }
            live.cache?.keep(me: me, for: endpoint.baseURL)
        }
    }
    public private(set) var activeProfile: Account?
    public private(set) var endpoint: ServerEndpoint?
    public private(set) var client: Client?
    /// The sections of primary navigation the server has libraries for; all until a server has answered.
    public internal(set) var librarySections = Set(LibrarySection.allCases)
    private let generation = ArtworkGeneration()
    /// The lock last sent, which an unlock waits on.
    @ObservationIgnored private var locking: Task<Void, Never>?
    /// Each profile's HomeSlots as read or last kept, so a Home redraw reads no file.
    @ObservationIgnored var heldHomeSlots: [String: HomeSlots] = [:]
    public private(set) var artwork: ArtworkStore?
    /// The remembered profile whose PIN a launch asks for at Who's watching, until a profile is picked.
    public private(set) var pinPrompt: Account?
    /// What the server says has changed, for what is on screen to load
    /// again; it holds the cache the client reads through.
    public let live: LiveFeed
    /// What this device keeps for offline play; nil where nothing is downloaded, as on Apple TV.
    public let downloads: DownloadStore?
    /// Each server's name by address, as it said this launch.
    var serverNames: [URL: String] = [:]

    let store: any CredentialStore
    let deviceName: String
    let platform: Components.Schemas.Platform
    let transport: (any ClientTransport)?
    let rememberProfileByDefault: Bool

    /// `rememberProfileByDefault` is Remember profile and Skip PIN for an adult who has set neither on this device.
    public init(
        store: any CredentialStore, deviceName: String, platform: Components.Schemas.Platform = .macos,
        rememberProfileByDefault: Bool = true, transport: (any ClientTransport)? = nil,
        downloads: DownloadStore? = nil, cache: ResponseCache? = nil
    ) {
        self.downloads = downloads
        live = LiveFeed(cache: cache)
        self.store = store
        self.deviceName = deviceName
        self.platform = platform
        self.rememberProfileByDefault = rememberProfileByDefault
        self.transport = transport
    }

    /// Resumes the stored session, or asks to sign in when there is none, it
    /// was revoked, or its server is plain http outside the local network.
    /// With the last Me kept, it opens on that at once and takes the
    /// server's when it comes.
    public func restore() async {
        guard let server = store.server, let token = store.token,
            let endpoint = try? secure(ServerEndpoint(baseURL: server))
        else {
            phase = .signedOut
            return
        }
        phase = .starting
        let client = client(endpoint, token: token)
        if let kept = live.cache?.me(for: endpoint.baseURL) {
            live.cache?.profile = kept.locked == true ? nil : kept.activeProfileId
            await enter(endpoint, client, kept, launching: true)
            return await refresh(endpoint, client)
        }
        do {
            let me = try await client.getMe().ok.body.json
            await enter(endpoint, client, me, launching: true)
        } catch {
            // Only the server's own code says it no longer knows the device; a proxy's 401 does not.
            guard APIError.from(error)?.code == .unauthorized else {
                phase = .unreachable
                return
            }
            forget()
            phase = .signedOut
        }
    }

    /// The server's Me after a launch opened on the kept one. The profile
    /// shown still active takes it in place; a server answering otherwise
    /// takes the launch as it would have gone. A server that does not answer
    /// leaves the kept one, and a pick or switch made meanwhile stands.
    private func refresh(_ endpoint: ServerEndpoint, _ client: Client) async {
        let shown = (phase, activeProfile?.id)
        let fresh: Components.Schemas.Me
        do {
            fresh = try await client.getMe().ok.body.json
        } catch {
            guard APIError.from(error)?.code == .unauthorized, self.endpoint == endpoint else { return }
            forget()
            me = nil
            activeProfile = nil
            self.client = nil
            phase = .signedOut
            return
        }
        guard self.endpoint == endpoint, store.token != nil, phase == shown.0, activeProfile?.id == shown.1 else {
            return
        }
        let active = fresh.profiles.first { $0.id == shown.1 && !$0.pending && $0.revokedAt == nil }
        guard phase != .browsing || (fresh.locked != true && fresh.activeProfileId == shown.1 && active != nil) else {
            phase = .starting
            return await enter(endpoint, client, fresh, launching: true)
        }
        me = fresh
        if let active { activeProfile = active }
    }

    public func signIn(server: String, email: String, password: String) async throws {
        let endpoint = try parse(server)
        let request = Components.Schemas.SignInRequest(
            email: email.trimmingCharacters(in: .whitespaces), password: password, deviceName: deviceName,
            platform: platform)
        try await signedIn(endpoint) { try await $0.signIn(body: .json(request)).created.body.json }
    }

    /// Switches this device to a profile; the server checks the PIN.
    public func choose(_ profile: Account, pin: String? = nil) async throws {
        try await unlock(profile, pin: pin)
        if activeProfile?.id != profile.id { artwork?.profileChanged() }
        activeProfile = profile
        pinPrompt = nil
        profileMemory.lastProfileId = profile.id
        phase = .browsing
    }

    /// Makes a profile the server's active one and unlocks this device, staying on Who's watching.
    public func unlock(_ profile: Account, pin: String? = nil) async throws {
        let client = try signedInClient()
        // Who's watching shows before its lock is answered; a lock the server took after this unlock would undo it.
        await locking?.value
        do {
            _ = try await client.unlockProfile(path: .init(profileId: profile.id), body: .json(.init(pin: pin)))
                .noContent
        } catch {
            if APIError.from(error)?.code == .forbidden { throw AppError.wrongPin }
            throw AppError.from(error, unauthorized: .signedOut)
        }
        me?.activeProfileId = profile.id
        me?.locked = false
    }

    /// Holds this device at Who's watching; a server that does not answer leaves it as it was.
    public func lock() async {
        guard let client else { return }
        let sent = Task {
            guard (try? await client.lockDevice().noContent) != nil else { return }
            me?.locked = true
        }
        locking = sent
        await sent.value
    }

    /// Adds a pending adult to the household and returns what to hand them.
    public func addAdult(name: String, email: String) async throws -> Invite {
        let client = try signedInClient()
        do {
            let invite = try await client.addHouseholdAdult(body: .json(.init(name: name, email: email)))
                .created.body.json
            me = try await client.getMe().ok.body.json
            return self.invite(invite)
        } catch {
            if APIError.from(error)?.code == .conflict { throw AppError.emailTaken }
            throw AppError.from(error, unauthorized: .signedOut)
        }
    }

    /// Re-reads the household after a change made elsewhere in the app.
    public func reload() async {
        if let fresh = try? await client?.getMe().ok.body.json { me = fresh }
        if let id = activeProfile?.id, let fresh = profiles.first(where: { $0.id == id }) { activeProfile = fresh }
    }

    /// What the kids on an allow list have on it, for an adult's menus; empty for a kid, who may not change them.
    public let allowLists = AllowLists()

    /// Puts this device in one of `households`, then shows its Who's
    /// watching. The device starts in the first, the adult's own; a failed
    /// move keeps the choice showing.
    public func chooseHousehold(_ choice: Components.Schemas.HouseholdChoice) async throws {
        if choice.id != households.first?.id {
            let client = try signedInClient()
            do {
                _ = try await client.moveDevice(body: .json(.init(householdId: choice.id))).noContent
                me = try await client.getMe().ok.body.json
            } catch {
                throw AppError.from(error, unauthorized: .signedOut)
            }
        }
        households = []
        if me?.locked != true { await lock() }
        phase = .choosingProfile
    }

    /// Creates the kid, sets its PIN when asked, and refreshes the profiles.
    /// `created` takes the kid the moment it exists, for the form to edit
    /// from then on: a retry after a failed PIN saves that kid instead of
    /// adding another.
    public func addKid(_ form: AddKidForm, created: (Account) -> Void) async throws {
        let client = try signedInClient()
        var kid = form.editing
        do {
            if let kid {
                _ = try await client.replaceProfile(path: .init(profileId: kid.id), body: .json(form.input)).ok
            } else {
                let made = try await client.createProfile(body: .json(form.input)).created.body.json
                created(made)
                kid = made
            }
            if form.requirePin, let kid {
                _ = try await client.setProfilePin(path: .init(profileId: kid.id), body: .json(.init(pin: form.pin)))
                    .noContent
            }
            me = try await client.getMe().ok.body.json
        } catch {
            if kid != nil { await reload() }
            throw AppError.from(error, unauthorized: .signedOut)
        }
    }

    public func switchProfile() async {
        guard me != nil else { return }
        await lock()
        activeProfile = nil
        pinPrompt = nil
        phase = .choosingProfile
    }

    /// Signs out here at once; telling the server waits on a server that may not answer.
    public func signOut() async {
        let signedIn = client
        forget()
        me = nil
        activeProfile = nil
        client = nil
        households = []
        phase = .signedOut
        _ = try? await signedIn?.signOut().noContent
    }

    /// Signed out, the device keeps nothing of the account: no token, no
    /// downloads, no kept answer, no cached response.
    private func forget() {
        store.token = nil
        downloads?.wipe()
        live.cache?.clear()
        heldHomeSlots = [:]
        URLCache.shared.removeAllCachedResponses()
    }

    func signedInClient() throws -> Client {
        guard let client else { throw AppError.signedOut }
        return client
    }

    func signedIn(
        _ endpoint: ServerEndpoint, notFound: AppError? = nil,
        _ call: (Client) async throws -> Components.Schemas.SignInResult
    ) async throws {
        let result: Components.Schemas.SignInResult
        do {
            result = try await call(endpoint.client(token: nil, transport: transport))
        } catch {
            if let notFound, APIError.from(error)?.status == 404 { throw notFound }
            throw AppError.from(error)
        }
        try await adopt(endpoint, result, households: result.households ?? [])
    }

    /// A token the store does not keep is signed out at once: the next
    /// launch would find no token and land on sign-in unexplained. More
    /// than one of `households` asks which this device is in.
    func adopt(
        _ endpoint: ServerEndpoint, _ result: Components.Schemas.SignInResult,
        households: [Components.Schemas.HouseholdChoice] = []
    ) async throws {
        if store.server != endpoint.baseURL { store.serverName = nil }
        store.server = endpoint.baseURL
        store.token = result.token
        guard store.token == result.token else {
            _ = try? await endpoint.client(token: result.token, transport: transport).signOut().noContent
            throw AppError.server("This device couldn't keep the sign-in. Try again.")
        }
        await enter(endpoint, client(endpoint, token: result.token), result.me, households: households)
    }

    private func client(_ endpoint: ServerEndpoint, token: String) -> Client {
        let client = endpoint.client(
            token: token, transport: transport, generation: generation, offline: downloads, cache: live.cache
        ) { [weak self] in self?.lockedOut() }
        downloads?.connect(client: client, endpoint: endpoint, token: token)
        return client
    }

    /// A launch, unlike a sign-in, may continue as the remembered profile.
    private func enter(
        _ endpoint: ServerEndpoint, _ client: Client, _ me: Components.Schemas.Me, launching: Bool = false,
        households: [Components.Schemas.HouseholdChoice] = []
    ) async {
        self.endpoint = endpoint
        self.client = client
        librarySections = Self.rememberedLibrarySections(endpoint.baseURL)
        // Off the way in, as a launch offline must not wait on the server.
        Task { await learnName(endpoint) }
        artwork = ArtworkStore(client: client, generation: generation)
        self.me = me
        activeProfile = nil
        pinPrompt = nil
        // Moving takes an unlocked device, so the household is chosen before Who's watching locks it.
        if households.count > 1 {
            self.households = households
            phase = .choosingHousehold
            return
        }
        if launching, await resumeRememberedProfile() { return }
        phase = .choosingProfile
        if self.me?.locked != true { await lock() }
    }

    /// Browses as the profile last picked here when this adult remembers it.
    /// A PIN is skipped only while the server still has that profile
    /// unlocked on this device; otherwise the PIN is asked for at Who's
    /// watching. False leaves Who's watching to show.
    private func resumeRememberedProfile() async -> Bool {
        let memory = profileMemory
        guard memory.remember, let profile = profiles.first(where: { $0.id == memory.lastProfileId }) else {
            return false
        }
        if profile.hasPin && !memory.skipPin {
            pinPrompt = profile
            return false
        }
        if me?.locked != true && me?.activeProfileId == profile.id {
            activeProfile = profile
            phase = .browsing
            return true
        }
        if profile.hasPin {
            pinPrompt = profile
            return false
        }
        return (try? await choose(profile)) != nil
    }

    /// The server answered device_locked, so a profile must be picked again.
    private func lockedOut() {
        guard me != nil else { return }
        me?.locked = true
        activeProfile = nil
        pinPrompt = nil
        phase = .choosingProfile
    }
}
