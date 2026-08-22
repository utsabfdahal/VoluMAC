import AppKit
import CoreAudio
import SwiftUI

private enum Product {
    static let displayMatch = "DELL"
    static let preferredRate = 48_000.0
}

private enum AudioRouteError: LocalizedError {
    case displayUnavailable
    case builtInUnavailable
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "Dell display audio is not connected."
        case .builtInUnavailable:
            return "MacBook speakers are unavailable."
        case let .coreAudio(operation, status):
            return "\(operation) failed (CoreAudio \(status))."
        }
    }
}

private struct AudioSnapshot {
    let dellDevice: AudioDeviceID?
    let builtInDevice: AudioDeviceID?
    let defaultOutput: AudioDeviceID
    let defaultSystemOutput: AudioDeviceID
    let dellRate: Double?
    let dellUID: String?

    var dellConnected: Bool { dellDevice != nil }
    var dellIsDefault: Bool { dellDevice == defaultOutput }
    var dellHandlesSystemSounds: Bool { dellDevice == defaultSystemOutput }
}

private final class AudioRouter {
    private let system = AudioObjectID(kAudioObjectSystemObject)

    func snapshot() -> AudioSnapshot {
        let devices = allDevices().filter(hasOutput)
        let dell = devices.first {
            deviceName($0).localizedCaseInsensitiveContains(Product.displayMatch)
        }
        let builtIn = devices.first { deviceUID($0) == "BuiltInSpeakerDevice" }
            ?? devices.first { deviceName($0).localizedCaseInsensitiveContains("MacBook") }
        return AudioSnapshot(
            dellDevice: dell,
            builtInDevice: builtIn,
            defaultOutput: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
            defaultSystemOutput: defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice),
            dellRate: dell.map(sampleRate),
            dellUID: dell.map(deviceUID)
        )
    }

    func selectDell(keep48k: Bool) throws {
        let current = snapshot()
        guard let device = current.dellDevice else { throw AudioRouteError.displayUnavailable }
        if keep48k { try pinDellTo48k(device) }
        try setDefault(device, selector: kAudioHardwarePropertyDefaultOutputDevice, operation: "Selecting Dell output")
        try setDefault(device, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, operation: "Selecting Dell system sounds")
    }

    func selectBuiltIn() throws {
        guard let device = snapshot().builtInDevice else { throw AudioRouteError.builtInUnavailable }
        try setDefault(device, selector: kAudioHardwarePropertyDefaultOutputDevice, operation: "Selecting MacBook output")
        try setDefault(device, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, operation: "Selecting MacBook system sounds")
    }

    func pinDellTo48k() throws {
        guard let device = snapshot().dellDevice else { throw AudioRouteError.displayUnavailable }
        try pinDellTo48k(device)
    }

    private func pinDellTo48k(_ device: AudioDeviceID) throws {
        let current = sampleRate(device)
        guard abs(current - Product.preferredRate) > 1 else { return }
        guard supportsRate(Product.preferredRate, device: device) else {
            throw AudioRouteError.coreAudio("Pinning Dell to 48 kHz", kAudioHardwareUnsupportedOperationError)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Product.preferredRate
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<Double>.size), &rate
        )
        guard status == noErr else { throw AudioRouteError.coreAudio("Pinning Dell to 48 kHz", status) }
    }

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private func stringProperty(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private func deviceName(_ device: AudioDeviceID) -> String {
        stringProperty(device, selector: kAudioObjectPropertyName)
    }

    private func deviceUID(_ device: AudioDeviceID) -> String {
        stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        return device
    }

    private func setDefault(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var selected = device
        let status = AudioObjectSetPropertyData(
            system, &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &selected
        )
        guard status == noErr else { throw AudioRouteError.coreAudio(operation, status) }
    }

    private func sampleRate(_ device: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    private func supportsRate(_ rate: Double, device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: Int(size) / MemoryLayout<AudioValueRange>.size
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return false }
        return ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
    }
}

final class AudioModel: ObservableObject {
    static let shared = AudioModel()

