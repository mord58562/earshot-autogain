import AppKit
import AVFoundation

/// The container app exists only because macOS registers Audio Unit extensions
/// through their host bundle. It shows a small window confirming whether the
/// component has been picked up, then gets out of the way.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "Checking")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let title = NSTextField(labelWithString: "Earshot AutoGain")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let body = NSTextField(labelWithString:
            "An Audio Unit effect. Add it from your host's effect list, under "
            + "Audio Unit Effects. This window is only here so macOS registers "
            + "the component; you can quit it once the check passes.")
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 5
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        status.font = .systemFont(ofSize: 12, weight: .medium)

        let stack = NSStackView(views: [title, body, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        body.widthAnchor.constraint(equalToConstant: 400).isActive = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 448, height: 200),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Earshot AutoGain"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Registration is asynchronous after a fresh install, so poll briefly.
        checkRegistration(attemptsRemaining: 20)
    }

    private func checkRegistration(attemptsRemaining: Int) {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_Effect
        description.componentSubType = 0x6167_6e31          // 'agn1'
        description.componentManufacturer = 0x4572_7368      // 'Ersh'

        let matches = AVAudioUnitComponentManager.shared()
            .components(matching: description)

        if let found = matches.first {
            status.stringValue = "Registered: \(found.name) \(found.versionString)"
            status.textColor = .systemGreen
        } else if attemptsRemaining > 0 {
            status.stringValue = "Waiting for macOS to register the component"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkRegistration(attemptsRemaining: attemptsRemaining - 1)
            }
        } else {
            status.stringValue = "Not registered. See the Troubleshooting notes."
            status.textColor = .systemRed
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
