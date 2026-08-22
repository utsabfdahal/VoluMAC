import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

private final class VolumeHUDState: ObservableObject {
    @Published var volume = 0.25
    @Published var muted = false

    var displayedVolume: Double { muted ? 0 : min(max(volume, 0), 1) }

    var symbolName: String {
        if muted || displayedVolume == 0 { return "speaker.slash.fill" }
        if displayedVolume < 0.34 { return "speaker.wave.1.fill" }
        if displayedVolume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var label: String {
        muted ? "Muted" : "\(Int((displayedVolume * 100).rounded()))%"
    }

    var filledSegments: Int {
        guard !muted, displayedVolume > 0 else { return 0 }
        return min(16, max(1, Int(ceil(displayedVolume * 16))))
    }
}

private struct VolumeHUDView: View {
    @ObservedObject var state: VolumeHUDState

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: state.symbolName)
                .font(.system(size: 47, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(height: 52)

            Text(state.label)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                        .fill(index < state.filledSegments ? Color.white : Color.white.opacity(0.2))
                        .frame(width: 7, height: 8)
                }
            }
            .accessibilityLabel("Volume \(state.label)")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: 190, height: 155)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.7)
        }
    }
}

final class VolumeHUDController {
    private let state = VolumeHUDState()
    private let panel: NSPanel
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 190, height: 155)
        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "VoluMAC Volume HUD"
        panel.contentView = NSHostingView(rootView: VolumeHUDView(state: state))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    @discardableResult
    func show(volume: Double, muted: Bool, duration: TimeInterval = 1.35) -> CGDirectDisplayID? {
        precondition(Thread.isMainThread)
        state.volume = min(max(volume, 0), 1)
        state.muted = muted
        hideWorkItem?.cancel()

        let screen = builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        ))
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        return displayID(for: screen)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
