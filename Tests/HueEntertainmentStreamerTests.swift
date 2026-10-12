import XCTest
@testable import StremioTV

/// Vérifie la pompe HueStream sans réseau : séquence, lissage, ligne à retard,
/// canaux absents, arrêt sans envoi ultérieur et pompe réelle.
final class HueEntertainmentStreamerTests: XCTestCase {

    private let areaID = "1a8d99cc-967b-44f2-9202-43f976c0fa6b"

    // MARK: Doublure de transport

    /// Transport factice qui enregistre les datagrammes (thread-safe).
    private final class RecordingTransport: HueDatagramTransport {
        private let lock = NSLock()
        private var _datagrams: [Data] = []
        /// Appelé dans `send`, après l'enregistrement (sur la file de l'appelant).
        var onSend: (() -> Void)?

        var datagrams: [Data] {
            lock.lock(); defer { lock.unlock() }
            return _datagrams
        }

        func connect(host: String, pskIdentity: String, pskHex: String, timeout: TimeInterval,
                     completion: @escaping (Result<Void, Error>) -> Void) {
            completion(.success(()))
        }

        func send(_ datagram: Data) {
            lock.lock()
            _datagrams.append(datagram)
            lock.unlock()
            onSend?()
        }

        func close() {}
    }

    // MARK: Décodage des paquets

    private struct DecodedChannel: Equatable {
        let id: UInt8
        let r: UInt16
        let g: UInt16
        let b: UInt16
    }

    private func sequence(of packet: Data) -> UInt8 {
        Array(packet)[11]
    }

