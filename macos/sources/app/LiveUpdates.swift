import RabbitEarsAPI
import RabbitEarsKit
import SwiftUI

/// Follows the server's live events while the window is in view, loads again
/// what each says has changed, and shows the app's brief notices.
struct LiveUpdates: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let catalog: CatalogModel?
    let stations: StationsModel?
    let playlists: PlaylistsModel?
    let browser: Browser

    func body(content: Content) -> some View {
        content
            .task(id: "\(catalog.map { ObjectIdentifier($0).hashValue } ?? 0)/\(scenePhase == .background)") {
                await model.followLive(catalog, inView: scenePhase != .background)
            }
            .onChange(of: model.live.watched) { browser.revision += 1 }
            .onChange(of: model.live.stations) {
                browser.revision += 1
                if model.activeProfile?.kind == .adult { Task { await stations?.loadMine() } }
            }
            .onChange(of: model.live.playlists) {
                browser.revision += 1
                Task { await playlists?.load() }
            }
            .overlay(alignment: .bottom) {
                if let notice = model.live.notice {
                    Text(notice).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14)
                        .frame(height: 32).background(.black.opacity(0.8), in: .capsule).padding(.bottom, 28)
                }
            }
    }
}
