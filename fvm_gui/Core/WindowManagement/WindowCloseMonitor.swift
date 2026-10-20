import AppKit
import SwiftUI

struct WindowCloseMonitor: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> WindowCloseObservingView {
        let view = WindowCloseObservingView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: WindowCloseObservingView, context: Context) {
        view.onClose = onClose
    }
}

@MainActor final class WindowCloseObservingView: NSView {
    var onClose: (@MainActor () -> Void)?
    private var observer: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }
        removeObserver()
        guard let window else { return }
        observedWindow = window
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                           object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeObserver()
                self?.onClose?()
            }
        }
    }

    private func removeObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        observedWindow = nil
    }
}
