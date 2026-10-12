import SwiftUI

/// Native Liquid Glass backdrop for Tinycast's borderless panels; HUD vibrancy on Sequoia.
struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            return NSGlassEffectView()
        }
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