    @Published private(set) var dellConnected = false
    @Published private(set) var dellIsDefault = false
    @Published private(set) var dellHandlesSystemSounds = false
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var volume = 0.5
    @Published private(set) var volumeAvailable = false
    @Published private(set) var volumeLoading = false
    @Published private(set) var muted = false
    @Published private(set) var softwareVolumeActive = false
    @Published private(set) var mediaKeysActive = false
    @Published private(set) var message = "Checking audio…"

    @Published var autoSwitch: Bool {
        didSet { defaults.set(autoSwitch, forKey: Keys.autoSwitch) }
    }
    @Published var keep48k: Bool {
        didSet {
            defaults.set(keep48k, forKey: Keys.keep48k)
            if keep48k { pinRate(silent: false) }
        }
    }

    private enum Keys {
        static let autoSwitch = "autoSwitchToDell"
        static let keep48k = "keepDellAt48k"
        static let volume = "softwareVolume"
        static let muted = "softwareMuted"
        static let mediaKeysActive = "mediaKeysActiveStatus"
    }

    private let defaults = UserDefaults.standard
    private let router = AudioRouter()
    private let softwareVolume = SoftwareVolumeController()
    private let mediaKeyMonitor = MediaKeyMonitor()
    private let volumeHUD = VolumeHUDController()
    private var routingTimer: Timer?
    private var hasRefreshed = false
    private var wasConnected = false
    private var nextEngineRetry = Date.distantPast
    private var lastCallbackCount: UInt64 = 0
    private var stalledCallbackChecks = 0
    private let isTesting = CommandLine.arguments.contains("--self-test")
        || CommandLine.arguments.contains(where: { $0.hasPrefix("--self-test-gain=") })
        || CommandLine.arguments.contains("--test-built-in-route")
        || CommandLine.arguments.contains("--test-media-key-decode")
        || CommandLine.arguments.contains("--test-hud")

