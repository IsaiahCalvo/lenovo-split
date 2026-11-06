import AppKit
import SwiftUI
import Combine
import LenovoDock
import DisplayLayout
import WindowFocus
import Darwin

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
        didSet {
            controller.swapSides = swap; UserDefaults.standard.set(swap, forKey: "swap")
            if identifier.isShowing { identifyDisplays() }
            updateRecoveryContext(restore: false); windowRecovery.remember(force: true)
        }
    }
    @Published var windowAccess = WindowFitter.trusted
    @Published var fitWindows = UserDefaults.standard.bool(forKey: "fitWindows") {
        didSet {
            UserDefaults.standard.set(fitWindows, forKey: "fitWindows")
            fitter.setEnabled(fitWindows && windowAccess)
        }
    }
    private let fitter = WindowFitter()
    private let windowRecovery = WindowRecovery()
    @Published var keepWindowsVisible = UserDefaults.standard.object(forKey: "keepWindowsVisible") == nil ? true : UserDefaults.standard.bool(forKey: "keepWindowsVisible") {
        didSet {
            UserDefaults.standard.set(keepWindowsVisible,forKey: "keepWindowsVisible")
            windowRecovery.setEnabled(keepWindowsVisible && windowAccess)
            updateRecoveryContext(restore: running)
        }
    }
    private let dockClick = NativeDockClick()
    @Published private(set) var dockClickStarted = false
    @Published var dockClickToMinimize = UserDefaults.standard.bool(forKey: "dockClickToMinimize") {
        didSet {
            UserDefaults.standard.set(dockClickToMinimize,forKey: "dockClickToMinimize")
            dockClick.setEnabled(dockClickToMinimize && windowAccess)
            dockClickStarted = dockClick.isRunning
        }
    }
    private let hoverRaise = HoverRaise()
    @Published private(set) var hoverRaiseStatus = "Off"
    @Published var hoverRaiseEnabled = UserDefaults.standard.bool(forKey: "hoverRaiseEnabled") {
        didSet {
            UserDefaults.standard.set(hoverRaiseEnabled,forKey: "hoverRaiseEnabled")
            hoverRaise.setEnabled(hoverRaiseEnabled)
        }
    }
    @Published var hoverRaiseDelay = UserDefaults.standard.object(forKey: "hoverRaiseDelay") as? Double ?? 0.5 {
        didSet {
            let safe = min(2,max(0.2,hoverRaiseDelay.isFinite ? hoverRaiseDelay : 0.5))
            UserDefaults.standard.set(safe,forKey: "hoverRaiseDelay"); hoverRaise.delay = safe
        }
    }
    @Published private(set) var physicalOutputNames = ["Display 1", "Display 2"]
    var panelNames: [String] { PanelAssignment(outputNames: physicalOutputNames).panelNames(swapped: swap) }
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
        UserDefaults.standard.register(defaults: ["fitAppIDs": ["com.anthropic.claudefordesktop", "com.anysphere.sand"]])
        controller.swapSides = swap
        if let names = UserDefaults.standard.stringArray(forKey: "physicalOutputNames"),names.count == 2 {
            physicalOutputNames = names
        } else if let legacy = UserDefaults.standard.stringArray(forKey: "panelNames"),legacy.count == 2 {
            physicalOutputNames = PanelAssignment.fromPanelNames(legacy,swapped: swap).outputNames
            UserDefaults.standard.set(physicalOutputNames,forKey: "physicalOutputNames")
        }
        if let data = UserDefaults.standard.data(forKey: "screenLayout") {
            controller.savedLayout = try? JSONDecoder().decode(ScreenLayout.self,from: data)
        }
        fitter.allowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: "fitAppIDs") ?? [])
        fitter.isRunning = { [weak self] in self?.running == true }
        fitter.setEnabled(fitWindows && windowAccess)
        dockClick.setEnabled(dockClickToMinimize && windowAccess)
        dockClickStarted = dockClick.isRunning
        windowRecovery.setEnabled(keepWindowsVisible && windowAccess)
        dockClick.recoverWindows = { [weak self] pid in self?.windowRecovery.revealIfNeeded(pid: pid) ?? false }
        hoverRaise.delay = min(2,max(0.2,hoverRaiseDelay.isFinite ? hoverRaiseDelay : 0.5))
        hoverRaise.onStatus = { [weak self] in self?.hoverRaiseStatus = $0 }
        hoverRaise.isBlocked = { [weak self] in self == nil || self?.busy == true || (self?.previewSeconds ?? 0)>0 }
        hoverRaise.setEnabled(hoverRaiseEnabled)
        monitor = DockMonitor { [weak self] in self?.dockChanged() }
    }

    func requestWindowAccess() {
        WindowFitter.requestPermission()
        status = "Allow Accessibility for Lenovo Split, then choose Check Accessibility."
    }
    func refreshWindowAccess() {
        windowAccess = WindowFitter.trusted
        fitter.allowedBundleIDs = Set(UserDefaults.standard.stringArray(forKey: "fitAppIDs") ?? [])
        fitter.setEnabled(fitWindows && windowAccess)
        dockClick.setEnabled(dockClickToMinimize && windowAccess)
        dockClickStarted = dockClick.isRunning
        windowRecovery.setEnabled(keepWindowsVisible && windowAccess)
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
        windowRecovery.pause()
        let token = generation
        startTask = Task {
            do {
                try await controller.start(physical: physical, wide: wide)
                try Task.checkCancellation()
                guard token == generation else { return }
                running = true; attempts = 0; healthFailures = 0
                updateRecoveryContext(restore: true)
                status = "Two separate screens connected."
                scheduleCheck(after: 10)
                Log.write("STARTED panels=\(controller.panelIDs) frames=\(controller.frameCounts)")
            } catch {
                guard token == generation else { return }
                controller.stop(); restoreOrigins()
                updateRecoveryContext(restore: false)
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
        windowRecovery.remember(force: true)
        recoveryTimer?.invalidate(); recoveryTimer = nil
        previewTimer?.invalidate(); previewTimer = nil; previewSeconds = 0; previousLayout = nil; layoutVerified = false
        identifier.hide(); healthBusy = false
        generation += 1; startTask?.cancel(); startTask = nil
        controller.stop(); restoreOrigins(); running = false; busy = false
        updateRecoveryContext(restore: false)
    }
    func stop() {
        paused = true; stopInternal()
        status = "Stopped. Start again here, or reconnect the dock."
    }
    func shutdown() { hoverRaise.setEnabled(false); dockClick.setEnabled(false); stopInternal(); windowRecovery.setEnabled(false) }

    private func updateRecoveryContext(restore: Bool) {
        var mapping: [CGDirectDisplayID:String] = [:]
        if running {
            for (index,id) in controller.panelIDs.enumerated() { mapping[id] = "output\(swap ? 1-index : index)" }
        }
        windowRecovery.configure(hidden: running ? controller.physicalDisplayID : nil,panelKeys: mapping,restore: restore)
    }

    func identifyDisplays() {
        guard running else { return }
        identifier.show(displays: controller.layoutDisplays,names: panelNames)
    }
    func recoverWindowsNow() { windowRecovery.recover(pid: nil,restoreSaved: false) }
    func savePanelNames(_ names: [String]) {
        guard names.count == 2 else { return }
        let cleaned = names.enumerated().map { index,value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "Display \(index+1)" : String(clean.prefix(40))
        }
        physicalOutputNames = PanelAssignment.fromPanelNames(cleaned,swapped: swap).outputNames
        UserDefaults.standard.set(physicalOutputNames,forKey: "physicalOutputNames")
        if identifier.isShowing { identifyDisplays() }
    }
    func previewLayout(_ layout: ScreenLayout) throws {
        guard running,previewSeconds == 0 else { throw HubError("Start the screens before changing their layout.") }
        previousLayout = controller.layout
        windowRecovery.pause()
        do { try controller.applyLayout(layout) }
        catch { previousLayout = nil; updateRecoveryContext(restore: false); throw error }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { [weak self] in self?.updateRecoveryContext(restore: false) }
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
        windowRecovery.pause()
        do { try controller.applyLayout(previous) }
        catch { status = "Could not restore the layout. Choose Stop, then Start to use the saved layout." }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.5) { [weak self] in self?.updateRecoveryContext(restore: false) }
    }
}

