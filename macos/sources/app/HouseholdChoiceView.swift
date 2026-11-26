import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// After a sign-in of an adult in several households: which one this Mac
/// shows, their own preselected.
struct HouseholdChoiceView: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: Int64?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        AccountCard {
            Text("Which household is this Mac in?").font(.system(size: 22, weight: .bold))
            Text("You are in more than one. Who's watching shows the profiles of the household you pick.")
                .foregroundStyle(Theme.secondary)
            Picker("Household", selection: $chosen) {
                ForEach(Array(model.households.enumerated()), id: \.element.id) { index, household in
                    Text("\(household.name)'s household · \(index == 0 ? "Yours" : "Visiting")")
                        .tag(Optional(household.id))
                }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Color(hex: 0xFF6B6B)) }
            Button(action: submit) {
                if busy { ProgressView().controlSize(.small) } else { Text("Continue") }
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true, height: 44))
            .keyboardShortcut(.defaultAction)
            .disabled(busy || chosen == nil)
            Text("Asked once, after signing in. Sign out to change it.").font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .onAppear { if chosen == nil { chosen = model.households.first?.id } }
    }

    private func submit() {
        guard let choice = model.households.first(where: { $0.id == chosen }), !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.chooseHousehold(choice)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
