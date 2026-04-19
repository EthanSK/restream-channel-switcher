// usb-watcher: native macOS daemon that watches for USB device attach and
// display reconfiguration events, and shells out to the restream-profile CLI
// when matching events occur.
//
// Build:
//   swiftc -O -o usb-watcher main.swift -framework IOKit -framework CoreFoundation
//
// Config: ~/.config/restream-profile/watcher.json
//   {
//     "restream_profile_cli": "/abs/path/to/restream-profile.py",
//     "triggers": [
//       {"on": "usb_attach",     "vendor_id": "0x1234", "product_id": "0x5678", "profile": "wreathen"},
//       {"on": "display_attach", "profile": "3000ad"}
//     ]
//   }
//
// Logs to stderr (captured by launchd into ~/Library/Logs/restream-profile-auto.log).

import Foundation
import IOKit
import IOKit.usb
import CoreGraphics

// MARK: - Config

struct Trigger: Decodable {
    let on: String                 // "usb_attach" | "usb_detach" | "display_attach" | "display_detach"
    let vendorId: String?          // hex string, e.g. "0x1234"
    let productId: String?         // hex string, e.g. "0x5678"
    let profile: String            // passed to restream-profile --profile

    enum CodingKeys: String, CodingKey {
        case on
        case vendorId = "vendor_id"
        case productId = "product_id"
        case profile
    }
}

struct Config: Decodable {
    let restreamProfileCli: String
    let triggers: [Trigger]

    enum CodingKeys: String, CodingKey {
        case restreamProfileCli = "restream_profile_cli"
        case triggers
    }
}

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

func loadConfig() -> Config {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let path = home.appendingPathComponent(".config/restream-profile/watcher.json")
    guard let data = try? Data(contentsOf: path) else {
        log("FATAL: cannot read config at \(path.path)")
        exit(1)
    }
    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        log("FATAL: bad config JSON: \(error)")
        exit(1)
    }
}

func hexToInt(_ s: String?) -> Int? {
    guard let s = s else { return nil }
    var t = s
    if t.hasPrefix("0x") || t.hasPrefix("0X") { t = String(t.dropFirst(2)) }
    return Int(t, radix: 16)
}

// MARK: - Action

func fireTrigger(config: Config, trigger: Trigger, reason: String) {
    log("Firing trigger reason=\(reason) profile=\(trigger.profile)")
    let task = Process()
    task.launchPath = "/usr/bin/env"
    task.arguments = ["python3", config.restreamProfileCli, "--profile", trigger.profile]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8), !out.isEmpty {
            log("CLI output: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        log("CLI exit code: \(task.terminationStatus)")
    } catch {
        log("ERROR: failed to exec CLI: \(error)")
    }
}

// MARK: - USB watcher

class USBWatcher {
    let config: Config
    var notifyPort: IONotificationPortRef
    var addedIterator: io_iterator_t = 0
    var removedIterator: io_iterator_t = 0

    init(config: Config) {
        self.config = config
        self.notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }

    func start() {
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        // Retain for second call — IOServiceAddMatchingNotification consumes one ref.
        let addedDict = matchingDict.copy() as! NSMutableDictionary
        let removedDict = matchingDict.copy() as! NSMutableDictionary

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Attach
        let addedResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOMatchedNotification,
            addedDict,
            { (userData, iterator) in
                let watcher = Unmanaged<USBWatcher>.fromOpaque(userData!).takeUnretainedValue()
                watcher.handleUSBEvent(iterator: iterator, eventType: "usb_attach")
            },
            selfPtr,
            &addedIterator
        )
        if addedResult != KERN_SUCCESS {
            log("ERROR: IOServiceAddMatchingNotification (added) failed: \(addedResult)")
        }
        // Drain initial iteration (devices already attached at startup)
        drainIterator(addedIterator, fireEvents: false)

        // Detach
        let removedResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            removedDict,
            { (userData, iterator) in
                let watcher = Unmanaged<USBWatcher>.fromOpaque(userData!).takeUnretainedValue()
                watcher.handleUSBEvent(iterator: iterator, eventType: "usb_detach")
            },
            selfPtr,
            &removedIterator
        )
        if removedResult != KERN_SUCCESS {
            log("ERROR: IOServiceAddMatchingNotification (removed) failed: \(removedResult)")
        }
        drainIterator(removedIterator, fireEvents: false)

        log("USB watcher armed")
    }

    private func drainIterator(_ iterator: io_iterator_t, fireEvents: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if fireEvents {
                processService(service, eventType: "usb_attach")
            }
            IOObjectRelease(service)
        }
    }

    func handleUSBEvent(iterator: io_iterator_t, eventType: String) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            processService(service, eventType: eventType)
            IOObjectRelease(service)
        }
    }

    private func processService(_ service: io_service_t, eventType: String) {
        let vendorRef = IORegistryEntryCreateCFProperty(
            service, "idVendor" as CFString, kCFAllocatorDefault, 0
        )
        let productRef = IORegistryEntryCreateCFProperty(
            service, "idProduct" as CFString, kCFAllocatorDefault, 0
        )
        let nameRef = IORegistryEntryCreateCFProperty(
            service, "USB Product Name" as CFString, kCFAllocatorDefault, 0
        )

        let vid = (vendorRef?.takeRetainedValue() as? Int) ?? -1
        let pid = (productRef?.takeRetainedValue() as? Int) ?? -1
        let name = (nameRef?.takeRetainedValue() as? String) ?? "(unknown)"

        log("USB \(eventType): name=\(name) vid=\(String(format: "0x%04x", vid)) pid=\(String(format: "0x%04x", pid))")

        for trigger in config.triggers where trigger.on == eventType {
            let wantVid = hexToInt(trigger.vendorId)
            let wantPid = hexToInt(trigger.productId)
            if let wv = wantVid, wv != vid { continue }
            if let wp = wantPid, wp != pid { continue }
            fireTrigger(config: config, trigger: trigger, reason: "\(eventType) \(name)")
        }
    }
}

// MARK: - Display watcher

var globalConfig: Config!

func displayCallback(display: CGDirectDisplayID,
                     flags: CGDisplayChangeSummaryFlags,
                     userInfo: UnsafeMutableRawPointer?) {
    let attached = flags.contains(.addFlag)
    let detached = flags.contains(.removeFlag)
    if !attached && !detached { return }  // ignore other reconfiguration flags

    let eventType = attached ? "display_attach" : "display_detach"
    log("Display \(eventType): display_id=\(display)")

    for trigger in globalConfig.triggers where trigger.on == eventType {
        fireTrigger(config: globalConfig, trigger: trigger, reason: "\(eventType) id=\(display)")
    }
}

// MARK: - Main

let config = loadConfig()
globalConfig = config
log("Loaded config: cli=\(config.restreamProfileCli) triggers=\(config.triggers.count)")

let usbWatcher = USBWatcher(config: config)
usbWatcher.start()

let displayRegistered = CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
if displayRegistered != .success {
    log("ERROR: CGDisplayRegisterReconfigurationCallback failed: \(displayRegistered.rawValue)")
} else {
    log("Display watcher armed")
}

// Handle SIGTERM cleanly
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    log("SIGTERM received, exiting")
    exit(0)
}
sigtermSource.resume()
signal(SIGTERM, SIG_IGN)

log("Entering run loop")
CFRunLoopRun()
