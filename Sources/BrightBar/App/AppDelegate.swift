import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var manager: DisplayManager!
    private var hotKey: HotKey!
    /// Used when the status item is hidden (full menu bar / notch): a floating panel at the top-right instead.
    private var fallbackPanel: NSPanel?
    private var panelObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        manager = DisplayManager()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: makeRoot())

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "BrightBar")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        hotKey = HotKey()
        hotKey.onTrigger = { [weak self] in self?.toggleUI() }
        hotKey.register()

        installDebugHooks()
    }

    private func makeRoot() -> some View {
        BrightnessView(onQuit: { NSApp.terminate(nil) })
            .environmentObject(manager!)
    }

    /// Relaunching the app (Finder double-click, `open`) while it is running shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showUI()
        return false
    }

    private var isStatusItemVisible: Bool {
        guard let window = statusItem.button?.window else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        let frame = window.frame
        return NSScreen.screens.contains { screen in
            guard screen.frame.intersects(frame) else { return false }
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return left.intersects(frame) || right.intersects(frame)
            }
            return true
        }
    }

    private func toggleUI() {
        if popover.isShown { popover.performClose(nil); return }
        if let panel = fallbackPanel, panel.isVisible { closeFallbackPanel(); return }
        showUI()
    }

    private func showUI() {
        if isStatusItemVisible {
            closeFallbackPanel()
            if !popover.isShown { togglePopover(nil) }
        } else {
            showFallbackPanel()
        }
    }

    private func showFallbackPanel() {
        if fallbackPanel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.contentViewController = NSHostingController(rootView: makeRoot())
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isMovableByWindowBackground = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.becomesKeyOnlyIfNeeded = false
            fallbackPanel = panel
            panelObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closeFallbackPanel() }
            }
        }
        guard let panel = fallbackPanel, let content = panel.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = panel.frame.size
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: max(area.minX, area.maxX - size.width - 12),
                                     y: max(area.minY, area.maxY - size.height - 8)))
        refreshIfStale()
        manager.setVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeFallbackPanel() {
        guard let panel = fallbackPanel, panel.isVisible else { return }
        panel.orderOut(nil)
        if !popover.isShown { manager.setVisible(false) }
    }

    private func refreshIfStale() {
        if manager.isStale { manager.refresh() }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if !isStatusItemVisible, sender == nil {
            showFallbackPanel()
        } else if let button = statusItem.button {
            closeFallbackPanel()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        refreshIfStale()
        manager.setVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        manager.setVisible(false)
    }

    /// Developer aid: `BRIGHTBAR_SNAPSHOT=/path/out.png` opens the UI, writes a PNG of it plus a
    /// text dump of the display state next to it, then quits. With `BRIGHTBAR_WRITE_TEST=1` it also
    /// nudges the first display's brightness down, reads it back, and restores it.
    private func installDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BRIGHTBAR_SNAPSHOT"], !path.isEmpty else { return }
        let writeTest = env["BRIGHTBAR_WRITE_TEST"] == "1"
        var dump = ""
        var originals: [(id: String, value: Int)] = []

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            showUI()
            dump += "Displays after scan:\n" + stateDump()
            if writeTest {
                let targets = [manager.displays.first, manager.displays.first { $0.kind == .builtin }].compactMap { $0 }
                for d in targets {
                    originals.append((d.id, d.brightness))
                    let target = d.brightness >= 10 ? d.brightness - 10 : d.brightness + 10
                    dump += "Write test: setting \(d.name) to \(target)\n"
                    manager.setBrightness(target, for: d.id)
                }
                manager.commit()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            if writeTest { manager.refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [self] in
            if writeTest {
                dump += "Displays re-read from monitors:\n" + stateDump()
                for o in originals { manager.setBrightness(o.value, for: o.id) }
                manager.commit()
            }
            dump += "Surface: \(popover.isShown ? "popover" : (fallbackPanel?.isVisible == true ? "fallback panel" : "none")) statusItemVisible=\(isStatusItemVisible)\n"
            let renderer = ImageRenderer(content: makeRoot().frame(width: 320).background(.regularMaterial))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            try? dump.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            NSApp.terminate(nil)
        }
    }

    private func stateDump() -> String {
        var out = ""
        for d in manager.displays {
            out += "  \(d.name) id=\(d.id) brightness=\(d.brightness)/\(d.maxBrightness) contrast=\(d.contrast.map(String.init) ?? "n/a")/\(d.maxContrast)\n"
        }
        out += "  error: \(manager.lastError ?? "none")\n"
        return out
    }
}
