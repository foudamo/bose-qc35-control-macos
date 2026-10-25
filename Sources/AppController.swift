import AppKit
import IOBluetooth
import ServiceManagement

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, BoseConnectionDelegate {

    private let defaults = UserDefaults.standard
    private let preferredAddressKey = "preferredDeviceAddress"

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var connection: BoseConnection?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var batteryTimer: Timer?
    private var retriesLeft = 0
    private var lastError: String?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "QC35 Control")
            image?.isTemplate = true
            button.image = image
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Fires whenever any Bluetooth device connects, so we pick the headphones up automatically.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:)))

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connection?.refreshBattery() }
        }

        connect()
        updateStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        connection?.close()
    }

    // MARK: - Device selection

    private var pairedDevices: [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    private func looksLikeBose(_ device: IOBluetoothDevice) -> Bool {
        let name = (device.name ?? "").lowercased()
        return name.contains("bose") || name.contains("qc35") || name.contains("quietcomfort")
    }

    /// The user's chosen device if set, otherwise the first connected Bose-looking device.
    private func targetDevice() -> IOBluetoothDevice? {
        let devices = pairedDevices
        if let address = defaults.string(forKey: preferredAddressKey) {
            return devices.first { $0.addressString == address }
        }
        return devices.first { looksLikeBose($0) && $0.isConnected() }
            ?? devices.first { looksLikeBose($0) }
    }

    // MARK: - Connecting

    private func connect(retries: Int = 3) {
        if let c = connection, c.isOpen { return }
        connection?.close()
        connection = nil
        lastError = nil

        guard let device = targetDevice() else {
            lastError = "No Bose headphones paired"
            updateStatusIcon()
            return
        }
        guard device.isConnected() else {
            updateStatusIcon()
            return
        }

        retriesLeft = retries
        let c = BoseConnection(device: device)
        c.delegate = self
        connection = c
        c.open()
        updateStatusIcon()
    }

    private func retryLater() {
        guard retriesLeft > 0 else { return }
        retriesLeft -= 1
        let remaining = retriesLeft
        BoseConnection.after(2.0) { [weak self] in
            guard let self, !(self.connection?.isOpen ?? false) else { return }
            self.connect(retries: remaining)
        }
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let target = targetDevice(), target.addressString == device.addressString else { return }
        // Give the audio profiles a moment to settle before opening our channel.
        BoseConnection.after(1.5) { [weak self] in self?.connect() }
    }

    @objc private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotification = nil
        connection?.close()
        connection = nil
        updateStatusIcon()
    }

    // MARK: - BoseConnectionDelegate

    func boseConnectionDidOpen(_ connection: BoseConnection) {
        lastError = nil
        disconnectNotification?.unregister()
        disconnectNotification = connection.device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:)))
        updateStatusIcon()
    }

    func boseConnection(_ connection: BoseConnection, didFailWith message: String) {
        lastError = message
        if self.connection === connection { self.connection = nil }
        updateStatusIcon()
        retryLater()
    }

    func boseConnectionDidClose(_ connection: BoseConnection) {
        if self.connection === connection { self.connection = nil }
        updateStatusIcon()
    }

    func boseConnectionDidUpdate(_ connection: BoseConnection) {
        updateStatusIcon()
    }

    // MARK: - Status icon

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let c = connection
        button.appearsDisabled = !(c?.isOpen ?? false)

        var tip = "QC35 Control"
        if let c, c.isOpen {
            tip = c.deviceName
            if let anc = c.ancLevel { tip += " · Noise cancelling \(anc.title)" }
            if let b = c.batteryPercent { tip += " · \(b)%" }
        } else {
            tip += " · not connected"
        }
        button.toolTip = tip
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = connection
        let open = c?.isOpen ?? false

        // Header
        let name = c?.deviceName ?? targetDevice()?.name ?? "No headphones"
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: name, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(header)

        let stateText: String
        if open {
            stateText = c?.batteryPercent.map { "Connected · Battery \($0)%" } ?? "Connected"
        } else if c != nil {
            stateText = "Connecting…"
        } else if let err = lastError {
            stateText = err
        } else if let d = targetDevice(), !d.isConnected() {
            stateText = "Headphones not connected to this Mac"
        } else {
            stateText = "Not connected"
        }
        menu.addItem(disabledItem(stateText))
        menu.addItem(.separator())

        // Noise cancelling
        menu.addItem(disabledItem("Noise Cancelling"))
        for (index, level) in ANCLevel.allCases.enumerated() {
            let item = NSMenuItem(title: "    " + level.title,
                                  action: #selector(selectANC(_:)),
                                  keyEquivalent: "\(index + 1)")
            item.target = self
            item.tag = Int(level.rawValue)
            item.isEnabled = open
            item.state = (open && c?.ancLevel == level) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Device picker
        let devicesItem = NSMenuItem(title: "Headphones", action: nil, keyEquivalent: "")
        let devicesMenu = NSMenu()
        devicesMenu.autoenablesItems = false
        let preferred = defaults.string(forKey: preferredAddressKey)

        let auto = NSMenuItem(title: "Auto-detect Bose", action: #selector(selectDevice(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = nil
        auto.state = preferred == nil ? .on : .off
        devicesMenu.addItem(auto)
        devicesMenu.addItem(.separator())

        for d in pairedDevices {
            let title = (d.name ?? d.addressString ?? "Unknown") + (d.isConnected() ? "" : " (not connected)")
            let item = NSMenuItem(title: title, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.addressString
            item.state = (preferred != nil && preferred == d.addressString) ? .on : .off
            devicesMenu.addItem(item)
        }
        devicesItem.submenu = devicesMenu
        menu.addItem(devicesItem)

        let reconnect = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r")
        reconnect.target = self
        menu.addItem(reconnect)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit QC35 Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Ask for fresh numbers every time the menu opens.
        c?.refreshStatus()
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectANC(_ sender: NSMenuItem) {
        guard let level = ANCLevel(rawValue: UInt8(sender.tag)) else { return }
        connection?.setANC(level)
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        if let address = sender.representedObject as? String {
            defaults.set(address, forKey: preferredAddressKey)
        } else {
            defaults.removeObject(forKey: preferredAddressKey)
        }
        reconnect()
    }

    @objc private func reconnect() {
        disconnectNotification?.unregister()
        disconnectNotification = nil
        connection?.close()
        connection = nil
        connect()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove the app to /Applications and try again, or add it under System Settings › General › Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
