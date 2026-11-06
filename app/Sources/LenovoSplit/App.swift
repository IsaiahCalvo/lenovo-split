import AppKit
import SwiftUI
import Combine
import LenovoDock
import DisplayLayout

struct HubError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ message: String) { description = message }
    var errorDescription: String? { description }
}

enum Log {
    static let url = FileManager.default.temporaryDirectory.appendingPathComponent("LenovoSplit.log")
    static func write(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        NSLog("LenovoSplit: %@", message)
        guard let data = line.data(using: .utf8) else { return }
        if let file = try? FileHandle(forWritingTo: url) {
            file.seekToEndOfFile(); file.write(data); try? file.close()
        } else { try? data.write(to: url) }
    }
}

@MainActor
final class Model: ObservableObject {
    let controller = TwoDisplayController()
    @Published var status = "Waiting for the ThinkPad 40AS dock."
    @Published var busy = false
    @Published var running = false
    @Published var connected = false
    @Published var permission = CGPreflightScreenCaptureAccess()
    @Published var autoConnect: Bool = UserDefaults.standard.object(forKey: "autoConnect") == nil ? true : UserDefaults.standard.bool(forKey: "autoConnect") {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect"); if autoConnect { paused = false; monitor?.schedule() } }
    }
    @Published var swap: Bool = UserDefaults.standard.bool(forKey: "swap") {
        didSet { controller.swapSides = swap; UserDefaults.standard.set(swap, forKey: "swap") }
    }
    @Published var windowAccess = WindowFitter.trusted
    @Published var fitWindows = UserDefaults.standard.bool(forKey: "fitWindows") {
        didSet {
            UserDefaults.standard.set(fitWindows, forKey: "fitWindows")
            fitter.setEnabled(fitWindows && windowAccess)
        }
    }
    private let fitter = WindowFitter()
    private let appBars = ScreenAppBars()
    @Published var showAppBars = UserDefaults.standard.bool(forKey: "showAppBars") {
        didSet {
            UserDefaults.standard.set(showAppBars,forKey: "showAppBars")
            appBars.setEnabled(showAppBars && running,displays: controller.layoutDisplays)
        }
    }
    @Published private(set) var panelNames = UserDefaults.standard.stringArray(forKey: "panelNames") ?? ["Display 1", "Display 2"]
    @Published private(set) var previewSeconds = 0
    @Published private(set) var layoutVerified = false
    var onOpenLayout: (() -> Void)?
    private let identifier = DisplayIdentifier()
    private var previewTimer: Timer?
    private var previousLayout: ScreenLayout?
    private var recoveryTimer: Timer?
    private var healthBusy = false
    private var healthFailures = 0
    private var unsupported = false
    private var originalOrigins: [(CGDirectDisplayID, CGPoint)] = []
    private var monitor: DockMonitor?
    private let worker = DispatchQueue(label: "lenovosplit.dock")
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var paused = false
    private var attempts = 0

