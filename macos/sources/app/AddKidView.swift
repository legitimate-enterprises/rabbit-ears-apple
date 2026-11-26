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

    init(
        editing kid: Account? = nil, household: HouseholdModel? = nil,
        save: ((AddKidForm) async throws -> Void)? = nil, done: @escaping () -> Void
    ) {
        self.save = save
        self.household = household
        self.done = done
        _form = State(initialValue: kid.map { AddKidForm(editing: $0) } ?? AddKidForm())
    }
    @State private var showErrors = false
    @State private var serverError: String?
    @State private var busy = false

    var body: some View {
        AccountCard(width: 520) {
            VStack(alignment: .leading, spacing: 6) {
                Text(form.editing.map { "Edit \($0.name)" } ?? "Add a kid").font(.system(size: 22, weight: .bold))
                Text(
                    form.editing == nil
                        ? "They will appear next to you on every device in your household."
                        : "Changes apply on every device in your household."
                )
                .foregroundStyle(Theme.secondary)
            }
            LabeledField(label: "Name", error: shown(.name)) {
                TextField("", text: $form.name).accessibilityLabel("Name")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                ColorSwatches(selection: $form.color)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Birthday").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                DatePicker("Birthday", selection: $form.birthday, in: ...Date(), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field)
                if let hint = form.hint { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                if let error = shown(.birthday) { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Filter").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                filterOption(
                    .ratings, "Ratings", "Pick the highest rating for movies and TV. Suggested from the birthday.")
                if form.filterMode == .ratings {
                    HStack(spacing: 16) {
                        Picker("Movies up to", selection: $form.movieCeiling) {
                            ForEach(AddKidForm.movieRatings, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("TV up to", selection: $form.tvCeiling) {
                            ForEach(AddKidForm.tvRatings, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    .padding(.leading, 12)
                }
                filterOption(.allowList, "Only titles I choose", "Nothing shows until you add it.")
                // Allow-list changes apply at once; a new kid gets one after it is saved.
                if form.filterMode == .allowList, let kid = form.editing, let household {
                    AllowListView(kid: kid, model: household).padding(.leading, 12)
                }
            }
            Toggle(isOn: $form.requirePin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require a PIN").font(.system(size: 13, weight: .semibold))
                    Text("Only you can set or change it. Leave off for a young kid.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch)
            if form.requirePin {
                HStack(spacing: 12) {
                    let label = form.editing?.hasPin == true ? "New PIN (blank keeps it)" : "PIN"
                    LabeledField(label: label, error: shown(.pin)) {
                        SecureField("", text: $form.pin).accessibilityLabel("PIN")
                    }
                    LabeledField(label: "Confirm PIN") {
                        SecureField("", text: $form.pinConfirmation).accessibilityLabel("Confirm PIN")
                    }
                }
            }
            Text(
                "Kids hear no explicit songs and see only the YouTube channels their filter allows. "
                    + "Watch history is kept separately for \(form.trimmedName.isEmpty ? "them" : form.trimmedName)."
            )
            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            if let serverError { Text(serverError).font(.system(size: 13)).foregroundStyle(.red) }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: done).buttonStyle(SecondaryButtonStyle(height: 34))
                    .keyboardShortcut(.cancelAction)
                Button(form.submitTitle, action: submit).buttonStyle(PrimaryButtonStyle(height: 34))
                    .keyboardShortcut(.defaultAction).disabled(busy)
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

    private func shown(_ field: AddKidForm.Field) -> String? { showErrors ? form.errors[field] : nil }

    private func filterOption(_ mode: Components.Schemas.FilterMode, _ title: String, _ detail: String) -> some View {
        Button {
            form.filterMode = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: form.filterMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(form.filterMode == mode ? Theme.amber : Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(form.filterMode == mode ? Theme.amber : Theme.border))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(form.filterMode == mode ? .isSelected : [])
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
