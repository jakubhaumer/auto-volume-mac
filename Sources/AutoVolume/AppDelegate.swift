import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var lastTitle = ""
    private var lastOn: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        model.onTick = { [weak self] in self?.refreshStatusItem() }
        model.startIfNeeded()
        refreshStatusItem()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { self?.model.restartIfOn() }
            }
        }

        // Show the window on the very first launch so people see where the app lives.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self.showPopover() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // MARK: - Status item

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }

        if lastOn != model.isOn {
            lastOn = model.isOn
            let name = model.isOn ? "waveform.circle.fill" : "waveform.circle"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Auto Volume")
            image?.isTemplate = true
            button.image = image
        }

        var title = ""
        if model.isOn, model.showGainInMenuBar, !model.isSilent, model.errorText == nil {
            let g = Int(model.gainDb.rounded())
            title = " " + (g == 0 ? "0 dB" : String(format: "%+d dB", g))
        }
        if title != lastTitle {
            lastTitle = title
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        }
        button.toolTip = model.isOn ? "Auto Volume — leveling on" : "Auto Volume — off"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.refreshLoginState()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: model.isOn ? "Turn Off" : "Turn On", action: #selector(toggleOn), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Auto Volume", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleOn() {
        model.setOn(!model.isOn)
    }
}
