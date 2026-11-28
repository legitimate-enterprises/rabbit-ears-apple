import Foundation
import Observation
import RabbitEarsAPI

/// The list whose rules are edited; a new one, named and of a kind already, is made when saved.
public enum SmartTarget: Sendable {
    case newPlaylist(name: String, kind: PlaylistKind)
    case playlist(Playlist)
    /// The station's own playlist, through its owner.
    case station(Station)
    case newCollection(name: String)
    case collection(MovieCollection)
}

/// The editor sheet's rules. They are online only: read and replaced
/// through REST, never queued; only a list's create, rename and the delete
/// of one whose rules were refused go through the queue.
@MainActor
@Observable
public final class SmartRulesEditor {
    public static let groupLimit = 20
    public static let conditionLimit = 50
    public static let personalNote = "Watched, plays and favorites are yours, the owner's."
    /// Under a new list's Smart toggle.
    public static let smartNote = "Fills itself from rules you set."

    public let target: SmartTarget
    public var name = ""
    public let kind: PlaylistKind
    public var match = SmartMatch.all
    public var groups: [SmartGroupDraft] = []
    public private(set) var nameError: String?
    /// Each row's refusal by its id.
    public private(set) var errors: [UUID: String] = [:]
    /// A refusal no row is named in.
    public private(set) var error: String?
    /// False until an existing list's rules are read, as while offline.
    public private(set) var ready = true
    public private(set) var busy = false
    /// The new list's id once saved.
    public private(set) var created: UID?
    private let client: Client
    private let queue: ActionQueue
    private let profileId: UID

    public init(target: SmartTarget, client: Client, queue: ActionQueue, profileId: UID) {
        self.target = target
        self.client = client
        self.queue = queue
        self.profileId = profileId
        switch target {
        case .newPlaylist(_, let kind): self.kind = kind
        case .playlist(let playlist): kind = playlist.kind
        case .station(let station): kind = station.kind
        case .newCollection, .collection: kind = .movies
        }
        switch target {
        case .newPlaylist(let name, _), .newCollection(let name): self.name = name
        case .playlist(let playlist): name = playlist.name
        case .collection(let collection): name = collection.name
        case .station: break
        }
        ready = !isSmart
        groups = [newGroup()]
    }

    public var scope: SmartScope {
        switch target {
        case .newCollection, .collection: .collection
        default: .playlist(kind)
        }
    }

    public var fields: [SmartField] { SmartField.fields(scope) }
    /// Only an existing list's name is edited here: a new one's was asked
    /// before, and a station's own playlist has no name of its own to show.
    public var namesList: Bool {
        switch target {
        case .playlist, .collection: true
        case .newPlaylist, .newCollection, .station: false
        }
    }
    public var usesPersonal: Bool { groups.contains { $0.conditions.contains { $0.field.isPersonal } } }

    private var conditionCount: Int { groups.reduce(0) { $0 + $1.conditions.count } }
    public var canAddCondition: Bool { conditionCount < Self.conditionLimit }
    public var canAddGroup: Bool { groups.count < Self.groupLimit && canAddCondition }
    /// The last row stays, as rules hold at least one.
    public var canRemove: Bool { conditionCount > 1 }

    /// With one group the sheet reads "Match [all] of these conditions", that group's match.
    public var topMatch: SmartMatch {
        get { groups.count == 1 ? groups[0].match : match }
        set { if groups.count == 1 { groups[0].match = newValue } else { match = newValue } }
    }

    public func addCondition(to group: UUID) {
        guard canAddCondition, let index = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[index].conditions.append(SmartConditionDraft(field: fields[0]))
    }

    public func addGroup() {
        guard canAddGroup else { return }
        groups.append(newGroup())
    }

    /// A group's last row takes the group with it.
    public func remove(_ condition: UUID) {
        guard canRemove, let index = groups.firstIndex(where: { $0.conditions.contains { $0.id == condition } })
        else { return }
        groups[index].conditions.removeAll { $0.id == condition }
        if groups[index].conditions.isEmpty { groups.remove(at: index) }
        errors[condition] = nil
    }

    /// The request body, values trimmed.
    public var body: SmartRules {
        SmartRules(
            match: match,
            groups: groups.map { group in
                .init(
                    match: group.match,
                    conditions: group.conditions.map { row in
                        let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return switch row.field.type {
                        case .text: .init(field: row.field, _operator: row.op, text: value)
                        case .number: .init(field: row.field, _operator: row.op, number: Int64(value))
                        case .boolean: .init(field: row.field, _operator: row.op)
                        }
                    })
            })
    }

    private var isSmart: Bool {
        switch target {
        case .playlist(let playlist): playlist.smart == true
        case .station(let station): station.smart == true
        case .collection(let collection): collection.smart == true
        case .newPlaylist, .newCollection: false
        }
    }

