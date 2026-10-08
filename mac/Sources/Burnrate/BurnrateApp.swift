import AppKit
import BurnrateCore
import SwiftUI

@main
struct BurnrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Look.key) private var look: Look = .initial

    var body: some Scene {
        Window("Burnrate", id: "main") {
            RootView()
                .environment(delegate.model)
                .environment(delegate.model.store)
                .preferredColorScheme(look.scheme)
                .frame(minWidth: 380, minHeight: 360)
        }
        // first launch only; afterwards macOS restores the user's size and position
        .defaultWindowPlacement { content, context in
            let screen = context.defaultDisplay.visibleRect.size
            let width = Self.fittingWidth(in: screen.width, look: look, cards: delegate.model.store.ordered.count)
            // the ScrollView's ideal height is its content: header + all card rows;
            // the hidden title bar still takes its strip on top as a safe-area inset
            let fit = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let titleBar = NSWindow.frameRect(forContentRect: .zero, styleMask: .titled).height
            return WindowPlacement(size: CGSize(width: width, height: min(fit.height + titleBar, screen.height)))
        }
        // the zoom button sizes the window to its content too
        .windowIdealSize(.fitToContent)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                OpenWindowCommand()
                Button("Refresh All") { Task { await delegate.model.store.refresh(nil) } }
                    .keyboardShortcut("r")
            }
            CommandGroup(before: .toolbar) {
                Picker("Look", selection: $look) {
                    ForEach(Look.allCases) { Text($0.title).tag($0) }
                }
                Button("Switch Look") { look = look.toggled }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .environment(delegate.model.store)
        }

        MenuBarExtra {
            MenuPanel()
                .environment(delegate.model.store)
                .preferredColorScheme(look.scheme)
        } label: {
            MenuBarLabel(store: delegate.model.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// ⌘O brings the window back after it was closed; the app lives on in the menu bar.
private struct OpenWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Window") { AppDelegate.showWindow(openWindow) }
            .keyboardShortcut("o")
    }
}