    private init() {
        if defaults.object(forKey: Keys.autoSwitch) == nil { defaults.set(true, forKey: Keys.autoSwitch) }
        if defaults.object(forKey: Keys.keep48k) == nil { defaults.set(true, forKey: Keys.keep48k) }
        if defaults.object(forKey: Keys.volume) == nil { defaults.set(0.25, forKey: Keys.volume) }
        if defaults.object(forKey: Keys.muted) == nil { defaults.set(false, forKey: Keys.muted) }
        autoSwitch = defaults.bool(forKey: Keys.autoSwitch)
        keep48k = defaults.bool(forKey: Keys.keep48k)
        volume = min(max(defaults.double(forKey: Keys.volume), 0), 1)
        muted = defaults.bool(forKey: Keys.muted)

        if !isTesting {
            mediaKeyMonitor.onAction = { [weak self] action in
                self?.handleMediaKey(action)
            }
            mediaKeyMonitor.onStatusChange = { [weak self] active in
                DispatchQueue.main.async {
                    self?.mediaKeysActive = active
                    self?.defaults.set(active, forKey: Keys.mediaKeysActive)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.enableMediaKeys(requestPermission: true)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshRouting(allowAutoSwitch: !(self?.isTesting ?? true))
        }
        if !isTesting {
            routingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.refreshRouting()
                self?.refreshMediaKeys()
            }
        }
    }

    var menuIcon: String {
        if dellIsDefault && dellHandlesSystemSounds && softwareVolumeActive {
            return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }
        return dellConnected ? "display" : "speaker.wave.2"
    }

    var dellAudioReady: Bool {
        dellIsDefault && dellHandlesSystemSounds && softwareVolumeActive
    }

    var routeDescription: String {
        if !dellConnected { return "Display audio disconnected" }
        if dellAudioReady { return "Selected · software volume active" }
        if dellIsDefault && dellHandlesSystemSounds { return "Selected · volume permission needed" }
        if dellIsDefault { return "Selected for app audio" }
        if dellHandlesSystemSounds { return "Split route · select Dell or MacBook" }
        return "Connected · MacBook audio active"
    }

    var rateDescription: String {
        guard sampleRate > 0 else { return "—" }
        return String(format: "%.1f kHz", sampleRate / 1_000)
    }

    func refreshNow() {
        refreshRouting()
    }

    func selectDell(silent: Bool = false) {
        do {
            try router.selectDell(keep48k: keep48k)
            refreshRouting(allowAutoSwitch: false)
            startSoftwareVolume(silent: silent)
            if !silent { message = "Audio routed directly to the Dell." }
        } catch {
            message = error.localizedDescription
        }
    }

    func selectBuiltIn() {
        do {
            stopSoftwareVolume()
            try router.selectBuiltIn()
            refreshRouting(allowAutoSwitch: false)
            message = "Audio routed to MacBook speakers."
        } catch {
            message = error.localizedDescription
        }
    }

    func setVolumeFromUI(_ value: Double) {
        volume = min(max(value, 0), 1)
        if muted && volume > 0 {
            muted = false
            defaults.set(false, forKey: Keys.muted)
        }
        defaults.set(volume, forKey: Keys.volume)
        softwareVolume.setGain(effectiveGain)
        message = "Dell software volume: \(Int((volume * 100).rounded()))%"
    }

    func toggleMute() {
        muted.toggle()
        defaults.set(muted, forKey: Keys.muted)
        softwareVolume.setGain(effectiveGain)
        message = muted ? "Dell audio muted in software." : "Dell audio unmuted."
    }

    func setAutoSwitch(_ enabled: Bool) {
        autoSwitch = enabled
        if enabled && dellConnected && (!dellIsDefault || !dellHandlesSystemSounds) { selectDell() }
    }

    func setKeep48k(_ enabled: Bool) {
        keep48k = enabled
    }

    func openSoundSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAudioPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    func enableMediaKeys(requestPermission: Bool = true) {
        mediaKeysActive = mediaKeyMonitor.start(requestPermission: requestPermission)
        if mediaKeysActive {
            message = "F10 mute · F11 down · F12 up"
        } else if requestPermission {
            message = "Allow Dell Audio in Input Monitoring, then return here."
        }
    }

    func quitSafely() {
        selectBuiltIn()
        NSApplication.shared.terminate(nil)
    }

    func prepareForTermination() {
        mediaKeyMonitor.stop()
        volumeHUD.hide()
        softwareVolume.stop()
    }

    func runHUDTest(completion: @escaping () -> Void) {
        let displayID = volumeHUD.show(volume: 0.5, muted: false, duration: 2.4)
        let builtIn = displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        print("HUD target display: \(displayID ?? 0)")
        print("HUD target is built-in: \(builtIn)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            completion()
        }
    }

    func runSelfTest(gain: Float = 0.25, completion: @escaping () -> Void) {
        do {
            try router.selectDell(keep48k: true)
            let state = router.snapshot()
            guard let dell = state.dellDevice, let dellUID = state.dellUID else {
                throw AudioRouteError.displayUnavailable
            }
            let testGain = min(max(gain, 0), 1)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Hero.aiff"]
            try player.run()
            usleep(100_000)
            try softwareVolume.start(
                deviceID: dell,
                deviceUID: dellUID,
                gain: testGain
            )

            let before = softwareVolume.metrics()
            player.waitUntilExit()
            usleep(200_000)

            let after = softwareVolume.metrics()
            let ratio = after.inputPeak > 0 ? after.outputPeak / after.inputPeak : 0
            let passed = after.callbackCount > before.callbackCount
                && after.nonSilentFrameCount > before.nonSilentFrameCount
                && after.inputPeak > 0.0001
                && abs(ratio - testGain) < 0.04

            print("Dell connected: \(state.dellConnected)")
            print("Dell default output: \(state.dellIsDefault)")
            print("Dell system output: \(state.dellHandlesSystemSounds)")
            print("Dell sample rate: \(state.dellRate ?? 0)")
            print("Software-volume callbacks: \(after.callbackCount - before.callbackCount)")
            print("Non-silent frames: \(after.nonSilentFrameCount - before.nonSilentFrameCount)")
            print(String(format: "Input peak: %.5f", after.inputPeak))
            print(String(format: "Output peak: %.5f", after.outputPeak))
            print(String(format: "Measured gain: %.3f (target %.3f)", ratio, testGain))
            print("SOFTWARE VOLUME SELF-TEST: \(passed ? "PASS" : "FAIL")")
        } catch {
            print("SOFTWARE VOLUME SELF-TEST: FAIL — \(error.localizedDescription)")
        }
        softwareVolume.stop()
        completion()
    }

    func runBuiltInRouteTest(completion: @escaping () -> Void) {
        do {
            softwareVolume.stop()
            try router.selectBuiltIn()
            let state = router.snapshot()
            guard let builtIn = state.builtInDevice else { throw AudioRouteError.builtInUnavailable }
            let passed = state.defaultOutput == builtIn && state.defaultSystemOutput == builtIn
            print("Built-in default output: \(state.defaultOutput == builtIn)")
            print("Built-in system output: \(state.defaultSystemOutput == builtIn)")
            print("BUILT-IN ROUTE TEST: \(passed ? "PASS" : "FAIL")")
        } catch {
            print("BUILT-IN ROUTE TEST: FAIL — \(error.localizedDescription)")
        }
        completion()
    }

    private func refreshRouting(allowAutoSwitch: Bool = true) {
        let state = router.snapshot()
        let connectedTransition = state.dellConnected && !wasConnected
        let initial = !hasRefreshed

        dellConnected = state.dellConnected
        dellIsDefault = state.dellIsDefault
        dellHandlesSystemSounds = state.dellHandlesSystemSounds
        sampleRate = state.dellRate ?? 0
        wasConnected = state.dellConnected
        hasRefreshed = true

        let routeIsSplit = !state.dellIsDefault || !state.dellHandlesSystemSounds
        if allowAutoSwitch && autoSwitch && state.dellConnected && routeIsSplit && (initial || connectedTransition) {
            selectDell(silent: true)
        } else if keep48k && state.dellConnected && (initial || connectedTransition) {
            pinRate(silent: true)
        }

        if state.dellIsDefault {
            if !softwareVolume.isActive && Date() >= nextEngineRetry && !isTesting {
                startSoftwareVolume(silent: true)
            }
        } else if softwareVolume.isActive {
            stopSoftwareVolume()
        }

        if softwareVolume.isActive && !isTesting {
            let callbackCount = softwareVolume.metrics().callbackCount
            if callbackCount == lastCallbackCount {
                stalledCallbackChecks += 1
            } else {
                stalledCallbackChecks = 0
            }
            lastCallbackCount = callbackCount
            if stalledCallbackChecks >= 2 {
                stopSoftwareVolume()
                nextEngineRetry = .distantPast
                startSoftwareVolume(silent: true)
            }
        }

        if message == "Checking audio…" {
            message = state.dellConnected ? "Preparing software volume…" : "Waiting for the Dell display"
        }
    }

    private var effectiveGain: Float {
        muted ? 0 : Float(volume)
    }

    private func handleMediaKey(_ action: MediaKeyAction) {
        let step = action.fineAdjustment ? 1.0 / 64.0 : 1.0 / 16.0
        switch action.command {
        case .mute:
            toggleMute()
        case .volumeDown:
            setVolumeFromUI(max(0, volume - step))
        case .volumeUp:
            setVolumeFromUI(min(1, volume + step))
        }
        volumeHUD.show(volume: volume, muted: muted)
    }

    private func refreshMediaKeys() {
        guard !mediaKeysActive, mediaKeyMonitor.hasPermission else { return }
        enableMediaKeys(requestPermission: false)
    }

    private func startSoftwareVolume(silent: Bool) {
        let state = router.snapshot()
        guard let dell = state.dellDevice, let dellUID = state.dellUID, state.dellIsDefault else {
            stopSoftwareVolume()
            return
        }
        volumeLoading = true
        do {
            try softwareVolume.start(
                deviceID: dell,
                deviceUID: dellUID,
                gain: effectiveGain
            )
            softwareVolumeActive = true
            volumeAvailable = true
            volumeLoading = false
            nextEngineRetry = .distantPast
            lastCallbackCount = softwareVolume.metrics().callbackCount
            stalledCallbackChecks = 0
            if !silent { message = "Software volume is active for Dell audio." }
            else if message == "Checking audio…" || message == "Preparing software volume…" {
                message = "Ready · software volume active, no virtual driver"
            }
        } catch {
            softwareVolumeActive = false
            volumeAvailable = false
            volumeLoading = false
            nextEngineRetry = Date().addingTimeInterval(10)
            message = error.localizedDescription
        }
    }

    private func stopSoftwareVolume() {
        softwareVolume.stop()
        softwareVolumeActive = false
        volumeAvailable = false
        volumeLoading = false
        lastCallbackCount = 0
        stalledCallbackChecks = 0
    }

    private func pinRate(silent: Bool) {
        do {
            try router.pinDellTo48k()
            sampleRate = Product.preferredRate
            if !silent { message = "Dell fixed at 48 kHz." }
        } catch {
            if !silent { message = error.localizedDescription }
        }
    }
}

private struct DellAudioView: View {
    @ObservedObject var model: AudioModel