    init() {
        controller.swapSides = swap
        if panelNames.count != 2 { panelNames = ["Display 1", "Display 2"] }
        controller.panelNames = panelNames
        if let data = UserDefaults.standard.data(forKey: "screenLayout") {
            controller.savedLayout = try? JSONDecoder().decode(ScreenLayout.self,from: data)
        }
        fitter.allowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: "fitAppIDs") ?? [])
        fitter.isRunning = { [weak self] in self?.running == true }
        fitter.appBarHeight = { [weak self] in self?.appBars.reservedHeight ?? 0 }
        fitter.setEnabled(fitWindows && windowAccess)
        monitor = DockMonitor { [weak self] in self?.dockChanged() }
    }

    func requestWindowAccess() {
        WindowFitter.requestPermission()
        status = "Allow Accessibility for Lenovo Split, then choose Check window permission."
    }
    func refreshWindowAccess() {
        windowAccess = WindowFitter.trusted
        fitter.allowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: "fitAppIDs") ?? [])
        fitter.setEnabled(fitWindows && windowAccess)
    }

    func dockChanged() {
        refreshWindowAccess()
        let present = lenovo_dock_connected() != 0
        if present != connected {
            Log.write("USB dock connected=\(present)")
            connected = present; attempts = 0; healthFailures = 0; unsupported = false
            if present { paused = false }
        }
        if !present {
            recoveryTimer?.invalidate(); recoveryTimer = nil
            if running || busy { stopInternal() }
            status = "Waiting for the ThinkPad 40AS dock."
        } else if autoConnect && !paused && !busy && !healthBusy && !unsupported {
            if running { checkHealth() } else { prepareAndStart() }
        }
    }

    func requestPermission() {
        permission = CGRequestScreenCaptureAccess()
        status = "Allow Lenovo Split in Screen & System Audio Recording, then choose Start."
    }

    func start() {
        paused = false; attempts = 0; unsupported = false
        connected = lenovo_dock_connected() != 0
        prepareAndStart()
    }

    private func prepareAndStart() {
        guard connected, !busy, !running else { return }
        permission = CGPreflightScreenCaptureAccess()
        guard permission else { status = "Allow Screen Recording to use the separate screens."; return }
        attempts += 1; busy = true; status = "Checking the dock…"
        let token = generation
        worker.async {
            var state = LenovoDockState()
            let result = lenovo_dock_prepare(&state)
            let error = withUnsafeBytes(of: state.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let count = Int(state.monitors), wide = state.wide != 0, changed = state.changed != 0
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.busy = false
                if result != 0 {
                    self.status = error; Log.write("prepare failed: \(error)")
                    self.unsupported = error.contains("not been verified") || error.contains("differs from the tested") || error.contains("must each use") || error.contains("API unavailable")
                    self.retry(); return
                }
                Log.write("prepare monitors=\(count) wide=\(wide) changed=\(changed)")
                guard count == 2 else {
                    self.status = "Waiting for both dock outputs. If a monitor is shared with another computer, select the input wired to this dock. Recovery stays on while you switch inputs."
                    self.retry(); return
                }
                guard wide else {
                    self.status = "Waiting for the dock’s display data to refresh."
                    self.retry(); return
                }
                self.startDisplays()
            }
        }
    }

    private func retry() {
        guard autoConnect, !paused, !unsupported else { return }
        scheduleCheck(after: min(15,pow(2,Double(min(attempts,4)))))
    }

    private func scheduleCheck(after delay: Double) {
        recoveryTimer?.invalidate()
        let timer = Timer(timeInterval: delay,repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dockChanged() }
        }
        RunLoop.main.add(timer,forMode: .common); recoveryTimer = timer
    }

    private func checkHealth() {
        healthBusy = true
        let token = generation
        worker.async {
            var state = LenovoDockState()
            let result = lenovo_dock_check(&state)
            let count = state.monitors, mode = state.mode
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.healthBusy = false
                let healthy = result == 0 && count == 2 && mode == 2 && self.controller.transportHealthy
                self.healthFailures = healthy ? 0 : self.healthFailures+1
                if self.healthFailures >= 2 {
                    let physical = self.controller.physicalDisplayID
                    self.stopInternal()
                    self.worker.async { lenovo_dock_forget_host_refresh() }
                    if result == 0 && count < 2,
                       let single = DisplayModes.all(physical).first(where: { $0.width == 1920 && $0.height == 1080 && !$0.isHiDPI && $0.refresh == 60 }) {
                        DisplayModes.apply(single,on: physical,permanently: false)
                    }
                    self.status = "A dock output changed. Waiting for both monitors to use their dock input…"
                    self.attempts = 0; self.retry()
                    Log.write("recovery: dock outputs=\(count) mode=\(mode) check=\(result)")
                } else { self.scheduleCheck(after: healthy ? 10 : 3) }
            }
        }
    }

    private func startDisplays() {
        let physicalCandidate = DisplayModes.externalDisplay()
        let candidateModes = physicalCandidate.map { DisplayModes.all($0) } ?? []
        let wideCandidate = candidateModes.first { $0.width == 3840 && $0.height == 1080 && !$0.isHiDPI && $0.refresh == 60 }
        Log.write("mode lookup API=\(DisplayModes.available) physical=\(String(describing: physicalCandidate)) count=\(candidateModes.count) wide=\(String(describing: wideCandidate))")
        guard let physical = physicalCandidate, let wide = wideCandidate else {
            status = "Waiting for macOS to read the wide display mode."; retry(); return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        originalOrigins = ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0).origin) }
        busy = true; status = "Starting separate screens…"
        let token = generation
        startTask = Task {
            do {
                try await controller.start(physical: physical, wide: wide)
                try Task.checkCancellation()
                guard token == generation else { return }
                running = true; attempts = 0; healthFailures = 0
                appBars.setEnabled(showAppBars,displays: controller.layoutDisplays)
                status = "Two separate screens connected."
                scheduleCheck(after: 10)
                Log.write("STARTED panels=\(controller.panelIDs) frames=\(controller.frameCounts)")
            } catch {
                guard token == generation else { return }
                controller.stop(); restoreOrigins()
                status = "\(error)"; Log.write("START FAILED: \(error)"); retry()
            }
            if token == generation { busy = false }
        }
    }

    private func restoreOrigins() {
        guard !originalOrigins.isEmpty else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for (id, origin) in originalOrigins where CGDisplayIsOnline(id) != 0 {
            CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
        }
        Log.write("restore original origins result=\(CGCompleteDisplayConfiguration(cfg, .forSession).rawValue)")
        originalOrigins = []
    }

    private func stopInternal() {
        recoveryTimer?.invalidate(); recoveryTimer = nil
        previewTimer?.invalidate(); previewTimer = nil; previewSeconds = 0; previousLayout = nil; layoutVerified = false
        identifier.hide(); appBars.setEnabled(false,displays: []); healthBusy = false
        generation += 1; startTask?.cancel(); startTask = nil
        controller.stop(); restoreOrigins(); running = false; busy = false
    }
    func stop() {
        paused = true; stopInternal()
        status = "Stopped. Start again here, or reconnect the dock."
    }
    func shutdown() { stopInternal() }

    func identifyDisplays() {
        guard running else { return }
        identifier.show(displays: controller.layoutDisplays,names: panelNames)
    }
    func savePanelNames(_ names: [String]) {
        guard names.count == 2 else { return }
        panelNames = names.enumerated().map { index,value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "Display \(index+1)" : String(clean.prefix(40))
        }
        controller.panelNames = panelNames
        UserDefaults.standard.set(panelNames,forKey: "panelNames")
    }
    func previewLayout(_ layout: ScreenLayout) throws {
        guard running,previewSeconds == 0 else { throw HubError("Start the screens before changing their layout.") }
        previousLayout = controller.layout
        do { try controller.applyLayout(layout) }
        catch { previousLayout = nil; throw error }
        previewSeconds = 15; layoutVerified = false
        let timer = Timer(timeInterval: 1,repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewSeconds -= 1
                self.layoutVerified = self.controller.layoutIsApplied
                if self.previewSeconds <= 12 && !self.layoutVerified {
                    self.revertLayout()
                    self.status = "macOS did not apply the preview. The previous layout was restored."
                    return
                }
                if self.previewSeconds <= 0 { self.revertLayout() }
            }
        }
        RunLoop.main.add(timer,forMode: .common); previewTimer = timer
    }
    func keepLayout() {
        guard previewSeconds > 0,layoutVerified,let layout = controller.layout else { return }
        previewTimer?.invalidate(); previewTimer = nil; previewSeconds = 0; previousLayout = nil
        controller.savedLayout = layout
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data,forKey: "screenLayout") }
    }
    func revertLayout() {
        previewTimer?.invalidate(); previewTimer = nil; previewSeconds = 0
        let previous = previousLayout; previousLayout = nil
        guard running,let previous else { return }
        do { try controller.applyLayout(previous) }
        catch { status = "Could not restore the layout. Choose Stop, then Start to use the saved layout." }
    }
}

