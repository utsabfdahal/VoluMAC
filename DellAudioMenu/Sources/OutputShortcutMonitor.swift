import Carbon
import Foundation

private func outputShortcutEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let monitor = Unmanaged<OutputShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
    return monitor.receive(identifier, eventKind: GetEventKind(event))
        ? noErr
        : OSStatus(eventNotHandledErr)
}

final class OutputShortcutMonitor {
    static let displayName = "⌃⌥S"

    fileprivate static let identifier = EventHotKeyID(
        signature: OSType(0x564D_4143), // "VMAC"
        id: 1
    )

    var onToggle: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isPressed = false
    private var releaseToken: UInt64 = 0

    private static let releaseQuietPeriod: TimeInterval = 0.2

    var isActive: Bool {
        hotKey != nil && eventHandler != nil
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        precondition(Thread.isMainThread)
        if isActive { return true }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        var newHandler: EventHandlerRef?
        let handlerStatus = eventTypes.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                outputShortcutEventHandler,
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &newHandler
            )
        }
        guard handlerStatus == noErr, let newHandler else { return false }
        eventHandler = newHandler

        var newHotKey: EventHotKeyRef?
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(controlKey | optionKey),
            Self.identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &newHotKey
        )
        guard hotKeyStatus == noErr, let newHotKey else {
            RemoveEventHandler(newHandler)
            eventHandler = nil
            return false
        }

        hotKey = newHotKey
        return true
    }

    func stop() {
        releaseNow()
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func receive(_ identifier: EventHotKeyID, eventKind: UInt32) -> Bool {
        guard identifier.signature == Self.identifier.signature,
              identifier.id == Self.identifier.id else { return false }

        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            releaseToken &+= 1
            guard !isPressed else { return true }
            isPressed = true
            onToggle?()
        case UInt32(kEventHotKeyReleased):
            scheduleRelease()
        default:
            return false
        }
        return true
    }

    static func runRepeatSuppressionSelfTest() -> Bool {
        let monitor = OutputShortcutMonitor()
        var toggleCount = 0
        monitor.onToggle = { toggleCount += 1 }

        let firstPress = monitor.receive(Self.identifier, eventKind: UInt32(kEventHotKeyPressed))
        let repeatRelease = monitor.receive(Self.identifier, eventKind: UInt32(kEventHotKeyReleased))
        let repeatedPress = monitor.receive(Self.identifier, eventKind: UInt32(kEventHotKeyPressed))
        let finalRelease = monitor.receive(Self.identifier, eventKind: UInt32(kEventHotKeyReleased))
        monitor.releaseNow()
        let secondPress = monitor.receive(Self.identifier, eventKind: UInt32(kEventHotKeyPressed))

        return firstPress && repeatRelease && repeatedPress && finalRelease
            && secondPress && toggleCount == 2
    }

    private func scheduleRelease() {
        releaseToken &+= 1
        let token = releaseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseQuietPeriod) { [weak self] in
            guard let self, self.releaseToken == token else { return }
            self.isPressed = false
        }
    }

    private func releaseNow() {
        releaseToken &+= 1
        isPressed = false
    }
}
