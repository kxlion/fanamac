import SwiftUI

@main
struct FanaMacApp: App {
    @NSApplicationDelegateAdaptor private var appearance: AppearanceMenu
    @StateObject private var model = TuningModel()

    var body: some Scene {
        WindowGroup("FanaMac") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // For a base FanaMac doesn't support yet: its owner sends this file.
            CommandGroup(replacing: .help) {
                Button("Save Diagnostic…") { model.askDiagnosticFile() }
                    .disabled(model.capturing)
            }
        }
    }
}

/// System, light or dark, chosen from the Dock icon's menu.
final class AppearanceMenu: NSObject, NSApplicationDelegate {
    private static let choices: [(title: String, name: NSAppearance.Name?)] = [
        ("System Appearance", nil), ("Light Appearance", .aqua), ("Dark Appearance", .darkAqua),
    ]
    private var current: String {
        get { UserDefaults.standard.string(forKey: "appearance") ?? Self.choices[0].title }
        set { UserDefaults.standard.set(newValue, forKey: "appearance") }
    }

    func applicationWillFinishLaunching(_ notification: Notification) { apply() }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for choice in Self.choices {
            let item = NSMenuItem(title: choice.title, action: #selector(choose), keyEquivalent: "")
            item.target = self
            item.state = choice.title == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ item: NSMenuItem) {
        current = item.title
        apply()
    }

    private func apply() {
        NSApp.appearance = Self.choices.first { $0.title == current }?.name.flatMap(NSAppearance.init(named:))
    }
}
