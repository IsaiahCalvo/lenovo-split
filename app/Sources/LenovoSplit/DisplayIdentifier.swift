import AppKit
import SwiftUI

@MainActor
final class DisplayIdentifier {
    private var windows: [NSWindow] = []
    private var timer: Timer?
    var isShowing: Bool { !windows.isEmpty }

    func show(displays: [(String, CGDirectDisplayID)], names: [String]) {
        hide()
        for (key,id) in displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }) else { continue }
            let number = key == "builtin" ? 3 : (key == "panel1" ? 1 : 2)
            let name = key == "builtin" ? "Mac display" : names[number-1]
            let badge = VStack(spacing: 2) {
                Text("\(number)").font(.system(size: 76, weight: .bold, design: .rounded))
                Text(name).font(.title3).lineLimit(1)
            }.foregroundStyle(.white).frame(width: 260,height: 170)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 20))
            let window = NSPanel(contentRect: .zero, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("lenovosplit.identify.\(key)")
            window.backgroundColor = .clear; window.isOpaque = false
            window.hasShadow = true; window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false; window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces,.stationary,.fullScreenAuxiliary,.ignoresCycle]
            window.contentView = NSHostingView(rootView: badge)
            let area = screen.visibleFrame
            window.setFrame(CGRect(x: area.midX-130,y: area.midY-85,width: 260,height: 170),display: true)
            window.orderFrontRegardless(); windows.append(window)
        }
        let timer = Timer(timeInterval: 5,repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        RunLoop.main.add(timer,forMode: .common); self.timer = timer
    }
    func hide() {
        timer?.invalidate(); timer = nil
        windows.forEach { $0.orderOut(nil) }; windows = []
    }
}
