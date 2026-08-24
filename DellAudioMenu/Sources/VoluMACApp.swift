import AppKit
import CoreAudio
import SwiftUI

private enum AppConfiguration {
    static let preferredRate = 48_000.0
    static let bundleIdentifier = "io.github.utsabfdahal.volumac"
    static let legacyDefaultsSuite = "local.dellaudio.menu"
}

private enum AudioRouteError: LocalizedError {
    case outputUnavailable
    case builtInUnavailable
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .outputUnavailable:
            return "The selected audio output is not connected."
        case .builtInUnavailable:
            return "Built-in speakers are unavailable."
        case let .coreAudio(operation, status):
            return "\(operation) failed (CoreAudio \(status))."
        }
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    let sampleRate: Double

    var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeUnknown: return "External audio"
        default: return fourCC(transportType)
        }
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? "External audio"
        let printable = text.unicodeScalars.allSatisfy {
            $0.value >= 32 && $0.value <= 126
        }
        return printable ? text : "External audio"
    }
}

private struct AudioSnapshot {
    let availableOutputs: [OutputDevice]
    let selectedOutput: OutputDevice?
    let builtInDevice: OutputDevice?
    let defaultOutput: AudioDeviceID
    let defaultSystemOutput: AudioDeviceID

    var outputConnected: Bool { selectedOutput != nil }
    var outputIsDefault: Bool { selectedOutput?.id == defaultOutput }
    var outputHandlesSystemSounds: Bool { selectedOutput?.id == defaultSystemOutput }
}