extension BurnrateApp {
    /// Every card in one row if the screen is wide enough, else as many columns as
    /// fit with even rows: the window is as wide as the grid it will show.
    static func fittingWidth(in screen: CGFloat, look: Look, cards: Int) -> CGFloat {
        // Cyberpunk: 340 pt cards on 1 pt hairlines; Boring: 320 pt cards, 12 pt gaps, 16 pt margins
        let (card, gap, inset): (CGFloat, CGFloat, CGFloat) = look == .boring ? (320, 12, 32) : (340, 1, 0)
        let cols = GridColumns.balanced(fit: Int((screen - inset + gap) / (card + gap)), count: cards)
        return CGFloat(cols) * (card + gap) - gap + inset
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    @MainActor func applicationWillFinishLaunching(_ notification: Notification) {
        // one copy polls and writes the history: a second launch (say from
        // another install location) hands over to the running one
        if let id = Bundle.main.bundleIdentifier,
            let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0 != NSRunningApplication.current })
        {
            other.activate()
            exit(0)
        }
        Fonts.register()
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        // no window left → no Dock icon either; the menu bar item stays
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard closing?.canBecomeMain == true else { return }  // not the menu bar panel
                let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
                if !others { NSApp.setActivationPolicy(.accessory) }
            }
        }
        // debug: `--args -snapshot /path.png [-snapshotDelay 8]` saves the window as PNG
        if let path = UserDefaults.standard.string(forKey: "snapshot") {
            let delay = UserDefaults.standard.double(forKey: "snapshotDelay")
            Task {
                try? await Task.sleep(for: .seconds(delay > 0 ? delay : 8))
                // `-snapshotWidth N` lays the window out as on a screen that wide
                let forcedWidth = UserDefaults.standard.double(forKey: "snapshotWidth")
                if forcedWidth > 0, let main = Self.mainWindow {
                    var frame = main.frame
                    frame.size.width = forcedWidth
                    main.setFrame(frame, display: true)
                    try? await Task.sleep(for: .seconds(1))
                }
                Self.snapshot(self.model, to: URL(fileURLWithPath: path))
                Self.snapshotFrame(to: URL(fileURLWithPath: path))
                Self.snapshotMenu(self.model, to: URL(fileURLWithPath: path))
                Self.snapshotSettings(self.model, to: URL(fileURLWithPath: path))
                // `-snapshotSwitch YES` flips the look live and frames the window again
                if UserDefaults.standard.bool(forKey: "snapshotSwitch") {
                    let look = Look(rawValue: UserDefaults.standard.string(forKey: Look.key) ?? "") ?? .initial
                    UserDefaults.standard.set(look.toggled.rawValue, forKey: Look.key)
                    try? await Task.sleep(for: .seconds(2))
                    Self.snapshotFrame(to: URL(fileURLWithPath: path), suffix: "-switched")
                }
            }
        }
    }

    @MainActor private static var mainWindow: NSWindow? {
        NSApp.windows.filter(\.isVisible).max { $0.frame.height < $1.frame.height }
    }

    /// The window's content at the window's width, without the toolbar: views
    /// with glass and scroll edge effects don't draw through cacheDisplay.
    @MainActor private static func snapshot(_ model: AppModel, to url: URL) {
        let width = mainWindow?.contentView?.bounds.width ?? 1200
        let look = Look(rawValue: UserDefaults.standard.string(forKey: Look.key) ?? "") ?? .initial
        // `-snapshotScheme light|dark` picks Boring's scheme; the system's otherwise
        let forced = UserDefaults.standard.string(forKey: "snapshotScheme")
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scheme: ColorScheme = look == .cyberpunk || (forced.map { $0 == "dark" } ?? systemDark) ? .dark : .light
        let content = Group {
            if look == .boring { BoringContent().background(Boring.canvas) } else { CyberRoot(flat: true) }
        }
        .frame(width: width)
        .environment(model)
        .environment(model.store)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The whole window with its toolbar as AppKit draws it (glass comes out flat),
    /// to check that the toolbar keeps its height across looks.
    @MainActor private static func snapshotFrame(to url: URL, suffix: String = "-frame") {
        guard let main = mainWindow, let frame = main.contentView?.superview else { return }
        let base = url.deletingPathExtension().path
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + suffix + ".png"))
        let toolbar = main.frame.height - main.contentLayoutRect.height
        let close = main.standardWindowButton(.closeButton)?.frame ?? .zero
        let info = "window \(main.frame.size) toolbar \(toolbar) close \(close)\n"
        try? info.write(toFile: base + suffix + ".txt", atomically: true, encoding: .utf8)
    }

    /// The menu bar panel and icon are off screen until clicked: render them directly.
    @MainActor private static func snapshotMenu(_ model: AppModel, to url: URL) {
        let base = url.deletingPathExtension().path
        let look = Look(rawValue: UserDefaults.standard.string(forKey: Look.key) ?? "") ?? .initial
        var images: [(NSImage?, String)] = []
        for scheme in look == .boring ? [ColorScheme.light, .dark] : [.dark] {
            // the real panel sits on system glass; the snapshot gets a plain backdrop of that scheme
            let content = MenuPanel()
                .environment(model.store)
                .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
            let panel = ImageRenderer(content: content)
            panel.scale = 2
            images.append((panel.nsImage, look == .boring ? "-menu-\(scheme == .dark ? "dark" : "light").png" : "-menu.png"))
        }
        images.append((MenuIcon.render(model.store.isPlaceholder ? nil : MenuSummary.headline(model.store.ordered), look: look), "-icon.png"))
        for (img, suffix) in images {
            guard let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + suffix))
        }
    }

    /// Each Settings pane in an off-screen window: AppKit-backed form controls
    /// don't draw through ImageRenderer, cacheDisplay gets them.
    @MainActor private static func snapshotSettings(_ model: AppModel, to url: URL) {
        let base = url.deletingPathExtension().path
        model.settings.load()
        let panes: [(String, AnyView)] = [
            ("general", AnyView(GeneralPane())), ("appearance", AnyView(AppearanceSettings())),
            ("providers", AnyView(ProvidersPane())),
        ]
        for (name, pane) in panes {
            let host = NSHostingView(
                rootView: pane.frame(width: 520).fixedSize(horizontal: false, vertical: true)
                    .environment(model.settings).environment(model.store))
            let size = host.fittingSize
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-settings-\(name).png"))
        }
    }

    /// Brings the window back with its Dock icon.
    @MainActor static func showWindow(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }

    /// Settings with a Dock icon, in front: an accessory app's Settings window
    /// otherwise opens behind the app the user was in.
    @MainActor static func showSettings(_ openSettings: OpenSettingsAction) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    // closing the window keeps the menu bar item running; Quit is in the panel and ⌘Q
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
