import AVFoundation
import Foundation
import Testing
@testable import Kaset

// MARK: - CanvasVideoViewTests

/// Regression coverage for the canvas player's readiness signal.
///
/// `AVPlayerLooper` enqueues its copies of the template item asynchronously, so
/// the queue is still empty immediately after
/// `AVPlayerLooper(player:templateItem:)` returns. Observing
/// `AVQueuePlayer.items().first` therefore falls back to the template item,
/// which is never enqueued and never leaves `.unknown` — the canvas then never
/// appears even though its video was resolved and downloaded.
///
/// Readiness itself is now reported when the player's timeline first moves,
/// because an item's `status == .readyToPlay` says nothing about whether frames
/// are being produced: streaming HLS reports it as soon as its playlist has
/// been read.
@Suite(.serialized, .tags(.integration))
@MainActor
struct CanvasVideoViewTests {
    @Test("the canvas player reports readiness once playback starts")
    func reportsReadyToPlay() async throws {
        let videoURL = try Self.makeTemporaryVideo()
        defer { try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent()) }

        let view = CanvasVideoNSView()
        var didBecomeReady = false
        var didFail = false
        view.onReadyToPlay = { didBecomeReady = true }
        view.onFailure = { didFail = true }

        view.load(url: videoURL)
        defer { view.teardown() }

        // Wait for AVFoundation to load the asset and the looper to enqueue it.
        let deadline = Date().addingTimeInterval(10)
        while !didBecomeReady, !didFail, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(didBecomeReady, "the canvas player never reported readiness")
        #expect(didFail == false)
        #expect(view.playerURL == videoURL)
    }

    @Test("a canvas that reported readiness is really playing")
    func readinessMeansPlaying() async throws {
        let videoURL = try Self.makeTemporaryVideo()
        defer { try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent()) }

        let view = CanvasVideoNSView()
        var didBecomeReady = false
        view.onReadyToPlay = { didBecomeReady = true }
        view.load(url: videoURL)
        defer { view.teardown() }

        let deadline = Date().addingTimeInterval(10)
        while !didBecomeReady, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(didBecomeReady)

        let firstSample = try #require(view.currentPlaybackTime)
        try await Task.sleep(for: .milliseconds(400))
        let secondSample = try #require(view.currentPlaybackTime)
        #expect(secondSample > firstSample, "readiness was reported but the timeline is not moving")
    }

    @Test("the canvas player keeps the stalling policy streaming canvases need")
    func keepsStallingPolicy() throws {
        let videoURL = try Self.makeTemporaryVideo()
        defer { try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent()) }

        let view = CanvasVideoNSView()
        view.load(url: videoURL)
        defer { view.teardown() }

        // Canvas videos resolved from Apple Music are remote, video-only HLS
        // streams. Disabling stalling minimization makes such a player settle
        // at rate 0 while still reporting `.playing`, so it draws one frame and
        // never advances — the canvas looks like a frozen album cover.
        #expect(view.waitsToMinimizeStalling, "the canvas player disabled waitsToMinimizeStalling")
    }

    @Test("tearing down clears the loaded URL so the view can be reused")
    func teardownResetsLoadedURL() throws {
        let videoURL = try Self.makeTemporaryVideo()
        defer { try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent()) }

        let view = CanvasVideoNSView()
        view.load(url: videoURL)
        #expect(view.playerURL == videoURL)

        view.teardown()
        #expect(view.playerURL == nil)
    }

    // MARK: - Fixtures

    /// Writes a tiny (30-frame, 128×128) H.264 clip into a fresh temp directory
    /// and returns its URL.
    private static func makeTemporaryVideo() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-canvas-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("canvas.mp4")
        try Self.writeTinyVideo(to: url)
        return url
    }

    private static func writeTinyVideo(to url: URL) throws {
        let side = 128
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            side,
            side,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard let pixelBuffer = buffer else {
            throw CanvasTestVideoError.pixelBufferCreationFailed
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x40, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let framesPerSecond: Int32 = 30
        for frame in 0 ..< 30 {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            _ = adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
        }
        input.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        guard writer.status == .completed else {
            throw writer.error ?? CanvasTestVideoError.writerFailed
        }
    }
}

private enum CanvasTestVideoError: Error {
    case pixelBufferCreationFailed
    case writerFailed
}
