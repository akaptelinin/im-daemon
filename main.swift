import Foundation
import Carbon
import CoreGraphics

let socketPath = "\(NSHomeDirectory())/.local/run/im-daemon.sock"
var subscribers: [Int32] = []
var subscribersLock = NSLock()
var lastLayout = ""

func getCurrentLayout() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
          let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String? else {
        return "unknown"
    }
    return id
}

func setLayout(_ layoutId: String) -> Bool {
    let filter = [kTISPropertyInputSourceID: layoutId] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let source = sources.first else {
        return false
    }
    return TISSelectInputSource(source) == noErr
}

func notifySubscribers() {
    let layout = getCurrentLayout()
    guard layout != lastLayout else { return }
    lastLayout = layout

    subscribersLock.lock()
    var deadFds: [Int32] = []
    for fd in subscribers {
        let msg = layout + "\n"
        let written = msg.withCString { write(fd, $0, strlen($0)) }
        if written <= 0 { deadFds.append(fd) }
    }
    for fd in deadFds {
        close(fd)
        subscribers.removeAll { $0 == fd }
    }
    subscribersLock.unlock()
}

func setupEventTap() -> Bool {
    let eventMask = (1 << CGEventType.flagsChanged.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(eventMask),
        callback: { _, _, event, _ in
            DispatchQueue.main.async {
                notifySubscribers()
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else {
        fputs("Failed to create event tap. Need Accessibility permissions.\n", stderr)
        return false
    }

    let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    fputs("CGEventTap enabled\n", stderr)
    return true
}

class KeyboardObserver: NSObject {
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(keyboardLayoutChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }
    @objc func keyboardLayoutChanged(_ n: Notification) {
        notifySubscribers()
    }
}

signal(SIGPIPE, SIG_IGN)

let runDir = "\(NSHomeDirectory())/.local/run"
try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(atPath: socketPath)

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
socketPath.withCString { ptr in
    withUnsafeMutablePointer(to: &addr.sun_path.0) { _ = strcpy($0, ptr) }
}

let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFd >= 0 else {
    fputs("Failed to create socket\n", stderr)
    exit(1)
}

let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else {
    fputs("Failed to bind: \(errno)\n", stderr)
    exit(1)
}
guard listen(serverFd, 10) == 0 else {
    fputs("Failed to listen\n", stderr)
    exit(1)
}

fputs("Listening on \(socketPath)\n", stderr)

let observer = KeyboardObserver()

// Try CGEventTap first (faster), fallback to DistributedNotificationCenter
if !setupEventTap() {
    fputs("Falling back to DistributedNotificationCenter\n", stderr)
}

DispatchQueue.global().async {
    while true {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFd, $0, &clientLen)
            }
        }
        guard clientFd >= 0 else { continue }

        var buffer = [CChar](repeating: 0, count: 256)
        let n = read(clientFd, &buffer, 255)
        if n <= 0 { close(clientFd); continue }

        let cmd = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)

        if cmd == "get" {
            let layout = getCurrentLayout()
            layout.withCString { _ = write(clientFd, $0, strlen($0)) }
            close(clientFd)
        } else if cmd.hasPrefix("set ") {
            let layoutId = String(cmd.dropFirst(4))
            let response = setLayout(layoutId) ? "ok" : "error"
            response.withCString { _ = write(clientFd, $0, strlen($0)) }
            close(clientFd)
        } else if cmd == "subscribe" {
            let layout = getCurrentLayout() + "\n"
            layout.withCString { _ = write(clientFd, $0, strlen($0)) }
            subscribersLock.lock()
            subscribers.append(clientFd)
            subscribersLock.unlock()
        } else {
            "error: unknown command".withCString { _ = write(clientFd, $0, strlen($0)) }
            close(clientFd)
        }
    }
}

withExtendedLifetime(observer) {
    RunLoop.main.run()
}
