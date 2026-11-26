import AVKit
import SwiftUI

/// AVPlayerLayer in a view, with picture in picture starting on its own
/// when the app leaves the foreground mid-playback.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    @Binding var pip: AVPictureInPictureController?

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported(),
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
        {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            DispatchQueue.main.async { pip = controller }
        }
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }
}

final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.amber)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
