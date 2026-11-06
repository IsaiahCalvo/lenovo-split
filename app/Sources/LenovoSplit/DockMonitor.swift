import AppKit
import CoreGraphics
import IOKit
import LenovoDock

/// Native USB/display notifications; no timers while the setup is healthy.
@MainActor
final class DockMonitor {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    private var wake: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        self.changed = changed
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let p = IONotificationPortCreate(kIOMainPortDefault) {
            port = p
            if let source = IONotificationPortGetRunLoopSource(p)?.takeUnretainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            let callback: IOServiceMatchingCallback = { context, iterator in
                var relevant = false
                while true {
                    let service = IOIteratorNext(iterator)
                    if service == 0 { break }
                    func value(_ key: String) -> Int? {
                        IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() as? Int
                    }
                    if value("idVendor") == 0x17ef && value("idProduct") == 0xa38f { relevant = true }
                    IOObjectRelease(service)
                }
                if relevant, let context {
                    let monitor = Unmanaged<DockMonitor>.fromOpaque(context).takeUnretainedValue()
                    DispatchQueue.main.async { monitor.schedule() }
                }
            }
            if IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), callback, context, &added) == KERN_SUCCESS { callback(context, added) }
            if IOServiceAddMatchingNotification(p, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), callback, context, &removed) == KERN_SUCCESS { callback(context, removed) }
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let monitor = Unmanaged<DockMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.schedule() }
        }, context)
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedule() }
        }
        schedule()
    }

    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.changed() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}