    private func channels(of packet: Data) -> [DecodedChannel] {
        let bytes = Array(packet)
        let start = HueStreamPacket.headerSize + HueStreamPacket.areaIDSize
        var result: [DecodedChannel] = []
        var offset = start
        while offset + HueStreamPacket.bytesPerChannel <= bytes.count {
            func word(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
            result.append(DecodedChannel(id: bytes[offset], r: word(offset + 1), g: word(offset + 3), b: word(offset + 5)))
            offset += HueStreamPacket.bytesPerChannel
        }
        return result
    }

    private func makeStreamer(channelIDs: [UInt8] = [0, 1, 2],
                              transport: RecordingTransport,
                              tau: TimeInterval = 0) -> HueEntertainmentStreamer {
        let streamer = HueEntertainmentStreamer(areaID: areaID, channelIDs: channelIDs,
                                                transport: transport, clock: { 0 })
        streamer.smoothingTimeConstant = tau
        return streamer
    }

    private func color(_ id: UInt8, _ r: Double, _ g: Double, _ b: Double) -> HueChannelColor {
        HueChannelColor(channelID: id, color: HueRGB(r: r, g: g, b: b))
    }

    // MARK: Tests

    func testInitialColorIsBlackAndChannelOrderFollowsChannelIDs() throws {
        let transport = RecordingTransport()
        let streamer = makeStreamer(channelIDs: [3, 1, 2], transport: transport)
        streamer.step(now: 1)

        let packet = try XCTUnwrap(transport.datagrams.first)
        XCTAssertEqual(packet.count, HueStreamPacket.headerSize + HueStreamPacket.areaIDSize + 3 * HueStreamPacket.bytesPerChannel)
        XCTAssertEqual(Array(packet.prefix(9)), Array("HueStream".utf8))
        XCTAssertEqual(channels(of: packet).map(\.id), [3, 1, 2])
        XCTAssertTrue(channels(of: packet).allSatisfy { $0.r == 0 && $0.g == 0 && $0.b == 0 })
        XCTAssertEqual(streamer.packetsSent, 1)
    }

    func testSequenceIncrementsAndWraps() {
        let transport = RecordingTransport()
        let streamer = makeStreamer(transport: transport)
        for i in 0..<300 {
            streamer.step(now: Double(i) * 0.02)
        }
        let sequences = transport.datagrams.map(sequence(of:))
        XCTAssertEqual(sequences.count, 300)
        for (i, value) in sequences.enumerated() {
            XCTAssertEqual(value, UInt8(i % 256))
        }
        XCTAssertEqual(streamer.packetsSent, 300)
    }

    func testIdenticalPacketsAreResent() {
        let transport = RecordingTransport()
        let streamer = makeStreamer(transport: transport)
        streamer.submit([color(0, 1, 0, 0)], capturedAt: 0)
        streamer.step(now: 1)
        streamer.step(now: 1.02)
        let packets = transport.datagrams
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(channels(of: packets[0]), channels(of: packets[1]))
    }

    func testZeroTimeConstantJumpsDirectly() throws {
        let transport = RecordingTransport()
        let streamer = makeStreamer(transport: transport, tau: 0)
        streamer.submit([color(0, 1, 0.5, 0), color(1, 0, 1, 0), color(2, 0, 0, 1)], capturedAt: 0)
        streamer.step(now: 0)

        let decoded = channels(of: try XCTUnwrap(transport.datagrams.last))
        XCTAssertEqual(decoded[0], DecodedChannel(id: 0, r: 65535, g: 32768, b: 0))
        XCTAssertEqual(decoded[1], DecodedChannel(id: 1, r: 0, g: 65535, b: 0))
        XCTAssertEqual(decoded[2], DecodedChannel(id: 2, r: 0, g: 0, b: 65535))
    }

    func testSmoothingFollowsExponentialAndConverges() throws {
        let transport = RecordingTransport()
        let tau = 0.1
        let streamer = makeStreamer(channelIDs: [7], transport: transport, tau: tau)
        streamer.submit([color(7, 1, 1, 1)], capturedAt: 0)

        streamer.step(now: 0)       // 1er pas : dt = 1/50 s
        streamer.step(now: 0.04)    // 2e pas : dt = 0,04 s
        let first = Double(channels(of: transport.datagrams[0])[0].r) / 65535
        let second = Double(channels(of: transport.datagrams[1])[0].r) / 65535

        let expectedFirst = 1 - exp(-0.02 / tau)
        let expectedSecond = expectedFirst + (1 - expectedFirst) * (1 - exp(-0.04 / tau))
        XCTAssertEqual(first, expectedFirst, accuracy: 1e-4)
        XCTAssertEqual(second, expectedSecond, accuracy: 1e-4)

        // Montée monotone puis convergence vers la cible.
        var previous = second
        var now = 0.04
        for _ in 0..<50 {
            now += 0.02
            streamer.step(now: now)
            let value = Double(channels(of: try XCTUnwrap(transport.datagrams.last))[0].r) / 65535
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        XCTAssertEqual(previous, 1, accuracy: 0.001)
    }

    func testStepIntervalIsClampedForSmoothing() throws {
        let transport = RecordingTransport()
        let tau = 1.0
        let streamer = makeStreamer(channelIDs: [0], transport: transport, tau: tau)
        streamer.step(now: 0)                       // noir, référence temporelle
        streamer.submit([color(0, 1, 0, 0)], capturedAt: 0)
        streamer.step(now: 100)                     // dt énorme → borné à 0,25 s
        let value = Double(channels(of: try XCTUnwrap(transport.datagrams.last))[0].r) / 65535
        XCTAssertEqual(value, 1 - exp(-0.25 / tau), accuracy: 1e-4)

        // Horloge qui recule : dt borné à 0 → aucune évolution.
        streamer.step(now: 50)
        let unchanged = Double(channels(of: try XCTUnwrap(transport.datagrams.last))[0].r) / 65535
        XCTAssertEqual(unchanged, value, accuracy: 1e-4)
    }

    func testLatencyDelaysTargets() throws {
        let transport = RecordingTransport()
        let streamer = makeStreamer(channelIDs: [0], transport: transport)
        streamer.latency = 0.5
        XCTAssertEqual(streamer.latency, 0.5)
        streamer.submit([color(0, 1, 0, 0)], capturedAt: 1.0)
        streamer.submit([color(0, 0, 0, 1)], capturedAt: 1.2)

        streamer.step(now: 1.2)     // aucune cible échue → noir
        XCTAssertEqual(channels(of: try XCTUnwrap(transport.datagrams.last))[0], DecodedChannel(id: 0, r: 0, g: 0, b: 0))

        streamer.step(now: 1.5)     // 1,0 ≤ 1,5 − 0,5 → rouge
        XCTAssertEqual(channels(of: try XCTUnwrap(transport.datagrams.last))[0], DecodedChannel(id: 0, r: 65535, g: 0, b: 0))

        streamer.step(now: 1.69)    // 1,2 > 1,19 → toujours rouge
        XCTAssertEqual(channels(of: try XCTUnwrap(transport.datagrams.last))[0], DecodedChannel(id: 0, r: 65535, g: 0, b: 0))

        streamer.step(now: 1.7)     // 1,2 ≤ 1,2 → bleu
        XCTAssertEqual(channels(of: try XCTUnwrap(transport.datagrams.last))[0], DecodedChannel(id: 0, r: 0, g: 0, b: 65535))
    }

    func testLatestDueTargetWinsAndOlderArePurged() throws {
        let transport = RecordingTransport()
        let streamer = makeStreamer(channelIDs: [0], transport: transport)
        // Soumises dans le désordre : l'ordre des instants fait foi.
        streamer.submit([color(0, 0, 1, 0)], capturedAt: 2)
        streamer.submit([color(0, 1, 0, 0)], capturedAt: 1)
        streamer.submit([color(0, 0, 0, 1)], capturedAt: 3)

        streamer.step(now: 2.5)
        XCTAssertEqual(channels(of: try XCTUnwrap(transport.datagrams.last))[0], DecodedChannel(id: 0, r: 0, g: 65535, b: 0))
        streamer.step(now: 3)
        XCTAssertEqual(channels(of: try XCTUnwrap(transport.datagrams.last))[0], DecodedChannel(id: 0, r: 0, g: 0, b: 65535))
    }

    func testNegativeOrInvalidLatencyIsClamped() {
        let transport = RecordingTransport()
        let streamer = makeStreamer(transport: transport)
        streamer.latency = -1
        XCTAssertEqual(streamer.latency, 0)
        streamer.latency = .nan
        XCTAssertEqual(streamer.latency, 0)
        streamer.smoothingTimeConstant = 0.35
        XCTAssertEqual(streamer.smoothingTimeConstant, 0.35)
    }

    func testAbsentChannelsKeepTheirLastTarget() throws {
        let transport = RecordingTransport()
        let streamer = makeStreamer(channelIDs: [1, 2], transport: transport)
        streamer.submit([color(1, 1, 0, 0), color(2, 1, 0, 0)], capturedAt: 0)
        streamer.step(now: 0)
        streamer.submit([color(2, 0, 0, 1), color(99, 0, 1, 0)], capturedAt: 0.1)   // canal 99 inconnu : ignoré
        streamer.step(now: 0.1)

        let decoded = channels(of: try XCTUnwrap(transport.datagrams.last))
        XCTAssertEqual(decoded, [DecodedChannel(id: 1, r: 65535, g: 0, b: 0),
                                 DecodedChannel(id: 2, r: 0, g: 0, b: 65535)])
    }

    func testMoreThanTwentyChannelsAreTruncatedByThePacket() throws {
        let transport = RecordingTransport()
        let streamer = makeStreamer(channelIDs: Array(0..<25), transport: transport)
        streamer.step(now: 0)
        XCTAssertEqual(channels(of: try XCTUnwrap(transport.datagrams.last)).count, HueStreamPacket.maxChannels)
    }

    func testStopPreventsFurtherSends() {
        let transport = RecordingTransport()
        let streamer = HueEntertainmentStreamer(areaID: areaID, channelIDs: [0], transport: transport)
        streamer.start()
        streamer.start()    // idempotent
        Thread.sleep(forTimeInterval: 0.1)
        streamer.stop()
        let countAtStop = transport.datagrams.count
        XCTAssertGreaterThan(countAtStop, 0)

        Thread.sleep(forTimeInterval: 0.1)
        streamer.step(now: 10)      // même un pas manuel n'envoie plus rien
        XCTAssertEqual(transport.datagrams.count, countAtStop)
        XCTAssertEqual(streamer.packetsSent, countAtStop)

        streamer.stop()     // idempotent

        // Redémarrage possible après un arrêt.
        streamer.start()
        Thread.sleep(forTimeInterval: 0.06)
        streamer.stop()
        XCTAssertGreaterThan(transport.datagrams.count, countAtStop)
    }

    func testStopWhileTickIsSendingDoesNotDeadlock() {
        let transport = RecordingTransport()
        let sending = DispatchSemaphore(value: 0)
        let didSignal = NSLock()
        var signaled = false
        transport.onSend = {
            didSignal.lock()
            let first = !signaled
            signaled = true
            didSignal.unlock()
            if first { sending.signal() }
            Thread.sleep(forTimeInterval: 0.05)     // envoi lent
        }
        let streamer = HueEntertainmentStreamer(areaID: areaID, channelIDs: [0], transport: transport)
        streamer.start()
        XCTAssertEqual(sending.wait(timeout: .now() + 2), .success)

        let stopped = expectation(description: "stop() rend la main")
        DispatchQueue.global().async {
            streamer.stop()     // pendant l'envoi en cours
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)

        let countAtStop = transport.datagrams.count
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(transport.datagrams.count, countAtStop)
    }

    func testStopFromInsideSendDoesNotDeadlock() {
        let transport = RecordingTransport()
        let streamer = HueEntertainmentStreamer(areaID: areaID, channelIDs: [0], transport: transport)
        let stopped = expectation(description: "stop() depuis send")
        stopped.assertForOverFulfill = false
        transport.onSend = { [weak streamer] in
            streamer?.stop()
            stopped.fulfill()
        }
        streamer.start()
        wait(for: [stopped], timeout: 2)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(transport.datagrams.count, 1)
    }

    func testRealPumpSendsAboutFiftyPacketsPerSecond() {
        let transport = RecordingTransport()
        let streamer = HueEntertainmentStreamer(areaID: areaID, channelIDs: [0, 1], transport: transport)
        streamer.submit([color(0, 1, 0, 0)], capturedAt: ProcessInfo.processInfo.systemUptime)
        streamer.start()
        Thread.sleep(forTimeInterval: 0.2)
        streamer.stop()

        let count = transport.datagrams.count
        // ≈ 10 paquets attendus ; marge large pour les machines chargées.
        XCTAssertGreaterThanOrEqual(count, 5)
        XCTAssertLessThanOrEqual(count, 16)
        XCTAssertEqual(streamer.packetsSent, count)
        let sequences = transport.datagrams.map(sequence(of:))
        XCTAssertEqual(sequences, (0..<count).map { UInt8($0 % 256) })
    }
}
