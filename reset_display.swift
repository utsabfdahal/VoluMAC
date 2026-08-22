import CoreGraphics
import Foundation

func externalDisplay() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.first { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsOnline($0) != 0 }
}

guard let dpy = externalDisplay() else { print("ERROR: no external display found"); exit(2) }
let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(dpy, opts) as? [CGDisplayMode],
      let current = CGDisplayCopyDisplayMode(dpy) else { print("ERROR: no modes"); exit(2) }

let cw = current.width, ch = current.height, crr = current.refreshRate
print("external display id=\(dpy)  current: \(cw)x\(ch) @ \(crr)Hz  pixels=\(current.pixelWidth)x\(current.pixelHeight)")

print("available same-resolution refresh rates:")
for m in modes where m.width == cw && m.height == ch && m.isUsableForDesktopGUI() {
    print(String(format: "  %dx%d @ %.3gHz  pixels=%dx%d", m.width, m.height, m.refreshRate, m.pixelWidth, m.pixelHeight))
}

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "refresh"
var alt: CGDisplayMode?
if arg == "res" {
    // Force a different resolution (heavier pipeline rebuild). Prefer a smaller standard size.
    alt = modes.first { $0.width == 1280 && $0.height == 720 && $0.isUsableForDesktopGUI() }
        ?? modes.first { ($0.width != cw || $0.height != ch) && $0.width >= 1024 && $0.isUsableForDesktopGUI() }
} else {
    // Same logical size, different refresh rate (no window movement).
    alt = modes.first { $0.width == cw && $0.height == ch && $0.refreshRate != crr && $0.refreshRate > 0 && $0.isUsableForDesktopGUI() }
    if alt == nil {
        alt = modes.first { ($0.width != cw || $0.height != ch) && $0.isUsableForDesktopGUI() }
    }
}
guard let altMode = alt else { print("ERROR: no alternate mode to toggle to"); exit(3) }
print(String(format: "toggling: -> %dx%d @ %.3gHz, then back to %dx%d @ %.3gHz",
             altMode.width, altMode.height, altMode.refreshRate, cw, ch, crr))

func setMode(_ m: CGDisplayMode) -> CGError {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return .failure }
    CGConfigureDisplayWithDisplayMode(cfg, dpy, m, nil)
    return CGCompleteDisplayConfiguration(cfg, .forSession)
}

let e1 = setMode(altMode)
print("switch to alt: CGError \(e1.rawValue)")
usleep(1_500_000)
let e2 = setMode(current)
print("revert to original: CGError \(e2.rawValue)")
usleep(1_500_000)
print("done")