    private var statusColor: Color {
        if model.dellAudioReady { return .green }
        return model.dellConnected ? .orange : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dell Audio")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(model.routeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(model.rateDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                model.selectDell()
            } label: {
                Label(
                    model.dellAudioReady
                        ? "Dell audio + volume are active"
                        : "Use Dell for All Audio",
                    systemImage: model.dellAudioReady
                        ? "checkmark.circle.fill"
                        : "speaker.arrow.circlepath"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.dellConnected || model.dellAudioReady)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Software volume")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if model.volumeLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(Int((model.volume * 100).rounded()))%")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        model.toggleMute()
                    } label: {
                        Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(model.muted ? "Unmute Dell" : "Mute Dell")
                    Slider(
                        value: Binding(
                            get: { model.volume },
                            set: { model.setVolumeFromUI($0) }
                        ),
                        in: 0...1
                    )
                    .disabled(!model.dellConnected || !model.volumeAvailable)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 9) {
                Toggle(
                    "Use Dell automatically when connected",
                    isOn: Binding(get: { model.autoSwitch }, set: { model.setAutoSwitch($0) })
                )
                Toggle(
                    "Keep Dell at 48 kHz",
                    isOn: Binding(get: { model.keep48k }, set: { model.setKeep48k($0) })
                )
                HStack {
                    Label(
                        model.mediaKeysActive ? "F10 · F11 · F12 enabled" : "Media keys need permission",
                        systemImage: model.mediaKeysActive ? "keyboard.fill" : "keyboard.badge.ellipsis"
                    )
                    Spacer()
                    if !model.mediaKeysActive {
                        Button("Enable") { model.enableMediaKeys() }
                            .controlSize(.small)
                    }
                }
            }
            .toggleStyle(.switch)
            .font(.subheadline)

