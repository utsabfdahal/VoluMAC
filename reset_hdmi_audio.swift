import CoreAudio
import Foundation

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ dev: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cf)
    return st == noErr ? (cf as String) : ""
}

func hasOutput(_ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return false }
    return size > 0
}

func getRate(_ dev: AudioDeviceID) -> Double {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
    return rate
}

func setRate(_ dev: AudioDeviceID, _ rate: Double) -> OSStatus {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var r = rate
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &r)
}

func availableRates(_ dev: AudioDeviceID) -> [Double] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return [] }
    let n = Int(size) / MemoryLayout<AudioValueRange>.size
    var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: n)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
    return ranges.map { $0.mMinimum }
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DELL"

print("--- output devices ---")
var match: AudioDeviceID? = nil
for d in allDevices() where hasOutput(d) {
    let nm = deviceName(d)
    print(String(format: "  id=%u  rate=%.0f  %@", d, getRate(d), nm))
    if nm.localizedCaseInsensitiveContains(target) { match = d }
}

guard let dev = match else {
    print("ERROR: no output device matching \"\(target)\"")
    exit(2)
}

let orig = getRate(dev)
let avail = availableRates(dev)
print("\ntarget: \(deviceName(dev)) id=\(dev) currentRate=\(orig)")
print("available rates: \(avail.map { Int($0) })")

// Pick an alternate rate to force a real StopLink/StartLink, then restore.
let alt: Double = (avail.first { $0 != orig }) ?? (orig == 48000 ? 44100 : 48000)
let sequence: [Double] = [alt, orig == 0 ? 48000 : orig]

for r in sequence {
    let st = setRate(dev, r)
    usleep(800_000)
    print(String(format: "set %.0f -> OSStatus %d, now %.0f", r, Int(st), getRate(dev)))
}
print("done; final rate \(getRate(dev))")
