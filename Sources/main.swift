import AppKit

// Top-level code runs on the main thread; tell the compiler so it can create
// the main-actor AppController.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
