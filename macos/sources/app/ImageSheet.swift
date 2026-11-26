import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// A playlist or station shows its new image once the server keeps it.
    func imageSheet(browser: Browser, client: Client?, playlists: PlaylistsModel?) -> some View {
        @Bindable var browser = browser
        return sheet(item: $browser.imaging) { request in
            if let client {
                ImageSheet(model: CustomImageModel(client: client), request: request) {
                    Task {
                        await playlists?.load()
                        browser.revision += 1
                    }
                }
            }
        }
    }
}

struct ImageSheet: View {
    @State var model: CustomImageModel
    let request: ImageRequest
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [ArtChoice]?
    @State private var link = ""
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set image").font(.system(size: 17, weight: .bold))
            Button("Choose a file…") { importing = true }.buttonStyle(SecondaryButtonStyle())
            Text("Pick a title's artwork").font(.system(size: 13, weight: .semibold))
            picks
            HStack {
                TextField("Paste an image link", text: $link).textFieldStyle(.roundedBorder).onSubmit(useLink)
                Button("Use link", action: useLink).buttonStyle(SecondaryButtonStyle())
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.error { Text(error).foregroundStyle(Theme.red).font(.system(size: 12)) }
            HStack {
                if request.hasImage {
                    Button("Remove image", role: .destructive) { run { await model.remove(from: request.target) } }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .disabled(model.busy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            // A picked file is readable only inside its security scope.
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            run { await model.set(.file(data ?? Data()), on: request.target) }
        }
        .task { choices = await model.choices(profileId: request.profileId, playlistId: request.playlistId) }
    }

    @ViewBuilder private var picks: some View {
        if let choices {
            if choices.isEmpty {
                Text("Nothing in it has artwork to pick.").foregroundStyle(Theme.secondary).font(.system(size: 12))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10, alignment: .top)], spacing: 10) {
                        ForEach(choices) { choice in
                            Button {
                                run {
                                    await model.set(
                                        .artwork(itemId: choice.itemId, kind: choice.kind), on: request.target)
                                }
                            } label: {
                                Color.clear.aspectRatio(choice.kind == .backdrop ? 16 / 9 : 2 / 3, contentMode: .fit)
                                    .overlay { ArtImage(id: choice.itemId, kind: choice.kind) }
                                    .clipShape(.rect(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.label)
                            .help(choice.label)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func useLink() { run { await model.set(.link(link), on: request.target) } }

    /// Closes once the server has done it; a refusal stays in the sheet.
    private func run(_ act: @escaping () async -> Bool) {
        Task {
            if await act() {
                done()
                dismiss()
            }
        }
    }
}
