import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Add a kid, or edit one when given the kid and how to save them.
struct AddKidView: View {
    @Environment(AppModel.self) private var model
    var save: ((AddKidForm) async throws -> Void)?
    var household: HouseholdModel?
    let done: () -> Void
    @State private var form: AddKidForm
    @State private var showErrors = false
    @State private var serverError: String?
    @State private var busy = false

    init(
        editing kid: Account? = nil, household: HouseholdModel? = nil,
        save: ((AddKidForm) async throws -> Void)? = nil, done: @escaping () -> Void
    ) {
        self.save = save
        self.household = household
        self.done = done
        _form = State(initialValue: kid.map { AddKidForm(editing: $0) } ?? AddKidForm())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { fields }
                    .padding(EdgeInsets(top: 8, leading: 16, bottom: 32, trailing: 16))
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.ground)
            .navigationTitle(form.editing.map { "Edit \($0.name)" } ?? "New kid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(form.editing == nil ? "Add" : "Save", action: submit).disabled(busy)
                }
            }
        }
        .onChange(of: form.movieCeiling) {
            if $0 != $1 && form.suggestion?.movieCeiling != $1 { form.ceilingsEdited = true }
        }
        .onChange(of: form.tvCeiling) { if $0 != $1 && form.suggestion?.tvCeiling != $1 { form.ceilingsEdited = true } }
        .task(id: form.birthdayString) {
            if let suggestion = await model.suggestCeilings(for: form) { form.apply(suggestion) }
        }
    }

    @ViewBuilder
    private var fields: some View {
        LabeledField(label: "Name", error: shown(.name)) {
            TextField("", text: $form.name).textContentType(.givenName).accessibilityLabel("Name")
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Birthday").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            DatePicker("Birthday", selection: $form.birthday, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
            if let hint = form.hint { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            if let error = shown(.birthday) { Text(error).font(.system(size: 12)).foregroundStyle(Theme.error) }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Filter").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            let ratings = "Pick the highest rating for movies and TV. Suggested from the birthday."
            filterOption(.ratings, "Ratings", ratings) {
                HStack(spacing: 12) {
                    ratingPicker("Movies up to", $form.movieCeiling, AddKidForm.movieRatings)
                    ratingPicker("TV up to", $form.tvCeiling, AddKidForm.tvRatings)
                }
                .padding(.leading, 26)
            }
            filterOption(.allowList, "Only titles I choose", "Nothing shows until you add it.") {
                // Allow-list changes apply at once; a new kid gets one after it is saved.
                if let kid = form.editing, let household { AllowListView(kid: kid, model: household) }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            ColorSwatches(selected: form.color) { form.color = $0 }
        }
        Toggle(isOn: $form.requirePin) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Require a PIN").font(.system(size: 15, weight: .semibold))
                Text("Only you can set or change it. Leave off for a young kid.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(12)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        if form.requirePin {
            HStack(spacing: 12) {
                let label = form.editing?.hasPin == true ? "New PIN (blank keeps it)" : "PIN"
                LabeledField(label: label, error: shown(.pin)) {
                    SecureField("", text: $form.pin).keyboardType(.numberPad).accessibilityLabel("PIN")
                }
                LabeledField(label: "Confirm PIN") {
                    SecureField("", text: $form.pinConfirmation).keyboardType(.numberPad)
                        .accessibilityLabel("Confirm PIN")
                }
            }
        }
        Text("Watch history is kept separately for \(form.trimmedName.isEmpty ? "them" : form.trimmedName).")
            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        if let serverError { Text(serverError).font(.system(size: 13)).foregroundStyle(Theme.error) }
    }

    private func shown(_ field: AddKidForm.Field) -> String? { showErrors ? form.errors[field] : nil }

    private func ratingPicker<Rating: Hashable & RawRepresentable<String>>(
        _ label: String, _ selection: Binding<Rating>, _ ratings: [Rating]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Picker(label, selection: selection) { ForEach(ratings, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Theme.raised, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
    }

    private func filterOption<Detail: View>(
        _ mode: Components.Schemas.FilterMode, _ title: String, _ detail: String,
        @ViewBuilder expanded: () -> Detail
    ) -> some View {
        let selected = form.filterMode == mode
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                form.filterMode = mode
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Theme.amber : Theme.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if selected { expanded() }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? Theme.amber.opacity(0.12) : Theme.raised, in: .rect(cornerRadius: 8))
    }

    private func submit() {
        showErrors = true
        guard form.errors.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let save { try await save(form) } else { try await model.addKid(form) { form.editing = $0 } }
                done()
            } catch {
                serverError = error.localizedDescription
            }
        }
    }
}