struct Controls: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lenovo Split").font(.title2.bold())
            Text("Two separate screens through a ThinkPad 40AS").foregroundStyle(.secondary)
            Text(model.status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Toggle("Start screens when this dock connects", isOn: $model.autoConnect)
            if !model.permission {
                Text("Screen Recording draws the two virtual screens on the monitors. Frames stay on this Mac.").font(.callout)
                Button("Allow Screen Recording…") { model.requestPermission() }
            }
            HStack {
                Button("Start") { model.start() }.disabled(model.busy || model.running)
                Button("Stop") { model.stop() }.disabled(model.busy || !model.running)
            }
            HStack {
                Button("Identify displays") { model.identifyDisplays() }.disabled(!model.running)
                Button("Arrange displays…") { model.onOpenLayout?() }.disabled(!model.running)
            }
            Divider()
            Toggle("Show an app bar on every display",isOn: $model.showAppBars)
            if model.showAppBars {
                Text("A custom launcher with pinned and running apps. Apple’s Dock settings stay unchanged. Other apps may need resizing to leave room for the bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Keep maximized windows above the Dock", isOn: $model.fitWindows).disabled(!model.windowAccess)
            if !model.windowAccess {
                Text("Window fitting needs Accessibility permission to resize windows in your chosen apps.").font(.caption).foregroundStyle(.secondary)
                Button("Allow window fitting…") { model.requestWindowAccess() }
            }
            Button("Check window permission") { model.refreshWindowAccess() }
            Text("Protected video may appear black. Window fitting applies only to Claude and Grok Bot.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
        }.padding(20).frame(width: 410)
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let model = Model()
    var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusSubscription: AnyCancellable?
    private var layoutWindow: NSWindow?
    private var outsideClick: Any?
    private var localClick: Any?
    private var resignObserver: NSObjectProtocol?
    private var menuPreview: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let preference = "NSStatusItem Preferred Position LenovoSplitStatus"
        if UserDefaults.standard.object(forKey: preference) == nil { UserDefaults.standard.set(0, forKey: preference) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "LenovoSplitStatus"
        item.behavior = []; item.isVisible = true
        if let button = item.button {
            button.title = "Split"
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Lenovo Split")
            button.imagePosition = .imageLeading
            button.target = self; button.action = #selector(togglePopover)
        }
        statusItem = item
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Controls(model: model))
        model.onOpenLayout = { [weak self] in self?.showLayout() }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,object: NSApp,queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        statusSubscription = model.$status.sink { [weak self] text in self?.statusItem?.button?.toolTip = "Lenovo Split: " + text }
        Log.write("status item created visible=\(item.isVisible) button=\(item.button != nil)")
        Log.write("launched menu-bar-only=true autoConnect=\(model.autoConnect) permission=\(model.permission) windowAccess=\(model.windowAccess)")
        if !CommandLine.arguments.contains("--background") { showControls() }
        // A foreground launch mode for testing the real menu panel without
        // relying on the position of a status item hidden by a camera notch.
        if CommandLine.arguments.contains("--show-menu") {
            menuPreview = model.$running.filter { $0 }.first().sink { [weak self] _ in
                DispatchQueue.main.async { self?.togglePopover() }
            }
        }
    }
    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func popoverDidShow(_ notification: Notification) {
        stopClickMonitors()
        // Clicks only, installed only while the panel is open. Never record
        // event data or intercept input to another app.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.popover.contentViewController?.view.window && event.window !== self.statusItem?.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }
        Log.write("menu panel opened")
    }
    func popoverDidClose(_ notification: Notification) {
        stopClickMonitors(); Log.write("menu panel closed")
    }
    private func stopClickMonitors() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }; outsideClick = nil
        if let localClick { NSEvent.removeMonitor(localClick) }; localClick = nil
    }
    private func showLayout() {
        popover.performClose(nil)
        if layoutWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LayoutEditor(model: model)))
            window.title = "Arrange displays — Lenovo Split"
            window.styleMask = [.titled,.closable]; window.isReleasedWhenClosed = false
            window.delegate = self; window.center(); layoutWindow = window
        } else {
            layoutWindow?.contentViewController = NSHostingController(rootView: LayoutEditor(model: model))
        }
        layoutWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow,closed === layoutWindow { model.revertLayout() }
    }
    func showControls() {
        popover.performClose(nil)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Controls(model: model)))
            w.title = "Lenovo Split"; w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        stopClickMonitors()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        model.shutdown()
    }
}

@main
enum LenovoSplitMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
