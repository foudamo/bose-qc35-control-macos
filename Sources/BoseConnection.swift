import Foundation
import IOBluetooth

/// Noise-cancelling levels as the headphones encode them on the wire.
/// (Same mapping SaorCon uses: 0 = off, 1 = high, 3 = low.)
enum ANCLevel: UInt8, CaseIterable {
    case high = 0x01
    case low  = 0x03
    case off  = 0x00

    var title: String {
        switch self {
        case .high: return "High"
        case .low:  return "Low"
        case .off:  return "Off"
        }
    }
}

@MainActor
protocol BoseConnectionDelegate: AnyObject {
    func boseConnectionDidOpen(_ connection: BoseConnection)
    func boseConnection(_ connection: BoseConnection, didFailWith message: String)
    func boseConnectionDidClose(_ connection: BoseConnection)
    func boseConnectionDidUpdate(_ connection: BoseConnection)
}

/// Talks the Bose proprietary protocol over RFCOMM.
///
/// Packet format (both directions): [3-byte code][1-byte payload length][payload]
@MainActor
final class BoseConnection: NSObject, IOBluetoothRFCOMMChannelDelegate {

    // Protocol constants, taken from SaorCon v0.0.1.0-alpha (BoseDevice.cs)
    static let rfcommChannel: BluetoothRFCOMMChannelID = 8

    private enum Command {
        static let connect:      [UInt8] = [0x00, 0x01, 0x01]
        static let queryStatus:  [UInt8] = [0x01, 0x01, 0x05]
        static let queryBattery: [UInt8] = [0x02, 0x02, 0x01]
        static let setANC:       [UInt8] = [0x01, 0x06, 0x02]
    }

    private enum Message {
        static let connectAck:   [UInt8] = [0x00, 0x01, 0x03]
        static let ancLevel:     [UInt8] = [0x01, 0x06, 0x03]
        static let batteryLevel: [UInt8] = [0x02, 0x02, 0x03]
    }

    let device: IOBluetoothDevice
    weak var delegate: BoseConnectionDelegate?

    private(set) var isOpen = false
    private(set) var handshakeComplete = false
    private(set) var ancLevel: ANCLevel?
    private(set) var batteryPercent: Int?

    private var channel: IOBluetoothRFCOMMChannel?
    private var rxBuffer: [UInt8] = []
    private var txQueue: [[UInt8]] = []
    private var txBusy = false
    private var requestedANC: ANCLevel?

    init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    var deviceName: String { device.name ?? device.addressString ?? "Headphones" }

    // MARK: - Lifecycle

    /// Starts opening the RFCOMM channel. Result arrives via the delegate.
    func open() {
        var ch: IOBluetoothRFCOMMChannel? = nil
        let result = device.openRFCOMMChannelAsync(&ch, withChannelID: Self.rfcommChannel, delegate: self)
        if result != 0 {
            delegate?.boseConnection(self, didFailWith: "Could not open channel (\(Self.hex(result)))")
            return
        }
        channel = ch
    }

    func close() {
        if let ch = channel {
            _ = ch.setDelegate(nil)
            _ = ch.close()
        }
        channel = nil
        isOpen = false
        handshakeComplete = false
        txQueue.removeAll()
        rxBuffer.removeAll()
    }

    // MARK: - Commands

    func setANC(_ level: ANCLevel) {
        requestedANC = level
        send(Command.setANC, payload: [level.rawValue])
        // If no acknowledgement arrives, ask for the status so the menu shows the truth.
        Self.after(1.2) { [weak self] in
            guard let self, self.isOpen, self.ancLevel != self.requestedANC else { return }
            self.send(Command.queryStatus)
        }
    }

    func refreshStatus() {
        send(Command.queryStatus)
        send(Command.queryBattery)
    }

    func refreshBattery() {
        send(Command.queryBattery)
    }

    private func send(_ code: [UInt8], payload: [UInt8] = []) {
        txQueue.append(code + [UInt8(payload.count)] + payload)
        pumpQueue()
    }

    /// Writes one packet at a time with a short gap, like SaorCon's 100 ms cooldown.
    private func pumpQueue() {
        guard !txBusy, isOpen, let ch = channel, !txQueue.isEmpty else { return }
        var packet = txQueue.removeFirst()
        txBusy = true
        let result = packet.withUnsafeMutableBytes { buf in
            ch.writeSync(buf.baseAddress, length: UInt16(buf.count))
        }
        if result != 0 {
            NSLog("QC35Control: write failed %@", Self.hex(result))
        }
        Self.after(0.12) { [weak self] in
            self?.txBusy = false
            self?.pumpQueue()
        }
    }

    // MARK: - Incoming data

    private func receive(_ bytes: [UInt8]) {
        rxBuffer.append(contentsOf: bytes)
        if rxBuffer.count > 4096 { rxBuffer.removeAll() }   // never let a desync grow forever

        var changed = false
        while rxBuffer.count >= 4 {
            let length = Int(rxBuffer[3])
            guard rxBuffer.count >= 4 + length else { break }
            let header = Array(rxBuffer[0..<3])
            let payload = Array(rxBuffer[4..<(4 + length)])
            rxBuffer.removeFirst(4 + length)
            changed = handle(header: header, payload: payload) || changed
        }
        if changed { delegate?.boseConnectionDidUpdate(self) }
    }

    private func handle(header: [UInt8], payload: [UInt8]) -> Bool {
        switch header {
        case Message.connectAck:
            handshakeComplete = true
            return true
        case Message.ancLevel:
            guard let raw = payload.first, let level = ANCLevel(rawValue: raw) else { return false }
            ancLevel = level
            return true
        case Message.batteryLevel:
            guard let raw = payload.first else { return false }
            batteryPercent = Int(raw)
            return true
        default:
            return false   // the headphones send plenty of messages we don't need
        }
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate (called by IOBluetooth on the main run loop)

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        Self.onMain { [weak self] in
            guard let self else { return }
            if error != 0 {
                self.channel = nil
                self.isOpen = false
                self.delegate?.boseConnection(self, didFailWith: "Channel open failed (\(Self.hex(error)))")
                return
            }
            self.channel = rfcommChannel
            self.isOpen = true
            self.send(Command.connect)
            self.send(Command.queryStatus)
            self.send(Command.queryBattery)
            self.delegate?.boseConnectionDidOpen(self)
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                       data dataPointer: UnsafeMutableRawPointer!,
                                       length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        Self.onMain { [weak self] in self?.receive(bytes) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Self.onMain { [weak self] in
            guard let self else { return }
            self.channel = nil
            self.isOpen = false
            self.handshakeComplete = false
            self.delegate?.boseConnectionDidClose(self)
        }
    }

    // MARK: - Helpers

    nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    nonisolated static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    nonisolated static func hex(_ code: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: code))
    }
}
