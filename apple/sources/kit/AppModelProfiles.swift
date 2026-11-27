import Foundation
import RabbitEarsAPI

extension AppModel {
    /// The signed-in adult's Remember profile and Skip PIN on this device,
    /// with the profile last picked here; signed out, the defaults and no
    /// writes.
    public var profileMemory: ProfileMemory {
        get {
            access(keyPath: \.profileMemory)
            let blank = ProfileMemory(remember: rememberProfileByDefault, skipPin: rememberProfileByDefault)
            return memoryKey.flatMap { store.profileMemories[$0] } ?? blank
        }
        set {
            guard let memoryKey else { return }
            withMutation(keyPath: \.profileMemory) { store.profileMemories[memoryKey] = newValue }
        }
    }

    /// Account ids are per server, so the key carries both.
    private var memoryKey: String? {
        guard let endpoint, let me else { return nil }
        return "\(endpoint.baseURL.absoluteString) \(me.account.id)"
    }

    /// The household members to choose from; invited adults appear once they join.
    public var profiles: [Account] { (me?.profiles ?? []).filter { !$0.pending && $0.revokedAt == nil } }
    /// Held at Who's watching by the server until a profile is unlocked.
    public var locked: Bool { me?.locked == true }
    /// Whether the profile active on this device owns the household, so may add adults.
    public var isOwner: Bool { me.map { $0.household?.adultId == $0.activeProfileId } ?? false }
    /// The profile the server answers as on this device, which may differ
    /// from `activeProfile` while Who's watching is showing.
    public var serverActiveProfile: Account? {
        guard let me else { return nil }
        return me.account.id == me.activeProfileId ? me.account : me.profiles.first { $0.id == me.activeProfileId }
    }
    /// Household management needs an adult of the household active on the
    /// server, unlocked first while `locked`; one only visiting manages nothing.
    public var canManageHousehold: Bool { serverActiveProfile.map { $0.kind == .adult && $0.present != true } ?? false }
    public var householdName: String? { me?.household?.name ?? me?.account.name }

    /// The kids whose filter is a manual allow list, who each get a checkbox on a title or channel.
    public var allowListKids: [Account] { profiles.filter { $0.kind == .kid && $0.filterMode == .allowList } }

    public func loadAllowLists() async {
        guard let replica = sync?.replica else { return }
        await allowLists.load(kids: activeProfile?.kind == .adult ? allowListKids : [], replica: replica)
    }

    func invite(_ invite: Components.Schemas.HouseholdInvite) -> Invite {
        let code = invite.joinCode
        return Invite(code: code.code, url: endpoint?.resolve(code.link) ?? URL(fileURLWithPath: code.link))
    }
}
