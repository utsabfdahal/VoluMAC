import CoreAudio
import Darwin
import Foundation

struct SoftwareVolumeMetrics {
    let callbackCount: UInt64
    let nonSilentFrameCount: UInt64
    let inputPeak: Float
    let outputPeak: Float
}

enum SoftwareVolumeError: LocalizedError {
    case operation(String, OSStatus)
    case tapUIDUnavailable

    var errorDescription: String? {
        switch self {
        case let .operation(name, status):
            return "\(name) failed (\(Self.describe(status)))."
        case .tapUIDUnavailable:
            return "The Core Audio tap did not publish a valid UID."
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "'\(fourCC)' / \(status)"
        }
        return String(status)
    }
}

final class SoftwareVolumeController {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var engine: DAVolumeEngineRef?

    private(set) var targetDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var isActive = false

    deinit {
        stop()
    }

    func start(deviceID: AudioDeviceID, deviceUID: String, gain: Float) throws {
        if isActive && targetDeviceID == deviceID {
            setGain(gain)
            return
        }
        stop()

        let excludedProcess = currentProcessObjectID()
        let excluded = excludedProcess == kAudioObjectUnknown ? [] : [excludedProcess]
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excluded
        )
        description.name = "Dell Audio software volume"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior(rawValue: 2) ?? description.muteBehavior
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = true
        if #available(macOS 26.0, *) {
            description.bundleIDs = [Bundle.main.bundleIdentifier ?? "local.dellaudio.menu"]
            description.isProcessRestoreEnabled = true
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw SoftwareVolumeError.operation("Creating the system-audio tap", status)
        }
        tapID = newTapID

        do {
            let tapUID = try readTapUID(newTapID)
            let aggregateUID = "local.dellaudio.private.\(UUID().uuidString)"
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Dell Audio Private Engine",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true as NSNumber,
                kAudioAggregateDeviceIsStackedKey: false as NSNumber,
                kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: deviceUID]
                ],
                kAudioAggregateDeviceTapAutoStartKey: false as NSNumber,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true as NSNumber,
                        kAudioSubTapDriftCompensationQualityKey:
                            kAudioAggregateDriftCompensationHighQuality as NSNumber
                    ]
                ]
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID)
            guard status == noErr else {
                throw SoftwareVolumeError.operation("Creating the private loopback device", status)
            }
            aggregateID = newAggregateID

            var streamStatus = kAudioHardwareBadDeviceError
            for _ in 0..<40 {
                streamStatus = duplexStreamStatus(newAggregateID)
                if streamStatus == noErr { break }
                usleep(50_000)
            }
            guard streamStatus == noErr else {
                reportAggregateState(newAggregateID, physicalDeviceID: deviceID)
                throw SoftwareVolumeError.operation("Publishing the private tap stream", streamStatus)
            }

            var newEngine: DAVolumeEngineRef?
            status = DAVolumeEngineCreate(newAggregateID, newAggregateID, &newEngine)
            guard status == noErr, let newEngine else {
                throw SoftwareVolumeError.operation("Preparing software volume", status)
            }
            engine = newEngine
            DAVolumeEngineSetGain(newEngine, min(max(gain, 0), 1))

            status = DAVolumeEngineStart(newEngine)
            guard status == noErr else {
                throw SoftwareVolumeError.operation("Starting software volume", status)
            }

            targetDeviceID = deviceID
            isActive = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        isActive = false
        targetDeviceID = kAudioObjectUnknown

        if let engine {
            DAVolumeEngineStop(engine)
            DAVolumeEngineDestroy(engine)
            self.engine = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    func setGain(_ gain: Float) {
        guard let engine else { return }
        DAVolumeEngineSetGain(engine, min(max(gain, 0), 1))
    }

    func metrics() -> SoftwareVolumeMetrics {
        guard let engine else {
            return SoftwareVolumeMetrics(
                callbackCount: 0,
                nonSilentFrameCount: 0,
                inputPeak: 0,
                outputPeak: 0
            )
        }
        return SoftwareVolumeMetrics(
            callbackCount: DAVolumeEngineCallbackCount(engine),
            nonSilentFrameCount: DAVolumeEngineNonSilentFrameCount(engine),
            inputPeak: DAVolumeEngineInputPeak(engine),
            outputPeak: DAVolumeEngineOutputPeak(engine)
        )
    }

    private func currentProcessObjectID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processID) { qualifier in
            AudioObjectGetPropertyData(
                system,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &size,
                &objectID
            )
        }
        return status == noErr ? objectID : kAudioObjectUnknown
    }

    private func readTapUID(_ objectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw SoftwareVolumeError.operation("Reading the audio-tap UID", status)
        }
        guard let value else { throw SoftwareVolumeError.tapUIDUnavailable }
        return value.takeRetainedValue() as String
    }

    private func duplexStreamStatus(_ deviceID: AudioDeviceID) -> OSStatus {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
            if status != noErr { return status }
            if size < UInt32(MemoryLayout<AudioObjectID>.size) {
                return kAudioHardwareBadDeviceError
            }
        }
        return noErr
    }

    private func reportAggregateState(
        _ deviceID: AudioDeviceID,
        physicalDeviceID: AudioDeviceID
    ) {
        let input = streamIDs(deviceID, scope: kAudioObjectPropertyScopeInput)
        let output = streamIDs(deviceID, scope: kAudioObjectPropertyScopeOutput)
        let global = streamIDs(deviceID, scope: kAudioObjectPropertyScopeGlobal)
        let physicalInput = streamIDs(physicalDeviceID, scope: kAudioObjectPropertyScopeInput)
        let physicalOutput = streamIDs(physicalDeviceID, scope: kAudioObjectPropertyScopeOutput)
        let physicalGlobal = streamIDs(physicalDeviceID, scope: kAudioObjectPropertyScopeGlobal)
        let devices = stringList(
            deviceID,
            selector: kAudioAggregateDevicePropertyFullSubDeviceList
        )
        let taps = stringList(
            deviceID,
            selector: kAudioAggregateDevicePropertyTapList
        )
        fputs("Dell Audio aggregate diagnostics:\n", stderr)
        fputs("  input streams: \(input)\n", stderr)
        fputs("  output streams: \(output)\n", stderr)
        fputs("  global streams: \(global)\n", stderr)
        fputs("  stream directions: \(global.map(streamDirection))\n", stderr)
        fputs("  subdevices: \(devices)\n", stderr)
        fputs("  active subdevice IDs: \(activeSubdevices(deviceID))\n", stderr)
        fputs("  taps: \(taps)\n", stderr)
        fputs("  physical input streams: \(physicalInput)\n", stderr)
        fputs("  physical output streams: \(physicalOutput)\n", stderr)
        fputs("  physical global streams: \(physicalGlobal)\n", stderr)
        fputs("  physical directions: \(physicalGlobal.map(streamDirection))\n", stderr)
    }

    private func streamIDs(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var values = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    private func streamDirection(_ streamID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyDirection,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var direction: UInt32 = UInt32.max
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &direction)
        return direction
    }

    private func activeSubdevices(_ deviceID: AudioDeviceID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var values = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }

    private func stringList(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return [] }
        return value.takeRetainedValue() as? [String] ?? []
    }
}