    /// Reads a smart list's rules; a list not yet smart starts from one row.
    public func load() async {
        guard isSmart else { return }
        do {
            let rules: SmartRules
            switch target {
            case .playlist(let playlist):
                rules = try await client.getPlaylistRules(path: .init(profileId: profileId, playlistId: playlist.id))
                    .ok.body.json
            case .station(let station):
                rules = try await client.getPlaylistRules(
                    path: .init(profileId: station.ownerId, playlistId: station.playlistId)
                ).ok.body.json
            case .collection(let collection):
                rules = try await client.getCollectionRules(path: .init(collectionId: collection.id)).ok.body.json
            case .newPlaylist, .newCollection: return
            }
            match = rules.match
            groups = rules.groups.map { group in
                SmartGroupDraft(
                    match: group.match,
                    conditions: group.conditions.map { condition in
                        var row = SmartConditionDraft(field: condition.field)
                        row.op = condition._operator
                        row.value = condition.text ?? condition.number.map(String.init) ?? ""
                        return row
                    })
            }
            if groups.isEmpty { groups = [newGroup()] }
            error = nil
            ready = true
        } catch {
            self.error = AppError.from(error, unauthorized: .signedOut).localizedDescription
        }
    }

    /// True once the server holds the rules. A new list is made first and,
    /// when its rules are refused, deleted again; the sheet stays open.
    public func save() async -> Bool {
        guard validate() else { return false }
        busy = true
        defer { busy = false }
        let name = self.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(scalars: 100)
        do {
            switch target {
            case .newPlaylist(_, let kind):
                let id = UID.new()
                try await queue.createPlaylist(as: profileId, id, name: name, kind: kind)
                try await made(
                    id, put: { try await put(playlist: id, of: profileId) },
                    delete: { try await queue.deletePlaylist(as: profileId, id) })
            case .newCollection:
                let id = UID.new()
                try await queue.createCollection(as: profileId, id, name: name)
                try await made(
                    id, put: { try await put(collection: id) },
                    delete: { try await queue.deleteCollection(as: profileId, id, entries: []) })
            case .playlist(let playlist):
                try await put(playlist: playlist.id, of: profileId)
                if name != playlist.name {
                    try await queue.renamePlaylist(as: profileId, playlist.id, name: name, kind: playlist.kind)
                }
            case .station(let station):
                try await put(playlist: station.playlistId, of: station.ownerId)
            case .collection(let collection):
                try await put(collection: collection.id)
                if name != collection.name {
                    try await queue.renameCollection(as: profileId, collection.id, name: name)
                }
            }
            error = nil
            return true
        } catch {
            refused(error)
            return false
        }
    }

    private func put(playlist: UID, of owner: UID) async throws {
        _ = try await client.replacePlaylistRules(
            path: .init(profileId: owner, playlistId: playlist), body: .json(body)
        )
        .ok
    }

    private func put(collection: UID) async throws {
        _ = try await client.replaceCollectionRules(path: .init(collectionId: collection), body: .json(body)).ok
    }

    /// Sends the queued create so the rules have a list to land on, then
    /// `put`; a list the server never took or whose rules it refused is deleted.
    private func made(_ id: UID, put: () async throws -> Void, delete: () async throws -> Void) async throws {
        do {
            guard await queue.flush() == .done else { throw AppError.unreachable }
            try await put()
            created = id
        } catch {
            try? await delete()
            _ = await queue.flush()
            throw error
        }
    }

    private func validate() -> Bool {
        nameError =
            namesList && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a name." : nil
        errors = [:]
        error = nil
        for row in groups.flatMap(\.conditions) {
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch row.field.type {
            case .text where value.isEmpty: errors[row.id] = "Enter a value."
            case .number where Int64(value) == nil: errors[row.id] = "Enter a whole number."
            default: break
            }
        }
        return nameError == nil && errors.isEmpty
    }

    /// A 400's fields name rows as groups.i.conditions.j.text, .number, .field or .operator.
    private func refused(_ failure: any Error) {
        guard let api = APIError.from(failure), !api.fieldMessages.isEmpty else {
            error = AppError.from(failure, unauthorized: .signedOut).localizedDescription
            return
        }
        var unplaced: [String] = []
        for field in api.fields {
            guard let message = api.fieldMessages[field] else { continue }
            let parts = field.split(separator: ".")
            if parts.count == 5, parts[0] == "groups", parts[2] == "conditions", let group = Int(parts[1]),
                let row = Int(parts[3]), groups.indices.contains(group), groups[group].conditions.indices.contains(row)
            {
                errors[groups[group].conditions[row].id] = message
            } else {
                unplaced.append(message)
            }
        }
        error = unplaced.isEmpty ? nil : unplaced.joined(separator: " ")
    }

    private func newGroup() -> SmartGroupDraft { SmartGroupDraft(conditions: [SmartConditionDraft(field: fields[0])]) }
}
