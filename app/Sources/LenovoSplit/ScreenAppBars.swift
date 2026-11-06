import AppKit
import SwiftUI

private struct AppBarEntry: Identifiable {
    let id: String
    let url: URL
    let name: String
    let icon: NSImage
    var running: Bool
}

/// A launcher on each usable display, not a clone or modification of Dock.app.
/// Uses only application URLs and NSWorkspace; never reads app window content.
@MainActor
final class ScreenAppBars: ObservableObject {
    @Published fileprivate var entries: [AppBarEntry] = []
    private var panels: [NSPanel] = []
    private var observers: [(NotificationCenter,NSObjectProtocol)] = []
    private var displays: [(String,CGDirectDisplayID)] = []
    private var enabled = false
    private var pending: DispatchWorkItem?
    private(set) var reservedHeight: CGFloat = 0

    func setEnabled(_ enabled: Bool,displays: [(String,CGDirectDisplayID)]) {
        self.enabled = enabled; self.displays = displays
        hide()
        guard enabled,!displays.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            let observer = workspace.addObserver(forName: name,object: nil,queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps() }
            }
            observers.append((workspace,observer))
        }
        let center = NotificationCenter.default
        let observer = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,object: nil,queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.buildPanels() }
                self.pending = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.4,execute: work)
            }
        }
        observers.append((center,observer))
        refreshApps(); buildPanels()
    }

    private func refreshApps() {
        var result: [AppBarEntry] = []
        var seen = Set<String>()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        func append(_ url: URL) {
            guard url.isFileURL,url.pathExtension.lowercased() == "app",let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier,id != Bundle.main.bundleIdentifier,seen.insert(id).inserted else { return }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            result.append(.init(id: id,url: url,name: name,icon: NSWorkspace.shared.icon(forFile: url.path),running: runningIDs.contains(id)))
        }
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") { append(finder) }
        let dock = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")
        for tile in dock?["persistent-apps"] as? [[String:Any]] ?? [] {
            guard let data = tile["tile-data"] as? [String:Any],let file = data["file-data"] as? [String:Any],
                  let path = file["_CFURLString"] as? String,let url = URL(string: path) else { continue }
            append(url)
        }
        for app in running.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            if let url = app.bundleURL { append(url) }
        }
        entries = result
    }

    private func buildPanels() {
        panels.forEach { $0.orderOut(nil) }; panels = []
        guard enabled else { return }
        let screens = NSScreen.screens
        reservedHeight = max(74,screens.map { $0.visibleFrame.minY-$0.frame.minY }.max() ?? 0)
        for (key,id) in displays {
            guard let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }) else { continue }
            let frame = CGRect(x: screen.frame.minX,y: screen.frame.minY,width: screen.frame.width,height: reservedHeight)
            let panel = NSPanel(contentRect: frame,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("lenovosplit.appbar.\(key)")
            panel.title = "App bar — \(key)"
            panel.isReleasedWhenClosed = false; panel.isOpaque = false
            panel.backgroundColor = .clear; panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces,.stationary,.fullScreenAuxiliary,.ignoresCycle]
            panel.contentView = NSHostingView(rootView: AppBarView(bars: self))
            panel.setFrame(frame,display: true); panel.orderFrontRegardless(); panels.append(panel)
        }
        Log.write("app bars visible=\(panels.count)")
    }
    fileprivate func open(_ entry: AppBarEntry) {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: entry.url,configuration: configuration) { _,error in
            if let error { Log.write("app bar launch failed: \(error.localizedDescription)") }
        }
    }
    func hide() {
        pending?.cancel(); pending = nil
        observers.forEach { $0.0.removeObserver($0.1) }; observers = []
        panels.forEach { $0.orderOut(nil) }; panels = []; reservedHeight = 0
    }
}

private struct AppBarView: View {
    @ObservedObject var bars: ScreenAppBars
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal,showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bars.entries) { entry in
                        Button { bars.open(entry) } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: entry.icon).resizable().interpolation(.high).frame(width: 42,height: 42)
                                Circle().fill(entry.running ? Color.primary.opacity(0.8) : .clear).frame(width: 4,height: 4)
                            }.frame(width: 48,height: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(entry.name).accessibilityLabel("Open \(entry.name)")
                    }
                }.padding(.horizontal,14).frame(minWidth: geometry.size.width,minHeight: geometry.size.height)
            }
        }.background(.regularMaterial)
    }
}
