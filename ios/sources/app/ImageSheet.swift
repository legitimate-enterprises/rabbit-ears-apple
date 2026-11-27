import PhotosUI
import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI
import UniformTypeIdentifiers

/// The owner's Set image, and Remove image while one is set, for a menu.
struct ImageActions: View {
    let request: ImageRequest
    let client: Client
    @Binding var imaging: ImageRequest?
    let done: () async -> Void

    var body: some View {
        Button("Set image", systemImage: "photo") { imaging = request }
        if request.hasImage {
            Button("Remove image", systemImage: "photo.badge.minus") {
                Task { if await CustomImageModel(client: client).remove(from: request.target) { await done() } }
            }
        }
    }
}

extension View {
    /// The Set image sheet for `request`, picking from `playlists`; done reloads what shows the image.
    func imageSheet(
        _ request: Binding<ImageRequest?>, playlists: PlaylistsModel, done: @escaping () async -> Void
    ) -> some View {
        sheet(item: request) {
            ImageSheet(model: CustomImageModel(client: playlists.client), playlists: playlists, request: $0, done: done)
        }
    }
}

/// Set image: a photo, a file, one of the playlist's titles' artwork, or a
/// link the server fetches.
struct ImageSheet: View {
    @State var model: CustomImageModel
    let playlists: PlaylistsModel
    let request: ImageRequest
    let done: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [ArtChoice]?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker("Choose a photo", selection: $photo, matching: .images)
                    Button("Choose a file") { importing = true }
                }
                Section("Pick a title's artwork") { picks }
                Section("Paste an image link") {
                    TextField("https://", text: $link).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().onSubmit(useLink)
                    Button("Use link", action: useLink).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error = model.error { Text(error).foregroundStyle(Theme.error) }
            }
            .disabled(model.busy)
            .navigationTitle("Set image").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if model.busy { ToolbarItem(placement: .confirmationAction) { ProgressView() } }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            run {
                let data = try? await item.loadTransferable(type: Data.self)
                return await model.set(.file(data ?? Data()), on: request.target)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            // A picked file is readable only inside its security scope.
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            run { await model.set(.file(data ?? Data()), on: request.target) }
        }
        .task { choices = await playlists.artChoices(of: request.playlistId) }
    }

    @ViewBuilder private var picks: some View {
        if let choices {
            if choices.isEmpty {
                Text("Nothing in it has artwork to pick.").foregroundStyle(Theme.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(choices) { choice in
                        Button {
                            run {
                                await model.set(.artwork(itemId: choice.itemId, kind: choice.kind), on: request.target)
                            }
                        } label: {
                            Color.clear.aspectRatio(choice.kind == .backdrop ? 16 / 9 : 2 / 3, contentMode: .fit)
                                .overlay { ArtImage(id: choice.itemId, kind: choice.kind) }
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.label)
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func useLink() { run { await model.set(.link(link), on: request.target) } }

    /// Closes once the server has it; a refusal stays in the sheet.
    private func run(_ act: @escaping () async -> Bool) {
        Task {
            if await act() {
                await done()
                dismiss()
            }
        }
    }
}
