import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// A request to edit a station, or to make one of a kind, perhaps for something to go in it.
struct StationEditRequest: Identifiable {
    let id = UUID()
    var station: Station?
    var kind = PlaylistKind.movies
    /// Takes a new station in place of opening its page, as Add to station's New station does.
    var made: ((Station) -> Void)?

    init(station: Station) {
        self.station = station
        kind = station.kind
    }

    init(kind: PlaylistKind = .movies, made: ((Station) -> Void)? = nil) {
        self.kind = kind
        self.made = made
    }
}

struct StationEditor: View {
    @Environment(Services.self) private var services
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    let request: StationEditRequest
    @State private var form = StationForm(kind: .movies)
    @State private var deleting = false
    @State private var busy = false
    @State private var rescheduling: Station?

    var body: some View {
        let stations = services.stations
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identity
                    scheduleFields
                    rating
                    if stations.fieldErrors.isEmpty, let error = stations.error {
                        Note(text: error, color: Theme.error)
                    }
                    if request.station != nil {
                        Button("Delete station") { deleting = true }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.error)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 24, trailing: 16))
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.ground)
            .navigationTitle(request.station == nil ? "New station" : "Edit station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(form.input == nil || busy)
                }
            }
        }
        .foregroundStyle(Theme.primary)
        .tint(Theme.amber)
        .onAppear { form = request.station.map(StationForm.init) ?? StationForm(kind: request.kind) }
        .onChange(of: form.kind) { if request.station == nil { form.timing = StationForm.timing(for: form.kind) } }
        .confirmationDialog(
            "Delete “\(request.station?.name ?? "")”?", isPresented: $deleting, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Its contents and schedule go with it.")
        }
        .rescheduleQuestion($rescheduling, services.stations) {
            browser.revision += 1
            dismiss()
        }
    }

    @ViewBuilder
    private var identity: some View {
        let errors = services.stations.fieldErrors
        LabeledField(label: "Name", error: errors["name"]) { TextField("Name", text: $form.name) }
        LabeledField(label: "Kind", error: errors["kind"]) {
            if request.station == nil {
                Picker("Kind", selection: $form.kind) {
                    Text("Movies").tag(PlaylistKind.movies)
                    Text("TV").tag(PlaylistKind.tv)
                    Text("Music").tag(PlaylistKind.music)
                }
                .pickerStyle(.segmented).labelsHidden()
            } else {
                Text(StationText.kind(form.kind)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Note(text: "A station holds one kind, chosen once. Add to it from any title's More menu.")
        HStack(alignment: .top, spacing: 12) {
            LabeledField(label: "Order") {
                Picker("Order", selection: $form.order) {
                    Text("In order").tag(Components.Schemas.StationOrder.playlist)
                    Text("Shuffled").tag(Components.Schemas.StationOrder.random)
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            LabeledField(label: "Visibility") {
                if form.serverWide {
                    Text("Server").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Visibility", selection: $form.visibility) {
                        Text("Private").tag(Components.Schemas.StationVisibility._private)
                        Text("Household").tag(Components.Schemas.StationVisibility.household)
                    }
                    .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        Note(text: "Only a server admin can make a station server wide.")
    }

    @ViewBuilder
    private var scheduleFields: some View {
        Text("Schedule").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        option(.continuous, "Continuous")
        VStack(alignment: .leading, spacing: 0) {
            option(.chosen, "Chosen days and times")
            if form.schedule == .chosen { chosen }
        }
        .background(form.schedule == .chosen ? Theme.amber.opacity(0.1) : .clear, in: .rect(cornerRadius: 10))
        if let error = services.stations.fieldErrors.first(where: {
            $0.key.hasPrefix("days") || $0.key.hasPrefix("times")
        }) {
            Note(text: error.value, color: Theme.error)
        }
        LabeledField(label: "Timing") {
            Picker("Timing", selection: $form.timing) {
                ForEach([Components.Schemas.StationTiming.continuous, .halfHour, .hour], id: \.self) {
                    Text(StationText.timing($0)).tag($0)
                }
            }
            .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
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
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(14)
            .background(Theme.raised.opacity(form.schedule == schedule ? 0 : 1), in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(form.schedule == schedule ? .isSelected : [])
    }

    private var chosen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Note(text: "Server time. A program still playing when a range ends plays to its end.")
            HStack(spacing: 4) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    let on = form.days.contains(day)
                    Button(String(day.rawValue.prefix(3)).capitalized) {
                        if on { form.days.remove(day) } else { form.days.insert(day) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Theme.ground : Theme.primary)
                    .frame(maxWidth: .infinity, minHeight: 32)
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
                    Spacer(minLength: 0)
                    Button {
                        form.times.remove(at: index)
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(Theme.secondary).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Remove this time range")
                }
            }
            Button("Add a time range") { form.times.append(.init(from: "18:00", to: "22:00")) }
                .buttonStyle(LinkButtonStyle())
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
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

    private var rating: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rating").font(.system(size: 15, weight: .semibold))
                Note(text: "The highest rating of what it holds. Recalculated hourly.")
            }
            Spacer()
            Tag(text: request.station.map(StationText.rating) ?? "None")
        }
        .padding(14).background(Theme.raised, in: .rect(cornerRadius: 10))
    }

    private func save() {
        busy = true
        Task {
            let saved = await services.stations.save(form, as: request.station?.id)
            busy = false
            guard let saved else { return }
            if request.station != nil {
                rescheduling = saved
                return
            }
            browser.revision += 1
            dismiss()
            if let made = request.made {
                made(saved)
            } else if request.station == nil {
                browser.open(.station(saved.id))
            }
        }
    }

    private func delete() {
        guard let station = request.station else { return }
        Task {
            guard await services.stations.delete(station.id) else { return }
            for tab in browser.paths.keys { browser.paths[tab]?.removeAll { $0 == .station(station.id) } }
            browser.revision += 1
            dismiss()
        }
    }
}

extension View {
    /// Reschedule now? once the owner has saved a station or changed what
    /// it plays; either answer ends with `done`.
    func rescheduleQuestion(
        _ station: Binding<Station?>, _ stations: StationsModel, done: @escaping () -> Void
    ) -> some View {
        alert(
            StationText.rescheduleQuestion,
            isPresented: Binding(get: { station.wrappedValue != nil }, set: { if !$0 { station.wrappedValue = nil } }),
            presenting: station.wrappedValue
        ) { chosen in
            Button("Now") {
                Task {
                    _ = await stations.reschedule(chosen.id)
                    done()
                }
            }
            Button("Later", role: .cancel, action: done)
        } message: { _ in
            Text(StationText.rescheduleAnswers)
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
