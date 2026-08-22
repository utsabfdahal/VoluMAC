import CoreAudio
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func str(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
    }
    guard st == noErr, let v = cf else { return "" }
    return v.takeRetainedValue() as String
}

func deviceName(_ dev: AudioDeviceID) -> String { str(dev, kAudioObjectPropertyName) }
func deviceUID(_ dev: AudioDeviceID) -> String { str(dev, kAudioDevicePropertyDeviceUID) }

func hasOutput(_ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return false }
    return size > 0
}

func defaultOutput() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &dev)
    return dev
}

func setDefaultOutput(_ dev: AudioDeviceID) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d)
}

func findByName(_ needle: String) -> AudioDeviceID? {
    allDevices().first { hasOutput($0) && deviceName($0).localizedCaseInsensitiveContains(needle) }
}

func tapList() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTapList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    let n = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: n)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "list"

switch cmd {
case "list":
    let def = defaultOutput()
    for d in allDevices() where hasOutput(d) {
        let mark = d == def ? " *DEFAULT*" : ""
        print(String(format: "id=%u  %@  [%@]%@", d, deviceName(d), deviceUID(d), mark))
    }
case "taps":
    let taps = tapList()
    print("tap count: \(taps.count)")
    for t in taps {
        print(String(format: "  tap id=%u  uid=%@  desc=%@", t,
            str(t, kAudioTapPropertyUID), str(t, kAudioTapPropertyDescription)))
    }
case "setdefault":
    guard args.count > 2, let dev = findByName(args[2]) else { print("not found: \(args.count>2 ? args[2] : "")"); exit(2) }
    let st = setDefaultOutput(dev)
    print("set default -> \(deviceName(dev)) (id \(dev)), OSStatus \(st)")
default:
    print("usage: audioctl [list|taps|setdefault <name>]")
}