            Text(model.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack {
                Menu {
                    Button("Use MacBook Speakers") { model.selectBuiltIn() }
                    Button("Open Sound Settings") { model.openSoundSettings() }
                    Button("Open Audio Privacy Settings") { model.openAudioPrivacySettings() }
                    Button("Open Input Monitoring Settings") { model.openInputMonitoringSettings() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
                Text("Core Audio tap · no virtual driver")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()

                Button("Quit") { model.quitSafely() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 330)
        .onAppear { model.refreshNow() }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            AudioModel.shared.runSelfTest {
                NSApplication.shared.terminate(nil)
            }
        } else if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--self-test-gain=") }),
                  let gain = Float(argument.split(separator: "=", maxSplits: 1).last ?? "") {
            AudioModel.shared.runSelfTest(gain: gain) {
                NSApplication.shared.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--test-built-in-route") {
            AudioModel.shared.runBuiltInRouteTest {
                NSApplication.shared.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--test-media-key-decode") {
            let passed = MediaKeyMonitor.runDecodeSelfTest()
            print("MEDIA KEY DECODE TEST: \(passed ? "PASS" : "FAIL")")
            NSApplication.shared.terminate(nil)
        } else if CommandLine.arguments.contains("--test-hud") {
            AudioModel.shared.runHUDTest {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioModel.shared.prepareForTermination()
    }
}

@main
private struct DellAudioMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AudioModel.shared

    var body: some Scene {
        MenuBarExtra {
            DellAudioView(model: model)
        } label: {
            Image(systemName: model.menuIcon)
                .accessibilityLabel("Dell Audio")
        }
        .menuBarExtraStyle(.window)
    }
}
