import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// After a password sign-in of an adult in several households: which one
/// this Apple TV shows. Focus starts on their own; picking a row continues.
struct HouseholdChoiceView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        AccountPage(name: model.serverName) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Which household is this Apple TV in?").font(.system(size: 64, weight: .bold))
                Text("You are in more than one. Who's watching shows the profiles of the household you pick.")
                    .font(.system(size: 30)).foregroundStyle(Theme.secondary).padding(.top, 20)
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(model.households.enumerated()), id: \.element.id) { index, household in
                        Button {
                            choose(household)
                        } label: {
                            HStack(spacing: 34) {
                                Image(systemName: "house").font(.system(size: 36)).frame(width: 46)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(household.name)'s household").font(.system(size: 36, weight: .bold))
                                    Text(index == 0 ? "Yours" : "Visiting").font(.system(size: 28))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 34)
                            .frame(width: 948, height: 126)
                            .background(Theme.control, in: .rect(cornerRadius: 20))
                        }
                        .buttonStyle(RowButtonStyle())
                        .disabled(busy)
                    }
                    if let error { Text(error).font(.system(size: 28)).foregroundStyle(Theme.amber) }
                }
                .padding(.top, 44)
                Text("Asked once, after signing in. Sign out to change it.").font(.system(size: 28))
                    .foregroundStyle(Theme.secondary).padding(.top, 44)
            }
            .padding(.leading, 120).padding(.top, 120)
        }
    }

    private func choose(_ household: Components.Schemas.HouseholdChoice) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.chooseHousehold(household)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
