import Testing
@testable import KDEConnectKit

struct TransferTrackerTests {
    private let start = ContinuousClock.now
    private let a = FileID(device: 1, inode: 10)
    private let b = FileID(device: 1, inode: 20)
    private let mb: Int64 = 1 << 20

    private func at(_ ms: Int) -> ContinuousClock.Instant { start + .milliseconds(ms) }

    @Test func followsOffsetsThroughEachFile() {
        var tracker = TransferTracker(files: [.init(id: a, size: 100 * mb), .init(id: b, size: 100 * mb)], start: start)
        #expect(tracker.update(offsets: [:], listening: true, now: at(100)) == .running)
        #expect(tracker.update(offsets: [a: 50 * mb], listening: true, now: at(200)) == .running)
        #expect(tracker.sentBytes == 50 * mb)
        #expect(tracker.currentIndex == 0)
        // The first file closed while the device connects for the second.
        #expect(tracker.update(offsets: [:], listening: true, now: at(300)) == .running)
        #expect(tracker.sentBytes == 100 * mb)
        #expect(tracker.update(offsets: [b: 25 * mb], listening: true, now: at(400)) == .running)
        #expect(tracker.currentIndex == 1)
        #expect(tracker.update(offsets: [:], listening: false, now: at(500)) == .finished)
    }

    @Test func aLaterFileFinishesTheEarlierOnes() {
        var tracker = TransferTracker(files: [.init(id: a, size: mb), .init(id: b, size: 100 * mb)], start: start)
        _ = tracker.update(offsets: [b: 10 * mb], listening: true, now: at(100))
        #expect(tracker.sentBytes == 11 * mb)
    }

    @Test func smallFilesMissedBetweenSnapshotsFinishWhenTheJobEnds() {
        var tracker = TransferTracker(files: [.init(id: a, size: mb)], start: start)
        #expect(tracker.update(offsets: [:], listening: true, now: at(100)) == .running)
        #expect(tracker.update(offsets: [:], listening: false, now: at(200)) == .running)
        #expect(tracker.update(offsets: [:], listening: false, now: at(1800)) == .finished)
        #expect(tracker.sentBytes == mb)
    }

    @Test func aLargeFileThatNeverOpenedFails() {
        var tracker = TransferTracker(files: [.init(id: a, size: 200 * mb)], start: start)
        _ = tracker.update(offsets: [:], listening: true, now: at(100))
        #expect(tracker.update(offsets: [:], listening: false, now: at(2000)) == .failed("The transfer did not finish."))
    }

    @Test func aDeviceThatNeverConnectsFails() {
        var tracker = TransferTracker(files: [.init(id: a, size: mb)], start: start)
        _ = tracker.update(offsets: [:], listening: true, now: at(100))
        _ = tracker.update(offsets: [:], listening: true, now: at(30_000))
        #expect(tracker.update(offsets: [:], listening: false, now: at(32_000)) == .failed("The device did not connect."))
    }

    @Test func waitsForTheJobBeforeGivingUp() {
        var tracker = TransferTracker(files: [.init(id: a, size: mb)], start: start)
        #expect(tracker.update(offsets: [:], listening: false, now: at(1000)) == .running)
        #expect(tracker.update(offsets: [:], listening: false, now: at(4100)) == .finished)
    }

    @Test func emptyFilesAndLinksNeedNoUpload() {
        var tracker = TransferTracker(files: [.init(id: nil, size: 0), .init(id: a, size: 0)], start: start)
        #expect(tracker.update(offsets: [:], listening: false, now: at(100)) == .finished)
    }
}