private final class AudioRouter {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let excludedExternalTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeAggregate,
        kAudioDeviceTransportTypeVirtual,
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeAirPlay
    ]

    func snapshot(preferredUID: String?, preferredName: String?) -> AudioSnapshot {
        let allOutputs = allOutputDevices()
        let externalOutputs = allOutputs
            .filter { !excludedExternalTransports.contains($0.transportType) }
            .filter { !$0.name.hasPrefix("VoluMAC Private Engine") }
            .filter { $0.sampleRate > 0 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultSystemOutput = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)

        var selected = preferredUID.flatMap { uid in
            externalOutputs.first { $0.uid == uid }
        }
        if selected == nil, let preferredName, !preferredName.isEmpty {
            selected = externalOutputs.first {
                $0.name.caseInsensitiveCompare(preferredName) == .orderedSame
            }
        }
        if selected == nil, preferredUID == nil, preferredName == nil {
            selected = externalOutputs.first { $0.id == defaultOutput }
            if selected == nil, externalOutputs.count == 1 {
                selected = externalOutputs.first
            }
        }

        let builtIn = allOutputs.first {
            $0.transportType == kAudioDeviceTransportTypeBuiltIn
                && $0.uid == "BuiltInSpeakerDevice"
        } ?? allOutputs.first {
            $0.transportType == kAudioDeviceTransportTypeBuiltIn
        }

        return AudioSnapshot(
            availableOutputs: externalOutputs,
            selectedOutput: selected,
            builtInDevice: builtIn,
            defaultOutput: defaultOutput,
            defaultSystemOutput: defaultSystemOutput
        )
    }

    func selectOutput(_ device: OutputDevice) throws {
        try setDefault(
            device.id,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            operation: "Selecting \(device.name) for application audio"
        )
        try setDefault(
            device.id,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            operation: "Selecting \(device.name) for system sounds"
        )
    }

    func selectBuiltIn(_ device: OutputDevice) throws {
        try setDefault(
            device.id,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            operation: "Selecting built-in audio"
        )
        try setDefault(
            device.id,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            operation: "Selecting built-in system sounds"
        )
    }

    func pinTo48k(_ device: OutputDevice) throws {
        let current = sampleRate(device.id)
        guard abs(current - AppConfiguration.preferredRate) > 1 else { return }
        guard supportsRate(AppConfiguration.preferredRate, device: device.id) else {
            throw AudioRouteError.coreAudio(
                "Setting \(device.name) to 48 kHz",
                kAudioHardwareUnsupportedOperationError
            )
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = AppConfiguration.preferredRate
        let status = AudioObjectSetPropertyData(
            device.id,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &rate
        )
        guard status == noErr else {
            throw AudioRouteError.coreAudio("Setting \(device.name) to 48 kHz", status)
        }
    }

    private func allOutputDevices() -> [OutputDevice] {
        allDevices().filter(hasOutput).compactMap { device in
            let uid = stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
            let name = stringProperty(device, selector: kAudioObjectPropertyName)
            guard !uid.isEmpty, !name.isEmpty else { return nil }
            return OutputDevice(
                id: device,
                uid: uid,
                name: name,
                transportType: uint32Property(device, selector: kAudioDevicePropertyTransportType),
                sampleRate: sampleRate(device)
            )
        }
    }

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
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

    private func stringProperty(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String {
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

    private func uint32Property(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
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
            system,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &selected
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

    @Published private(set) var availableOutputs: [OutputDevice] = []
    @Published private(set) var selectedOutput: OutputDevice?
    @Published private(set) var builtInDevice: OutputDevice?
    @Published private(set) var outputConnected = false
    @Published private(set) var outputIsDefault = false
    @Published private(set) var outputHandlesSystemSounds = false
    @Published private(set) var defaultOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var volume = 0.5
    @Published private(set) var volumeAvailable = false
    @Published private(set) var volumeLoading = false
    @Published private(set) var muted = false
    @Published private(set) var softwareVolumeActive = false
    @Published private(set) var mediaKeysActive = false
    @Published private(set) var message = "Checking audio…"

    @Published var autoSwitch = true {
        didSet { defaults.set(autoSwitch, forKey: Keys.autoSwitch) }
    }
    @Published var keep48k = true {
        didSet {
            defaults.set(keep48k, forKey: Keys.keep48k)
            if keep48k { pinSelectedRate(silent: false) }
        }
    }

    private enum Keys {
        static let autoSwitch = "autoSwitchToOutput"
        static let keep48k = "keepOutputAt48k"
        static let volume = "softwareVolume"
        static let muted = "softwareMuted"
        static let mediaKeysActive = "mediaKeysActiveStatus"
        static let selectedOutputUID = "selectedOutputUID"
        static let selectedOutputName = "selectedOutputName"
    }

    private let defaults = UserDefaults.standard
    private let router = AudioRouter()
    private let softwareVolume = SoftwareVolumeController()
    private let mediaKeyMonitor = MediaKeyMonitor()
    private let volumeHUD = VolumeHUDController()
    private var routingTimer: Timer?
    private var preferredOutputUID: String?
    private var preferredOutputName: String?
    private var hasRefreshed = false
    private var wasConnected = false
    private var nextEngineRetry = Date.distantPast
    private var lastCallbackCount: UInt64 = 0
    private var stalledCallbackChecks = 0
    private let isTesting = CommandLine.arguments.contains("--self-test")
        || CommandLine.arguments.contains(where: { $0.hasPrefix("--self-test-gain=") })
        || CommandLine.arguments.contains("--test-built-in-route")
        || CommandLine.arguments.contains("--test-media-key-decode")
        || CommandLine.arguments.contains("--test-media-key-lifecycle")
        || CommandLine.arguments.contains("--test-output-discovery")
        || CommandLine.arguments.contains("--test-hud")

    private init() {
        migrateLegacyPreferences()
        if defaults.object(forKey: Keys.autoSwitch) == nil { defaults.set(true, forKey: Keys.autoSwitch) }
        if defaults.object(forKey: Keys.keep48k) == nil { defaults.set(true, forKey: Keys.keep48k) }
        if defaults.object(forKey: Keys.volume) == nil { defaults.set(0.25, forKey: Keys.volume) }
        if defaults.object(forKey: Keys.muted) == nil { defaults.set(false, forKey: Keys.muted) }
        autoSwitch = defaults.bool(forKey: Keys.autoSwitch)
        keep48k = defaults.bool(forKey: Keys.keep48k)
        volume = min(max(defaults.double(forKey: Keys.volume), 0), 1)
        muted = defaults.bool(forKey: Keys.muted)
        preferredOutputUID = defaults.string(forKey: Keys.selectedOutputUID)
        preferredOutputName = defaults.string(forKey: Keys.selectedOutputName)

        if !isTesting {
            mediaKeyMonitor.onAction = { [weak self] action in self?.handleMediaKey(action) }
            mediaKeyMonitor.onStatusChange = { [weak self] active in
                DispatchQueue.main.async {
                    self?.mediaKeysActive = active
                    self?.defaults.set(active, forKey: Keys.mediaKeysActive)
                }
            }
            enableMediaKeys(requestPermission: true)
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
        if outputAudioReady { return muted ? "speaker.slash.fill" : "speaker.wave.2.fill" }
        return outputConnected ? "display" : "speaker.wave.2"
    }

    var outputAudioReady: Bool {
        outputIsDefault && outputHandlesSystemSounds && softwareVolumeActive
    }

    var selectedOutputName: String {
        selectedOutput?.name ?? preferredOutputName ?? "Select an output"
    }

    var selectedTransportLabel: String {
        selectedOutput?.transportLabel ?? "External display audio"
    }

    var builtInName: String {
        builtInDevice?.name ?? "Built-in Speakers"
    }

    var routeDescription: String {
        if selectedOutput == nil, !availableOutputs.isEmpty, preferredOutputUID == nil {
            return "Choose an external output"
        }
        if !outputConnected { return "Selected output is disconnected" }
        if outputAudioReady { return "Selected · software volume active" }
        if outputIsDefault && outputHandlesSystemSounds { return "Selected · volume permission needed" }
        if outputIsDefault { return "Selected for application audio" }
        if outputHandlesSystemSounds { return "Split route · select the output again" }
        return "Connected · another output is active"
    }

    var rateDescription: String {
        guard sampleRate > 0 else { return "—" }
        return String(format: "%.1f kHz", sampleRate / 1_000)
    }

    func isSelected(_ output: OutputDevice) -> Bool {
        selectedOutput?.uid == output.uid || preferredOutputUID == output.uid
    }

    func isActiveOutput(_ output: OutputDevice) -> Bool {
        defaultOutputDeviceID == output.id
    }

    var builtInIsActive: Bool {
        builtInDevice?.id == defaultOutputDeviceID
    }

    func refreshNow() {
        refreshRouting()
    }

    func chooseOutput(uid: String) {
        guard let output = availableOutputs.first(where: { $0.uid == uid }) else { return }
        preferredOutputUID = output.uid
        preferredOutputName = output.name
        defaults.set(output.uid, forKey: Keys.selectedOutputUID)
        defaults.set(output.name, forKey: Keys.selectedOutputName)
        stopSoftwareVolume()
        selectedOutput = output
        activateSelectedOutput(silent: false)
    }

    func activateSelectedOutput(silent: Bool = false) {
        let state = router.snapshot(
            preferredUID: preferredOutputUID,
            preferredName: preferredOutputName
        )
        guard let output = state.selectedOutput else {
            message = AudioRouteError.outputUnavailable.localizedDescription
            return
        }

        var rateWarning: String?
        if keep48k {
            do { try router.pinTo48k(output) }
            catch { rateWarning = error.localizedDescription }
        }

        do {
            stopSoftwareVolume()
            try router.selectOutput(output)
            refreshRouting(allowAutoSwitch: false)
            startSoftwareVolume(silent: silent)
            if !silent {
                message = rateWarning ?? "Audio routed to \(output.name)."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func selectBuiltIn() {
        let state = router.snapshot(
            preferredUID: preferredOutputUID,
            preferredName: preferredOutputName
        )
        guard let builtIn = state.builtInDevice else {
            message = AudioRouteError.builtInUnavailable.localizedDescription
            return
        }
        do {
            stopSoftwareVolume()
            try router.selectBuiltIn(builtIn)
            refreshRouting(allowAutoSwitch: false)
            message = "Audio routed to \(builtIn.name)."
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
        message = "Software volume: \(Int((volume * 100).rounded()))%"
    }

    func toggleMute() {
        muted.toggle()
        defaults.set(muted, forKey: Keys.muted)
        softwareVolume.setGain(effectiveGain)
        message = muted ? "Audio muted in software." : "Audio unmuted."
    }

    func setAutoSwitch(_ enabled: Bool) {
        autoSwitch = enabled
        if enabled && outputConnected && (!outputIsDefault || !outputHandlesSystemSounds) {
            activateSelectedOutput()
        }
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
            message = "Allow VoluMAC in Input Monitoring, then return here."
        }
    }

    func applicationDidFinishLaunching() {
        guard !isTesting else { return }
        if !mediaKeyMonitor.maintain() {
            enableMediaKeys(requestPermission: true)
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

    func runOutputDiscoveryTest(completion: @escaping () -> Void) {
        let state = router.snapshot(
            preferredUID: preferredOutputUID,
            preferredName: preferredOutputName
        )
        print("Compatible external outputs: \(state.availableOutputs.count)")
        for output in state.availableOutputs {
            print("- \(output.name) [\(output.transportLabel)] \(Int(output.sampleRate)) Hz uid=\(output.uid)")
        }
        print("Selected output: \(state.selectedOutput?.name ?? "none")")
        print("OUTPUT DISCOVERY TEST: \(!state.availableOutputs.isEmpty ? "PASS" : "NO EXTERNAL OUTPUT")")
        completion()
    }

    func runMediaKeyLifecycleTest(completion: @escaping () -> Void) {
        guard mediaKeyMonitor.start(requestPermission: false) else {
            print("MEDIA KEY LIFECYCLE TEST: NO INPUT MONITORING PERMISSION")
            completion()
            return
        }
        let before = mediaKeyMonitor.generation
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let after = self.mediaKeyMonitor.generation
            let passed = self.mediaKeyMonitor.isActive && after > before
            print("Media-key generation: \(before) -> \(after)")
            print("Media-key tap active: \(self.mediaKeyMonitor.isActive)")
            print("MEDIA KEY LIFECYCLE TEST: \(passed ? "PASS" : "FAIL")")
            self.mediaKeyMonitor.stop()
            completion()
        }
    }

    func runHUDTest(completion: @escaping () -> Void) {
        let displayID = volumeHUD.show(volume: 0.5, muted: false, duration: 2.4)
        let builtIn = displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        print("HUD target display: \(displayID ?? 0)")
        print("HUD target is built-in: \(builtIn)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { completion() }
    }

    func runSelfTest(gain: Float = 0.25, completion: @escaping () -> Void) {
        do {
            let state = router.snapshot(
                preferredUID: preferredOutputUID,
                preferredName: preferredOutputName
            )
            guard let output = state.selectedOutput else { throw AudioRouteError.outputUnavailable }
            if keep48k { try? router.pinTo48k(output) }
            try router.selectOutput(output)
            let routedState = router.snapshot(
                preferredUID: output.uid,
                preferredName: output.name
            )

            let testGain = min(max(gain, 0), 1)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Hero.aiff"]
            try player.run()
            usleep(100_000)
            try softwareVolume.start(
                deviceID: output.id,
                deviceUID: output.uid,
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

            print("Output: \(output.name) [\(output.transportLabel)]")
            print("Default output: \(output.id == routedState.defaultOutput)")
            print("System output: \(output.id == routedState.defaultSystemOutput)")
            print("Sample rate: \(output.sampleRate)")
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
        let state = router.snapshot(
            preferredUID: preferredOutputUID,
            preferredName: preferredOutputName
        )
        do {
            softwareVolume.stop()
            guard let builtIn = state.builtInDevice else { throw AudioRouteError.builtInUnavailable }
            try router.selectBuiltIn(builtIn)
            let after = router.snapshot(
                preferredUID: preferredOutputUID,
                preferredName: preferredOutputName
            )
            let passed = after.defaultOutput == builtIn.id
                && after.defaultSystemOutput == builtIn.id
            print("Built-in default output: \(after.defaultOutput == builtIn.id)")
            print("Built-in system output: \(after.defaultSystemOutput == builtIn.id)")
            print("BUILT-IN ROUTE TEST: \(passed ? "PASS" : "FAIL")")
        } catch {
            print("BUILT-IN ROUTE TEST: FAIL — \(error.localizedDescription)")
        }
        completion()
    }

    private func migrateLegacyPreferences() {
        guard let legacy = UserDefaults(suiteName: AppConfiguration.legacyDefaultsSuite) else { return }
        let mappings: [(String, String)] = [
            (Keys.autoSwitch, "autoSwitchToDell"),
            (Keys.keep48k, "keepDellAt48k"),
            (Keys.volume, "softwareVolume"),
            (Keys.muted, "softwareMuted")
        ]
        for (newKey, oldKey) in mappings where defaults.object(forKey: newKey) == nil {
            if let value = legacy.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    private func persistSelection(_ output: OutputDevice) {
        preferredOutputUID = output.uid
        preferredOutputName = output.name
        defaults.set(output.uid, forKey: Keys.selectedOutputUID)
        defaults.set(output.name, forKey: Keys.selectedOutputName)
    }

    private func refreshRouting(allowAutoSwitch: Bool = true) {
        let state = router.snapshot(
            preferredUID: preferredOutputUID,
            preferredName: preferredOutputName
        )
        let connectedTransition = state.outputConnected && !wasConnected
        let initial = !hasRefreshed

        availableOutputs = state.availableOutputs
        selectedOutput = state.selectedOutput
        builtInDevice = state.builtInDevice
        outputConnected = state.outputConnected
        outputIsDefault = state.outputIsDefault
        outputHandlesSystemSounds = state.outputHandlesSystemSounds
        defaultOutputDeviceID = state.defaultOutput
        sampleRate = state.selectedOutput?.sampleRate ?? 0
        wasConnected = state.outputConnected
        hasRefreshed = true

        if let output = state.selectedOutput,
           preferredOutputUID != output.uid || preferredOutputName != output.name {
            persistSelection(output)
        }

        let routeIsSplit = !state.outputIsDefault || !state.outputHandlesSystemSounds
        if allowAutoSwitch,
           autoSwitch,
           state.outputConnected,
           routeIsSplit,
           (initial || connectedTransition) {
            activateSelectedOutput(silent: true)
        } else if keep48k, state.outputConnected, (initial || connectedTransition) {
            pinSelectedRate(silent: true)
        }

        if state.outputIsDefault {
            if !softwareVolume.isActive && Date() >= nextEngineRetry && !isTesting {
                startSoftwareVolume(silent: true)
            }
        } else if softwareVolume.isActive {
            stopSoftwareVolume()
        }

        if softwareVolume.isActive && !isTesting {
            let callbackCount = softwareVolume.metrics().callbackCount
            stalledCallbackChecks = callbackCount == lastCallbackCount
                ? stalledCallbackChecks + 1
                : 0
            lastCallbackCount = callbackCount
            if stalledCallbackChecks >= 2 {
                stopSoftwareVolume()
                nextEngineRetry = .distantPast
                startSoftwareVolume(silent: true)
            }
        }

        if message == "Checking audio…" {
            message = state.outputConnected
                ? "Preparing software volume…"
                : (state.availableOutputs.isEmpty
                    ? "No compatible external output detected"
                    : "Choose an external output")
        }
    }

    private var effectiveGain: Float {
        muted ? 0 : Float(volume)
    }

    private func handleMediaKey(_ action: MediaKeyAction) {
        let step = action.fineAdjustment ? 1.0 / 64.0 : 1.0 / 16.0
        switch action.command {
        case .mute: toggleMute()
        case .volumeDown: setVolumeFromUI(max(0, volume - step))
        case .volumeUp: setVolumeFromUI(min(1, volume + step))
        }
        volumeHUD.show(volume: volume, muted: muted)
    }

    private func refreshMediaKeys() {
        if mediaKeysActive {
            mediaKeysActive = mediaKeyMonitor.maintain()
        } else if mediaKeyMonitor.hasPermission {
            enableMediaKeys(requestPermission: false)
        }
    }

    private func startSoftwareVolume(silent: Bool) {
        let state = router.snapshot(
            preferredUID: preferredOutputUID,
            preferredName: preferredOutputName
        )
        guard let output = state.selectedOutput, state.outputIsDefault else {
            stopSoftwareVolume()
            return
        }
        volumeLoading = true
        do {
            try softwareVolume.start(
                deviceID: output.id,
                deviceUID: output.uid,
                gain: effectiveGain
            )
            softwareVolumeActive = true
            volumeAvailable = true
            volumeLoading = false
            nextEngineRetry = .distantPast
            lastCallbackCount = softwareVolume.metrics().callbackCount
            stalledCallbackChecks = 0
            if !silent { message = "Software volume is active for \(output.name)." }
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

    private func pinSelectedRate(silent: Bool) {
        guard let output = selectedOutput else { return }
        do {
            try router.pinTo48k(output)
            sampleRate = AppConfiguration.preferredRate
            if !silent { message = "\(output.name) is set to 48 kHz." }
        } catch {
            if !silent { message = error.localizedDescription }
        }
    }
}

private struct VoluMACView: View {
    @ObservedObject var model: AudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound")
                .font(.headline)

            HStack(spacing: 9) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help(model.muted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { model.volume },
                        set: { model.setVolumeFromUI($0) }
                    ),
                    in: 0...1
                )
                .disabled(!model.outputConnected || !model.volumeAvailable)
                .help("Software volume: \(Int((model.volume * 100).rounded()))%")

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            Divider()

            Text("Output")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 3) {
                if let builtIn = model.builtInDevice {
                    SoundOutputRow(
                        name: builtIn.name,
                        detail: "Built-in",
                        icon: "laptopcomputer",
                        active: model.builtInIsActive
                    ) {
                        model.selectBuiltIn()
                    }
                }

                ForEach(model.availableOutputs) { output in
                    SoundOutputRow(
                        name: output.name,
                        detail: output.transportLabel,
                        icon: output.transportType == kAudioDeviceTransportTypeUSB
                            ? "speaker.wave.2.fill"
                            : "display",
                        active: model.isActiveOutput(output)
                    ) {
                        model.chooseOutput(uid: output.uid)
                    }
                }

                if model.builtInDevice == nil && model.availableOutputs.isEmpty {
                    Text("No audio outputs found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }

            Divider()

            HStack {
                Button("Sound Settings…") {
                    model.openSoundSettings()
                }
                .buttonStyle(.plain)

                Spacer()

                extraFeaturesMenu
            }
        }
        .padding(13)
        .frame(width: 305)
        .onAppear { model.refreshNow() }
    }

    private var extraFeaturesMenu: some View {
        Menu {
            Text(model.routeDescription)
            Text("\(model.selectedOutputName) · \(model.rateDescription)")

            Divider()

            Toggle(
                "Use selected output automatically",
                isOn: Binding(get: { model.autoSwitch }, set: { model.setAutoSwitch($0) })
            )
            Toggle(
                "Keep selected output at 48 kHz",
                isOn: Binding(get: { model.keep48k }, set: { model.setKeep48k($0) })
            )

            if model.mediaKeysActive {
                Label("F10 · F11 · F12 enabled", systemImage: "keyboard.fill")
            } else {
                Button("Enable media keys") { model.enableMediaKeys() }
            }

            Divider()

            Button("Refresh Outputs") { model.refreshNow() }
            Button("Audio Privacy Settings…") { model.openAudioPrivacySettings() }
            Button("Input Monitoring Settings…") { model.openInputMonitoringSettings() }

            Divider()

            Button("Quit VoluMAC", role: .destructive) { model.quitSafely() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More VoluMAC options")
    }
}

private struct SoundOutputRow: View {
    let name: String
    let detail: String
    let icon: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.16))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                }

                Text(name)
                    .font(.subheadline.weight(active ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioModel.shared.applicationDidFinishLaunching()
        if CommandLine.arguments.contains("--self-test") {
            AudioModel.shared.runSelfTest { NSApplication.shared.terminate(nil) }
        } else if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--self-test-gain=") }),
                  let gain = Float(argument.split(separator: "=", maxSplits: 1).last ?? "") {
            AudioModel.shared.runSelfTest(gain: gain) { NSApplication.shared.terminate(nil) }
        } else if CommandLine.arguments.contains("--test-built-in-route") {
            AudioModel.shared.runBuiltInRouteTest { NSApplication.shared.terminate(nil) }
        } else if CommandLine.arguments.contains("--test-media-key-decode") {
            let passed = MediaKeyMonitor.runDecodeSelfTest()
            print("MEDIA KEY DECODE TEST: \(passed ? "PASS" : "FAIL")")
            NSApplication.shared.terminate(nil)
        } else if CommandLine.arguments.contains("--test-media-key-lifecycle") {
            AudioModel.shared.runMediaKeyLifecycleTest {
                NSApplication.shared.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--test-output-discovery") {
            AudioModel.shared.runOutputDiscoveryTest { NSApplication.shared.terminate(nil) }
        } else if CommandLine.arguments.contains("--test-hud") {
            AudioModel.shared.runHUDTest { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioModel.shared.prepareForTermination()
    }
}

@main
private struct VoluMACApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AudioModel.shared

    var body: some Scene {
        MenuBarExtra {
            VoluMACView(model: model)
        } label: {
            Image(systemName: model.menuIcon)
                .accessibilityLabel("VoluMAC")
        }
        .menuBarExtraStyle(.window)
    }
}
