import AppKit
import CoreGraphics
import Foundation

private let systemDefinedEventType = CGEventType(rawValue: 14)!

enum MediaKeyCommand: Equatable {
    case mute
    case volumeDown
    case volumeUp
}

struct MediaKeyAction: Equatable {
    let command: MediaKeyCommand
    let fineAdjustment: Bool
}

private func voluMACMediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class MediaKeyMonitor {
    var onAction: ((MediaKeyAction) -> Void)?
    var onStatusChange: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastAction: MediaKeyAction?
    private var lastEventType: CGEventType?
    private var lastActionTime: TimeInterval = 0
    private var tapStartedAt: TimeInterval = 0
    private var pendingRestart: DispatchWorkItem?

    private(set) var generation: UInt64 = 0

    private static let maximumTapAge: TimeInterval = 6 * 60 * 60

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            lifecycleObservers.append(
                center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.scheduleRestart(after: 0.75)
                }
            )
        }
    }

    deinit {
        pendingRestart?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.forEach(center.removeObserver)
    }

    var isActive: Bool {
        guard let eventTap else { return false }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }
    var hasPermission: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    func start(requestPermission: Bool) -> Bool {
        if isActive { return true }
        guard hasPermission else {
            if requestPermission { _ = CGRequestListenEventAccess() }
            onStatusChange?(false)
            return false
        }

        let eventMask = (CGEventMask(1) << systemDefinedEventType.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: voluMACMediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            onStatusChange?(false)
            return false
        }

        eventTap = tap
        runLoopSource = source
        tapStartedAt = ProcessInfo.processInfo.systemUptime
        generation &+= 1
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onStatusChange?(true)
        return true
    }

    func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        tapStartedAt = 0
        onStatusChange?(false)
    }

    @discardableResult
    func maintain() -> Bool {
        precondition(Thread.isMainThread)
        let age = ProcessInfo.processInfo.systemUptime - tapStartedAt
        if !isActive || age >= Self.maximumTapAge {
            restart()
        }
        return isActive
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            scheduleRestart(after: 0.1)
            return
        }

        guard let action = Self.decode(type: type, event: event) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastActionTime
        if action == lastAction,
           let lastEventType,
           ((type != lastEventType && elapsed < 0.25)
            || (type == lastEventType && elapsed < 0.02)) {
            return
        }
        lastAction = action
        lastEventType = type
        lastActionTime = now
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }

    private func scheduleRestart(after delay: TimeInterval) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restart() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func restart() {
        precondition(Thread.isMainThread)
        pendingRestart?.cancel()
        pendingRestart = nil
        let permitted = hasPermission
        stop()
        if permitted {
            _ = start(requestPermission: false)
        }
    }

    private static func decode(type: CGEventType, event: CGEvent) -> MediaKeyAction? {
        let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
        if type == systemDefinedEventType,
           let appKitEvent = NSEvent(cgEvent: event),
           appKitEvent.subtype.rawValue == 8 {
            return decodeSystemDefined(data1: appKitEvent.data1, fineAdjustment: fine)
        }
        if type == .keyDown {
            let forbidden = event.flags.intersection([.maskCommand, .maskControl])
            guard forbidden.isEmpty else { return nil }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            return decodeKeyCode(keyCode, fineAdjustment: fine)
        }
        return nil
    }

    static func decodeSystemDefined(
        data1: Int,
        fineAdjustment: Bool = false
    ) -> MediaKeyAction? {
        let keyCode = (data1 & 0xffff0000) >> 16
        let keyFlags = data1 & 0x0000ffff
        let keyState = (keyFlags & 0xff00) >> 8
        guard keyState == 0x0a else { return nil }

        let command: MediaKeyCommand
        switch keyCode {
        case 0: command = .volumeUp
        case 1: command = .volumeDown
        case 7: command = .mute
        default: return nil
        }
        return MediaKeyAction(command: command, fineAdjustment: fineAdjustment)
    }

    static func decodeKeyCode(
        _ keyCode: Int64,
        fineAdjustment: Bool = false
    ) -> MediaKeyAction? {
        let command: MediaKeyCommand
        switch keyCode {
        case 0x6d: command = .mute
        case 0x67: command = .volumeDown
        case 0x6f: command = .volumeUp
        default: return nil
        }
        return MediaKeyAction(command: command, fineAdjustment: fineAdjustment)
    }

    static func runDecodeSelfTest() -> Bool {
        let downState = 0x0a00
        let cases: [(MediaKeyAction?, MediaKeyAction)] = [
            (decodeSystemDefined(data1: (7 << 16) | downState), .init(command: .mute, fineAdjustment: false)),
            (decodeSystemDefined(data1: (1 << 16) | downState), .init(command: .volumeDown, fineAdjustment: false)),
            (decodeSystemDefined(data1: (0 << 16) | downState), .init(command: .volumeUp, fineAdjustment: false)),
            (decodeKeyCode(0x6d), .init(command: .mute, fineAdjustment: false)),
            (decodeKeyCode(0x67), .init(command: .volumeDown, fineAdjustment: false)),
            (decodeKeyCode(0x6f), .init(command: .volumeUp, fineAdjustment: false)),
            (decodeKeyCode(0x6f, fineAdjustment: true), .init(command: .volumeUp, fineAdjustment: true))
        ]
        return cases.allSatisfy { $0.0 == $0.1 }
    }
}
