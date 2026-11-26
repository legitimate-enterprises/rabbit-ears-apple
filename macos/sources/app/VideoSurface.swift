import AVKit
import SwiftUI

/// AVPlayerLayer in a view, with picture in picture for the player's own
/// button: AVPlayerView starts it only from its own controls. Picture in
/// picture ends with the view, so its window never outlives the player.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    @Binding var pip: AVPictureInPictureController?

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported(),
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
        {
            view.pip = controller
            DispatchQueue.main.async { pip = controller }
        }
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) { view.pip?.stopPictureInPicture() }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var pip: AVPictureInPictureController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { playerLayer }
}
