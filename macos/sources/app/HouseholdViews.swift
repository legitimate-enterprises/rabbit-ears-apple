import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Actions the active adult cannot take are not shown; an adult only
/// visiting may only leave.
struct ManageHouseholdView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: HouseholdModel?
    @State private var sheet: HouseholdSheet?
    @State private var removing: Account?
    @State private var leaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manage household").font(.system(size: 20, weight: .bold))
                Text(app.householdName.map { "\($0)'s household" } ?? "").font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            if let model {
                List {
                    if !model.offers.incoming.isEmpty || !model.offers.outgoing.isEmpty {
                        Section("Offers") {
                            ForEach(model.offers.incoming, id: \.id) {
                                OfferRow(offer: $0, incoming: true, model: model, run: run)
                            }
                            ForEach(model.offers.outgoing, id: \.id) {
                                OfferRow(offer: $0, incoming: false, model: model, run: run)
                            }
                        }
                    }
                    Section("Profiles") {
                        ForEach(model.members) {
                            MemberRow(member: $0, model: model, sheet: $sheet, removing: $removing)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 300)
                if model.anyShared {
                    Text(
                        "A shared profile is the same in every household it is in: one watch history, one set of "
                            + "playlists and limits. Adults in each of its households can change a kid's settings."
                    )
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
            if let message = error ?? model?.error {
                Text(message).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B))
            }
            HStack {
                if model?.visiting == true {
                    Button("Leave this household…", role: .destructive) { leaving = true }
                        .buttonStyle(SecondaryButtonStyle(height: 34))
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle(height: 34)).keyboardShortcut(
                    .defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Theme.card)
        // A household live event, as an offer made or accepted elsewhere, loads the list again.
        .task(id: app.live.household) {
            let next = model ?? HouseholdModel(app: app)
            await next.load()
            model = next
        }
        .sheet(item: $sheet) { sheet in
            if let model { HouseholdSheetView(sheet: sheet, model: model) }
        }
        .confirmationDialog(
            removing.map(Removal.question) ?? "",
            isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { member in
            Button("Remove", role: .destructive) { run { try await model?.remove(member) } }
        } message: { member in
            Text(Removal.message(member))
        }
        .confirmationDialog("Leave this household?", isPresented: $leaving) {
            Button("Leave", role: .destructive) { run { try await model?.leave() } }
        } message: {
            Text("You stay in your own household, and nothing of yours is deleted.")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum HouseholdSheet: Identifiable {
    case edit(Account)
    case pin(Account)
    case toAdult(Account)
    case share(Account)
    case invite(String, Invite)

    var id: String {
        switch self {
        case .edit(let member): "edit/\(member.id)"
        case .pin(let member): "pin/\(member.id)"
        case .toAdult(let member): "adult/\(member.id)"
        case .share(let member): "share/\(member.id)"
        case .invite(_, let invite): "invite/\(invite.code)"
        }
    }
}

struct MemberRow: View {
    @Environment(AppModel.self) private var app
    let member: Account
    let model: HouseholdModel
    @Binding var sheet: HouseholdSheet?
    @Binding var removing: Account?
    @State private var error: String?

    var body: some View {
        let actions = model.actions(for: member)
        HStack(spacing: 12) {
            Avatar(account: member, size: 36).opacity(member.pending ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).font(.system(size: 13, weight: .semibold))
                    if member.hasPin {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.amber)
                            .accessibilityLabel("PIN set")
                    }
                }
                subtitle.font(.system(size: 12)).foregroundStyle(Theme.secondary)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Color(hex: 0xFF6B6B)) }
            }
            Spacer()
            if actions.contains(.resendCode) {
                Button("Resend code") { resend() }.buttonStyle(SecondaryButtonStyle(height: 28))
            }
            if actions.contains(.editKid) {
                Button("Edit") { sheet = .edit(member) }.buttonStyle(SecondaryButtonStyle(height: 28))
            }
            if !actions.subtracting([.resendCode, .editKid]).isEmpty {
                Menu {
                    if actions.contains(.setPin) {
                        Button(member.hasPin ? "Change PIN…" : "Set PIN…") { sheet = .pin(member) }
                    }
                    if actions.contains(.share) { Button("Share with another household…") { sheet = .share(member) } }
                    if actions.contains(.makeAdult) { Button("Change to adult…") { sheet = .toAdult(member) } }
                    if actions.contains(.remove) {
                        Divider()
                        Button(Removal.title(member), role: .destructive) { removing = member }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityLabel("More for \(member.name)")
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: Text {
        let line = Format.member(member, ownerId: app.me?.household?.adultId)
        guard let shared = Format.shared(member) else { return Text(line) }
        return Text("\(line) · \(Image(systemName: "person.2")) \(shared)")
    }

    private func resend() {
        Task {
            do {
                sheet = .invite(member.name, try await model.resendCode(member))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// An offer made to the active adult, to accept or decline, or one of this
/// household's, to withdraw.
struct OfferRow: View {
    let offer: ProfileOffer
    let incoming: Bool
    let model: HouseholdModel
    let run: (@escaping () async throws -> Void) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Color(hex: ProfilePalette.placeholder(offer.profileId))).frame(width: 36, height: 36)
                .overlay {
                    Text(offer.profileName.prefix(1).uppercased()).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.profileName).font(.system(size: 13, weight: .semibold))
                Text(Format.offer(offer, incoming: incoming)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if incoming {
                Button("Decline") { run { try await model.cancel(offer) } }.buttonStyle(
                    SecondaryButtonStyle(height: 28))
                Button("Accept") { run { try await model.accept(offer) } }.buttonStyle(PrimaryButtonStyle(height: 28))
            } else {
                Button("Withdraw") { run { try await model.cancel(offer) } }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
            }
        }
        .padding(.vertical, 6)
    }
}