struct Controls: View {
    @ObservedObject var model: Model
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
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
            Toggle("Keep windows on visible screens",isOn: $model.keepWindowsVisible).disabled(!model.windowAccess)
            Text("Remember external window positions on unplug. Recover windows from the hidden output when reconnecting or opening an app.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Recover windows now") { model.recoverWindowsNow() }.disabled(!model.keepWindowsVisible || !model.windowAccess)
            Divider()
            Text("Native macOS Dock").font(.headline)
            Toggle("Click an active app’s Dock icon to minimize",isOn: $model.dockClickToMinimize).disabled(!model.windowAccess)
            Text("Click again to restore its windows. Runs inside Lenovo Split and works with Apple’s Dock.")
                .font(.caption).foregroundStyle(.secondary)
            if model.dockClickToMinimize && !model.dockClickStarted {
                Text("Dock clicks could not start. Check Accessibility permission, then retry below.").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Toggle("Raise windows on hover",isOn: $model.hoverRaiseEnabled)
            if model.hoverRaiseEnabled {
                Picker("Hover delay",selection: $model.hoverRaiseDelay) {
                    Text("0.25 seconds").tag(0.25)
                    Text("0.5 seconds").tag(0.5)
                    Text("0.75 seconds").tag(0.75)
                    Text("1 second").tag(1.0)
                }
                Text(model.hoverRaiseStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("Focus and raise a window after the pointer rests on it. Pauses while standalone AutoRaise runs. Hold Control to pause.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
            Toggle("Keep maximized windows above the Dock", isOn: $model.fitWindows).disabled(!model.windowAccess)
            if !model.windowAccess {
                Text("These optional features need Accessibility to focus, minimize or resize windows.").font(.caption).foregroundStyle(.secondary)
                Button("Allow Accessibility…") { model.requestWindowAccess() }
            }
            Button("Check Accessibility permission") { model.refreshWindowAccess() }
            Text("Protected video may appear black. Window fitting applies only to Claude and Grok Bot.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
        }.padding(20) }.frame(width: 450,height: 700)
    }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = Model()
    var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var statusSubscription: AnyCancellable?
    private var layoutWindow: NSWindow?
    private var menuPreview: AnyCancellable?
    private var reopenObserver: NSObjectProtocol?
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
        }
        statusItem = item
        menu.delegate = self; menu.autoenablesItems = false
        item.menu = menu
        model.onOpenLayout = { [weak self] in self?.showLayout() }
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: .init("local.lenovosplit.reopen"),object: nil,queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showControls() }
        }
        statusSubscription = model.$status.sink { [weak self] text in self?.statusItem?.button?.toolTip = "Lenovo Split: " + text }
        Log.write("status item created visible=\(item.isVisible) button=\(item.button != nil)")
        Log.write("launched menu-bar-only=true autoConnect=\(model.autoConnect) permission=\(model.permission) windowAccess=\(model.windowAccess)")
        if !CommandLine.arguments.contains("--background") { showControls() }
        // A foreground launch mode for testing the real menu panel without
        // relying on the position of a status item hidden by a camera notch.
        if CommandLine.arguments.contains("--show-menu") {
            menuPreview = model.$running.filter { $0 }.first().sink { [weak self] _ in
                DispatchQueue.main.async { self?.statusItem?.button?.performClick(nil) }
            }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String,_ action: Selector?,enabled: Bool = true,checked: Bool? = nil) {
            let item = NSMenuItem(title: title,action: action,keyEquivalent: "")
            item.target = self; item.isEnabled = enabled
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item)
        }
        let state = model.running ? "Two separate displays connected" :
            (model.busy ? "Starting screens…" : (model.connected ? "Waiting for both dock outputs" : "Dock disconnected"))
        add(state,nil,enabled: false)
        menu.addItem(.separator())
        add("Start when this dock connects",#selector(toggleAutoConnect),checked: model.autoConnect)
        add(model.running ? "Stop screens" : "Start screens",#selector(toggleScreens),enabled: !model.busy)
        menu.addItem(.separator())
        add("Identify displays",#selector(identifyScreens),enabled: model.running)
        add("Arrange displays…",#selector(openLayout),enabled: model.running)
        add("Keep windows on visible screens",#selector(toggleWindowRecovery),enabled: model.windowAccess,checked: model.keepWindowsVisible)
        add("Recover windows now",#selector(recoverWindows),enabled: model.windowAccess && model.keepWindowsVisible)
        menu.addItem(.separator())
        add("Click active Dock icon to minimize",#selector(toggleDockClick),enabled: model.windowAccess,checked: model.dockClickToMinimize)
        add("Raise windows on hover",#selector(toggleHoverRaise),checked: model.hoverRaiseEnabled)
        if model.hoverRaiseEnabled { add(model.hoverRaiseStatus,nil,enabled: false) }
        add("Keep large windows above the Dock",#selector(toggleWindowFit),enabled: model.windowAccess,checked: model.fitWindows)
        menu.addItem(.separator())
        add("Settings…",#selector(openSettings))
        add("Quit Lenovo Split",#selector(quitApp))
    }
    func menuWillOpen(_ menu: NSMenu) { Log.write("menu opened") }
    func menuDidClose(_ menu: NSMenu) { Log.write("menu closed") }
    @objc private func toggleAutoConnect() { model.autoConnect.toggle() }
    @objc private func toggleScreens() { if model.running { model.stop() } else { model.start() } }
    @objc private func identifyScreens() { model.identifyDisplays() }
    @objc private func openLayout() { showLayout() }
    @objc private func toggleDockClick() { model.dockClickToMinimize.toggle() }
    @objc private func toggleWindowRecovery() { model.keepWindowsVisible.toggle() }
    @objc private func recoverWindows() { model.recoverWindowsNow() }
    @objc private func toggleHoverRaise() { model.hoverRaiseEnabled.toggle() }
    @objc private func toggleWindowFit() { model.fitWindows.toggle() }
    @objc private func openSettings() { showControls() }
    @objc private func quitApp() { model.shutdown(); NSApp.terminate(nil) }
    private func showLayout() {
        menu.cancelTracking()
        if layoutWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LayoutEditor(model: model)))
            window.title = "Arrange displays — Lenovo Split"
            window.styleMask = [.titled,.closable]; window.isReleasedWhenClosed = false
            window.delegate = self; window.center(); layoutWindow = window
        } else {
            layoutWindow?.contentViewController = NSHostingController(rootView: LayoutEditor(model: model))
        }
        if let layoutWindow { keepOwnWindowVisible(layoutWindow); layoutWindow.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow,closed === layoutWindow { model.revertLayout() }
    }
    func showControls() {
        menu.cancelTracking()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Controls(model: model)))
            w.title = "Lenovo Split"; w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false; w.center(); window = w
        }
        if let window { keepOwnWindowVisible(window); window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }
    private func keepOwnWindowVisible(_ window: NSWindow) {
        let ids = Set(model.controller.layoutDisplays.map(\.1))
        let screens = NSScreen.screens.filter { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return model.running ? ids.contains(id) : CGDisplayVendorNumber(id) != DisplayModes.virtualVendorID
        }
        let title = CGRect(x: window.frame.minX,y: window.frame.maxY-32,width: window.frame.width,height: 32)
        guard !screens.contains(where: { $0.visibleFrame.intersection(title).width>100 }),let target = screens.first else { return }
        window.setFrameOrigin(CGPoint(x: target.visibleFrame.midX-window.frame.width/2,y: target.visibleFrame.midY-window.frame.height/2))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        menu.cancelTracking()
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
        model.shutdown()
    }
}

@main
enum LenovoSplitMain {
    @MainActor static func main() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("LenovoSplit.lock").path
        let lock = open(path,O_CREAT | O_RDWR | O_NOFOLLOW,S_IRUSR | S_IWUSR)
        guard lock >= 0 else { Log.write("Could not open the single-instance lock; refusing a second display controller."); return }
        guard flock(lock,LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            if !CommandLine.arguments.contains("--background") {
                DistributedNotificationCenter.default().postNotificationName(.init("local.lenovosplit.reopen"),object: nil,userInfo: nil,deliverImmediately: true)
            }
            return
        }
        defer { close(lock) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
