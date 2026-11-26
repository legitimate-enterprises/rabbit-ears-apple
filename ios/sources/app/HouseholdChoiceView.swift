import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI
import UIKit

/// After a sign-in of an adult in several households: which one this
/// device shows, their own preselected.
struct HouseholdChoiceView: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: Int64?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        AccountPage(name: model.serverName) {
            Text("Which household is this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") in?")
                .font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Text("You are in more than one. Who's watching shows the profiles of the household you pick.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                ForEach(Array(model.households.enumerated()), id: \.element.id) { index, household in
                    RadioRow(
                        title: "\(household.name)'s household", detail: index == 0 ? "Yours" : "Visiting",
                        selected: chosen == household.id
                    ) {
                        chosen = household.id
                    } leading: {
                        Image(systemName: "house").frame(width: 36, height: 36).background(Theme.border, in: .circle)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.raised, in: .rect(cornerRadius: 12))
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.error) }
            Button(action: submit) {
                if busy { ProgressView().tint(Theme.ground) } else { Text("Continue") }
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            .disabled(busy || chosen == nil)
            Text("Asked once, after signing in. Sign out to change it.").font(.system(size: 13))
                .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity)
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
