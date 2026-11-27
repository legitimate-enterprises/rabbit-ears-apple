import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A request to edit a station, or to make one of a kind, perhaps for an
/// item or collection to land in.
struct StationEditRequest: Identifiable {
    let id = UUID()
    var station: Station?
    var kind = PlaylistKind.movies
    var itemId: UID?
    /// The edition chosen on details; nil asks the server, which may ask the adult.
    var editionId: UID?
    var collectionId: UID?
}

struct StationEditor: View {
    @Environment(StationsModel.self) private var stations
    @Environment(PlaylistsModel.self) private var playlists: PlaylistsModel?
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let request: StationEditRequest
    @State private var form = StationForm(kind: .movies)
    @State private var deleting = false
    @State private var busy = false
    @State private var rescheduling: Station?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(request.station == nil ? "New station" : "Edit station").font(.system(size: 20, weight: .bold))
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) { identity }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) { scheduleFields }.frame(maxWidth: .infinity)
            }
            if stations.fieldErrors.isEmpty, let error = stations.error { Note(text: error, color: Theme.red) }
            HStack {
                if request.station != nil {
                    Button("Delete station") { deleting = true }.buttonStyle(SecondaryButtonStyle())
                        .foregroundStyle(Theme.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle()).disabled(form.input == nil || busy)
            }
        }
        .padding(28).frame(width: 880)
        .background(Theme.card)
        .onAppear { form = request.station.map(StationForm.init) ?? StationForm(kind: request.kind) }
        .onChange(of: form.kind) { if request.station == nil { form.timing = StationForm.timing(for: form.kind) } }
        .rescheduleQuestion($rescheduling, stations) {
            browser.revision += 1
            dismiss()
        }
        .confirmationDialog(
            "Delete “\(request.station?.name ?? "")”?", isPresented: $deleting, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Its schedule and what it holds go with it. Everything stays in your libraries.")
        }
    }

    @ViewBuilder
    private var identity: some View {
        LabeledField(label: "Name", error: stations.fieldErrors["name"]) {
            TextField("Name", text: $form.name)
        }
        Field(label: "Kind", error: stations.fieldErrors["kind"]) {
            if request.station == nil {
                Picker("Kind", selection: $form.kind) {
                    Text("Movies").tag(PlaylistKind.movies)
                    Text("TV").tag(PlaylistKind.tv)
                    Text("Music").tag(PlaylistKind.music)
                }
                .pickerStyle(.segmented).labelsHidden()
            } else {
                Text(StationText.kind(form.kind)).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            }
        }
        Note(text: "Chosen once. Add to it from any title's menu.")
        HStack(alignment: .top, spacing: 12) {
            Field(label: "Order") {
                Picker("Order", selection: $form.order) {
                    Text("In order").tag(Components.Schemas.StationOrder.playlist)
                    Text("Shuffled").tag(Components.Schemas.StationOrder.random)
                }
                .labelsHidden()
            }
            Field(label: "Visibility") {
                if form.serverWide {
                    Text("Server").frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                } else {
                    Picker("Visibility", selection: $form.visibility) {
                        Text("Private").tag(Components.Schemas.StationVisibility._private)
                        Text("Household").tag(Components.Schemas.StationVisibility.household)
                    }
                    .labelsHidden()
                }
            }
        }
        Note(text: "Only a server admin can make a station server wide.")
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rating").font(.system(size: 14, weight: .semibold))
                Note(text: "The highest rating of what it holds. Recalculated hourly.")
            }
            Spacer()
            Tag(text: request.station.map(StationText.rating) ?? "None")
        }
        .padding(12).background(Theme.raised, in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var scheduleFields: some View {
        Text("Schedule").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        option(.continuous, "Continuous")
        VStack(alignment: .leading, spacing: 10) {
            option(.chosen, "Chosen days and times")
            if form.schedule == .chosen { chosen }
        }
        .background(form.schedule == .chosen ? Theme.amber.opacity(0.1) : .clear, in: .rect(cornerRadius: 8))
        if let error = stations.fieldErrors.first(where: { $0.key.hasPrefix("days") || $0.key.hasPrefix("times") }) {
            Note(text: error.value, color: Theme.red)
        }
        Field(label: "Timing") {
            Picker("Timing", selection: $form.timing) {
                ForEach([Components.Schemas.StationTiming.continuous, .halfHour, .hour], id: \.self) {
                    Text(StationText.timing($0)).tag($0)
                }
            }
            .labelsHidden()
        }
        Note(text: "When each program starts after the one before ends.")
    }

    private func option(_ schedule: StationForm.Schedule, _ title: String) -> some View {
        Button {
            form.schedule = schedule
        } label: {
            HStack(spacing: 10) {
                Image(systemName: form.schedule == schedule ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(form.schedule == schedule ? Theme.amber : Theme.secondary)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(12).background(Theme.raised.opacity(form.schedule == schedule ? 0 : 1), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(form.schedule == schedule ? .isSelected : [])
    }

    private var chosen: some View {
        VStack(alignment: .leading, spacing: 10) {
            Note(text: "Server time. A program still playing when a range ends plays to its end.")
            HStack(spacing: 6) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    let on = form.days.contains(day)
                    Button(String(day.rawValue.prefix(3)).capitalized) {
                        if on { form.days.remove(day) } else { form.days.insert(day) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Theme.ground : Theme.primary)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(on ? Theme.amber : .clear, in: .capsule)
                    .overlay(Capsule().stroke(on ? .clear : Theme.border))
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            ForEach(form.times.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    clock(\.from, index)
                    Text("to").foregroundStyle(Theme.secondary)
                    clock(\.to, index)
                    Button {
                        form.times.remove(at: index)
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Remove this time range")
                }
            }
            Button("Add a time range") { form.times.append(.init(from: "18:00", to: "22:00")) }
                .buttonStyle(LinkButtonStyle())
        }
        .padding(EdgeInsets(top: 0, leading: 36, bottom: 12, trailing: 12))
    }

    /// The server's wall-clock time, shown and picked in UTC so nothing shifts it.
    private func clock(_ end: WritableKeyPath<StationTimeRange, String>, _ index: Int) -> some View {
        DatePicker(
            "Time",
            selection: Binding(
                get: { StationForm.date(form.times[index][keyPath: end]) },
                set: { form.times[index][keyPath: end] = StationForm.clock($0) }),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .environment(\.timeZone, StationForm.zone)
    }

    private func save() {
        busy = true
        Task {
            let saved = await stations.save(form, as: request.station?.id)
            guard let saved else {
                busy = false
                return
            }
            if request.station == nil {
                await playlists?.add(
                    item: request.itemId, edition: request.editionId, collection: request.collectionId,
                    to: saved.playlistId)
            }
            busy = false
            if request.station != nil {
                rescheduling = saved
                return
            }
            browser.revision += 1
            dismiss()
            if request.station == nil && request.itemId == nil && request.collectionId == nil {
                browser.open(.station(saved.id))
            }
        }
    }

    private func delete() {
        guard let station = request.station else { return }
        Task {
            guard await stations.delete(station.id) else { return }
            browser.path.removeAll { $0 == .station(station.id) }
            browser.revision += 1
            dismiss()
        }
    }
}

extension View {
    /// Reschedule now? once the owner has saved a station or changed what
    /// it plays; either answer ends with `done`.
    func rescheduleQuestion(
        _ station: Binding<Station?>, _ stations: StationsModel?, done: @escaping () -> Void
    ) -> some View {
        alert(
            StationText.rescheduleQuestion,
            isPresented: Binding(get: { station.wrappedValue != nil }, set: { if !$0 { station.wrappedValue = nil } }),
            presenting: station.wrappedValue
        ) { chosen in
            Button("Now") {
                Task {
                    _ = await stations?.reschedule(chosen.id)
                    done()
                }
            }
            Button("Later", role: .cancel, action: done)
        } message: { _ in
            Text(StationText.rescheduleAnswers)
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    var error: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            content.frame(maxWidth: .infinity, alignment: .leading)
            if let error { Note(text: error, color: Theme.red) }
        }
    }
}

private struct Note: View {
    let text: String
    var color = Theme.secondary

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
