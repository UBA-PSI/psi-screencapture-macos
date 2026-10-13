// screenrec.swift
// Records every connected display, each with system audio, using ScreenCaptureKit.
// Runs on macOS 13 and later. Does not change any audio or video device and opens neither camera nor microphone.
//
// Build (universal binary, runs on macOS 13 and later; needs the Xcode Command Line Tools):
//   ./build.sh
//
// Usage:
//   ./screenrec --list
//   ./screenrec -o ~/Recordings -p lecture        (stop with Ctrl-C)
//
// Each display yields <prefix>_<date>_displayN.mov (HEVC + AAC system audio) and a .json file
// with the start time of the file in host time (mach_absolute_time) and Unix time.
// If a stream fails or the display configuration changes, a new file begins.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

let usage = """
Usage: screenrec [options]
  -o, --out DIR       output directory (default: current directory)
  -p, --prefix NAME   file name prefix (default: rec)
      --fps N         maximum frame rate (default: 15)
      --max-height N  limit the frame height to N pixels, keeping the aspect ratio (default: 1080, 0 = native)
      --scale F       fixed scale 0 < F <= 1 relative to the native pixel resolution, replaces --max-height
      --codec C       hevc | h264 (default: hevc, or h264 without a hardware HEVC encoder)
      --bitrate KBPS  video bit rate in kbit/s (default: estimated from resolution and fps)
      --no-cursor     do not record the mouse pointer
      --allow-sleep   do not keep the Mac and its displays awake while recording
      --list          print the detected displays and exit
Stop with Ctrl-C (SIGINT), SIGTERM or SIGHUP. The files are finalized then.
After a stream failure or a change of the displays, a new file begins automatically.
"""

func log(_ msg: String) {
    // fputs instead of FileHandle: does not throw once the terminal is gone (SIGHUP).
    fputs("[screenrec] \(msg)\n", stderr)
}

struct RecError: LocalizedError {
    let errorDescription: String?
}

/// Error text without pointer addresses, so that equal errors look equal.
func brief(_ error: Error?) -> String {
    guard let e = error as NSError? else { return "unknown error" }
    let cause = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { ", \($0.localizedDescription)" } ?? ""
    return "\(e.localizedDescription)\(cause)"
}

struct Options {
    var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var prefix = "rec"
    var fps: Int32 = 15
    var maxHeight = 1080
    var scale: Double?
    var codec: AVVideoCodecType = .hevc
    var codecExplicit = false
    var bitrate: Int?
    var cursor = true
    var keepAwake = true
    var list = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func fail(_ msg: String) -> Never {
        log(msg)
        print(usage)
        exit(2)
    }
    while let a = args.next() {
        switch a {
        case "-o", "--out":
            guard let v = args.next() else { fail("--out needs a directory") }
            o.outDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        case "-p", "--prefix":
            guard let v = args.next() else { fail("--prefix needs a name") }
            o.prefix = v
        case "--fps":
            guard let v = args.next(), let n = Int32(v), n > 0, n <= 120 else { fail("--fps: 1 to 120") }
            o.fps = n
        case "--max-height":
            guard let v = args.next(), let n = Int(v), n >= 0 else { fail("--max-height: pixels, 0 = native") }
            o.maxHeight = n
        case "--scale":
            guard let v = args.next(), let s = Double(v), s > 0, s <= 1 else { fail("--scale: 0 < F <= 1") }
            o.scale = s
        case "--codec":
            guard let v = args.next(), v == "hevc" || v == "h264" else { fail("--codec: hevc or h264") }
            o.codec = (v == "h264") ? .h264 : .hevc
            o.codecExplicit = true
        case "--bitrate":
            guard let v = args.next(), let n = Int(v), n > 0 else { fail("--bitrate in kbit/s") }
            o.bitrate = n * 1000
        case "--no-cursor":
            o.cursor = false
        case "--allow-sleep":
            o.keepAwake = false
        case "--list":
            o.list = true
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("Unknown option: \(a)")
        }
    }
    return o
}

/// Whether VideoToolbox offers a hardware encoder for the codec. `true` if the answer is unclear.
func hasHardwareEncoder(_ codec: CMVideoCodecType) -> Bool {
    var list: CFArray?
    guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[CFString: Any]] else {
        return true
    }
    return encoders.contains {
        ($0[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value == codec
            && ($0[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool) == true
    }
}

/// Stop request by signal.
/// Before `arm()` there is nothing to finalize, so a signal ends the process immediately.
final class StopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var armed = false
    private var requested = false

    init() {
        signal(SIGPIPE, SIG_IGN)
        let q = DispatchQueue(label: "screenrec.signals")
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
            src.setEventHandler { [unowned self] in self.trigger() }
            src.resume()
            sources.append(src)
        }
    }

    var isRequested: Bool { lock.withLock { requested } }

    func arm() { lock.withLock { armed = true } }

    private func trigger() {
        let wasArmed = lock.withLock { () -> Bool in
            requested = true
            return armed
        }
        if !wasArmed {
            log("Interrupted before the recording started.")
            exit(130)
        }
    }
}

/// Displays to record, main display (origin 0/0) first. Mirrored displays cover the same area,
/// only one of them is kept. Deliberately derived from ScreenCaptureKit data only.
func recordable(_ all: [SCDisplay]) -> [SCDisplay] {
    let sorted = all.sorted { a, b in
        let (am, bm) = (a.frame.origin == .zero, b.frame.origin == .zero)
        return am != bm ? am : a.displayID < b.displayID
    }
    var kept: [SCDisplay] = []
    for d in sorted where !kept.contains(where: { $0.frame.intersects(d.frame) }) {
        kept.append(d)
    }
    return kept
}

final class DisplayRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let index: Int
    let display: SCDisplay
    let opts: Options
    let startedAt = Date()
    let width: Int
    let height: Int
    let fileURL: URL
    let sidecarURL: URL

    // All state below is only changed on `queue`, `finishTask` and `streamDead` only under `finishLock`.
    private let queue: DispatchQueue
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let videoIn: AVAssetWriterInput
    private let audioIn: AVAssetWriterInput
    private var sessionStart: CMTime?
    private var sessionStartUnix: Double?
    private var firstAudioPTS: CMTime?
    private var lastFrame: CMSampleBuffer?
    private var finishing = false
    private var failed = false
    private var videoFrames = 0
    private var droppedVideo = 0
    private var droppedAudio = 0
    private let finishLock = NSLock()
    private var finishTask: Task<Void, Never>?
    private var streamDead = false

    /// `true` once finishing has begun, from outside or because of an error.
    var isEnding: Bool { finishLock.withLock { finishTask != nil } }

    static func pixelSize(_ d: SCDisplay) -> (Int, Int) {
        if let mode = CGDisplayCopyDisplayMode(d.displayID) {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (d.width, d.height)
    }

    private static func even(_ v: Double) -> Int { max(2, Int(v) & ~1) }

    init(index: Int, display: SCDisplay, opts: Options, baseName: String) throws {
        self.index = index
        self.display = display
        self.opts = opts
        queue = DispatchQueue(label: "screenrec.display\(index)", qos: .userInitiated)

        let (pw, ph) = DisplayRecorder.pixelSize(display)
        let scale = opts.scale
            ?? (opts.maxHeight > 0 ? min(1, Double(opts.maxHeight) / Double(ph)) : 1)
        width = DisplayRecorder.even((Double(pw) * scale).rounded())
        height = DisplayRecorder.even((Double(ph) * scale).rounded())

        // AVAssetWriter does not overwrite. On a restart within the same second the name gets a suffix.
        var name = "\(baseName)_display\(index)"
        var n = 2
        while FileManager.default.fileExists(atPath: opts.outDir.appendingPathComponent("\(name).mov").path) {
            name = "\(baseName)-\(n)_display\(index)"
            n += 1
        }
        fileURL = opts.outDir.appendingPathComponent("\(name).mov")
        sidecarURL = opts.outDir.appendingPathComponent("\(name).json")

        writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)
        // Fragmented writing: after a crash the file stays readable up to the last fragment.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let bitsPerPixel = opts.codec == .hevc ? 0.08 : 0.15
        let bitrate = opts.bitrate
            ?? max(1_000_000, Int(Double(width * height) * Double(opts.fps) * bitsPerPixel))

        videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: opts.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Matches colorSpaceName/colorMatrix of the stream (sRGB, tagged as BT.709).
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: opts.fps,
                AVVideoMaxKeyFrameIntervalKey: Int(opts.fps) * 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ])
        videoIn.expectsMediaDataInRealTime = true

        audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ])
        audioIn.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoIn), writer.canAdd(audioIn) else {
            throw RecError(errorDescription: "AVAssetWriter does not accept the tracks")
        }
        writer.add(videoIn)
        writer.add(audioIn)
        super.init()
    }

    func start() async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: opts.fps)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Fixed SDR color space instead of the display default: P3 and HDR displays are converted to sRGB.
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.queueDepth = 6
        cfg.showsCursor = opts.cursor
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        // Do not exclude: "current process" covers the whole terminal app including its child processes,
        // whose audio would otherwise be missing. screenrec itself plays no sound.
        cfg.excludesCurrentProcessAudio = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        guard writer.startWriting() else {
            throw RecError(errorDescription: "cannot create file: \(brief(writer.error))")
        }
        stream = s
        do {
            try await s.startCapture()
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, !failed, sb.isValid else { return }
        guard writer.status == .writing else {
            failed = true
            log("display\(index): writer error (\(brief(writer.error))), recording of this display ends")
            endedOnItsOwn()
            return
        }

        switch type {
        case .screen:
            // ScreenCaptureKit also delivers status buffers without an image (idle, blank). Write complete frames only.
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let raw = attachments.first?[.status] as? Int,
                SCFrameStatus(rawValue: raw) == .complete
            else { return }

            if sessionStart == nil {
                let pts = sb.presentationTimeStamp
                writer.startSession(atSourceTime: pts)
                sessionStart = pts
                sessionStartUnix = Date().timeIntervalSince1970
                    - (CMClockGetTime(CMClockGetHostTimeClock()) - pts).seconds
                writeSidecar(final: false)
            }
            if videoIn.isReadyForMoreMediaData, videoIn.append(sb) {
                videoFrames += 1
                lastFrame = sb
            } else {
                droppedVideo += 1
            }

        case .audio:
            guard sessionStart != nil else { return }
            if firstAudioPTS == nil { firstAudioPTS = sb.presentationTimeStamp }
            if !(audioIn.isReadyForMoreMediaData && audioIn.append(sb)) {
                droppedAudio += 1
            }

        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("display\(index): stream stopped (\(error.localizedDescription)), finalizing the file")
        finishLock.withLock { streamDead = true }
        endedOnItsOwn()
    }

    /// The reconciliation in main() sees `isEnding` and starts a new recorder if needed.
    private func endedOnItsOwn() {
        Task { await self.finish() }
    }

    // MARK: Finishing

    func finish() async {
        // Own lock instead of `queue`: this way finish() never waits for a running sample callback.
        let task: Task<Void, Never> = finishLock.withLock {
            if let t = finishTask { return t }
            let t = Task { await self.doFinish() }
            finishTask = t
            return t
        }
        await task.value
    }

    private func doFinish() async {
        // Take the time before stopCapture(): stopping takes about a second in which no more audio arrives.
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let dead = finishLock.withLock { streamDead }
        if !dead, let s = stream { try? await s.stopCapture() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finishing = true
                guard self.writer.status == .writing, self.sessionStart != nil else {
                    if self.writer.status == .writing {
                        self.writer.cancelWriting()
                        log("display\(self.index): no frames received, no file written")
                    } else {
                        log("display\(self.index): not finalized (\(brief(self.writer.error))). Readable up to the last fragment.")
                    }
                    c.resume()
                    return
                }
                // Write the last frame once more at the stop time. Otherwise the video track ends at the
                // last screen change and, with a static screen, is shorter than the audio track.
                // With a fixed duration; without one the writer reuses the duration of the previous frame.
                let frame = CMTime(value: 1, timescale: self.opts.fps)
                if let last = self.lastFrame, end - frame > last.presentationTimeStamp, self.videoIn.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: frame, presentationTimeStamp: end - frame, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(
                        allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy {
                        self.videoIn.append(copy)
                    }
                }
                self.lastFrame = nil
                self.videoIn.markAsFinished()
                self.audioIn.markAsFinished()
                self.writer.finishWriting {
                    self.queue.async {
                        let ok = self.writer.status == .completed
                        if !ok {
                            log("display\(self.index): error while finalizing: \(brief(self.writer.error))")
                        }
                        self.writeSidecar(final: ok)
                        log("display\(self.index): \(self.videoFrames) frames, dropped: \(self.droppedVideo) video / \(self.droppedAudio) audio")
                        c.resume()
                    }
                }
            }
        }
    }

    private func writeSidecar(final: Bool) {
        func host(_ t: CMTime?) -> Any { t.map { $0.seconds } ?? NSNull() }

        let info: [String: Any] = [
            "file": fileURL.lastPathComponent,
            "display_index": index,
            "display_id": display.displayID,
            "width": width,
            "height": height,
            "max_fps": opts.fps,
            "codec": opts.codec.rawValue,
            "clock": "host time (mach_absolute_time) in s, same base as time.monotonic() in Python on macOS",
            "file_t0_host": host(sessionStart),
            "file_t0_unix": sessionStartUnix ?? NSNull(),
            "first_audio_host": host(firstAudioPTS),
            "video_frames": videoFrames,
            "video_frames_dropped": droppedVideo,
            "audio_buffers_dropped": droppedAudio,
            "finalized": final,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sidecarURL)
        }
    }
}

@main
struct ScreenRec {
    static func main() async {
        var opts = parseOptions()
        let stop = StopRequest()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let app = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
            log("No access to screen recording: \(error.localizedDescription) (\((error as NSError).code))")
            log("The permission belongs to the app that screenrec is started from (here: \(app)).")
            log("System Settings > Privacy & Security > Screen & System Audio Recording: allow that app, then quit and restart it.")
            exit(1)
        }

        let displays = recordable(content.displays)
        guard !displays.isEmpty else {
            log("No displays found.")
            exit(1)
        }

        if opts.list {
            for (i, d) in displays.enumerated() {
                let (pw, ph) = DisplayRecorder.pixelSize(d)
                let main = d.frame.origin == .zero ? ", main display" : ""
                print("display\(i): ID \(d.displayID), \(pw)x\(ph) px\(main)")
            }
            for d in content.displays where !displays.contains(where: { $0.displayID == d.displayID }) {
                print("not recorded: ID \(d.displayID) (mirror)")
            }
            exit(0)
        }

        if opts.codec == .hevc, !hasHardwareEncoder(kCMVideoCodecType_HEVC) {
            if opts.codecExplicit {
                log("Warning: no hardware HEVC encoder, HEVC runs in software (high CPU load).")
            } else {
                log("No hardware HEVC encoder found, using H.264.")
                opts.codec = .h264
            }
        }

        do {
            try FileManager.default.createDirectory(at: opts.outDir, withIntermediateDirectories: true)
        } catch {
            log("Output directory: \(error.localizedDescription)")
            exit(1)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        // Prevents idle sleep and idle display sleep for as long as the process runs.
        // Changes no setting, the system releases the assertion when the process ends.
        let awake = opts.keepAwake
            ? ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "screenrec: recording")
            : nil

        // From here on a signal leads to an orderly stop instead of an immediate exit.
        stop.arm()
        var live: [CGDirectDisplayID: DisplayRecorder] = [:]
        var retired: [DisplayRecorder] = []
        var retryAfter: [CGDirectDisplayID: Date] = [:]
        var lastProblem = ""
        var nextScan = Date.distantPast
        var firstScan = true

        // Print repeated identical error messages (e.g. disk full, every 2 s) only once.
        func problem(_ msg: String) {
            if msg != lastProblem { log(msg) }
            lastProblem = msg
        }
        func retire(_ id: CGDirectDisplayID) {
            guard let r = live.removeValue(forKey: id) else { return }
            // After a very short recording wait briefly, so that a persistent error does not flood the disk with files.
            if Date().timeIntervalSince(r.startedAt) < 5 { retryAfter[id] = Date().addingTimeInterval(2) }
            retired.append(r)
            Task { await r.finish() }
        }

        // Reconcile the desired state (present displays) with the actual state (running recorders):
        // every 2 s, and immediately when a recorder has ended on its own.
        while !stop.isRequested {
            let ended = live.filter { $0.value.isEnding }.map(\.key)
            if !ended.isEmpty || Date() >= nextScan {
                ended.forEach(retire)
                nextScan = Date().addingTimeInterval(2)

                var current = displays
                if !firstScan {
                    do {
                        current = recordable(try await SCShareableContent
                            .excludingDesktopWindows(true, onScreenWindowsOnly: true).displays)
                    } catch {
                        problem("Cannot query displays: \(brief(error))")
                        continue
                    }
                }
                for (id, r) in live where !current.contains(where: { $0.displayID == id }) {
                    log("display\(r.index): display is gone or mirrored now, finalizing the file")
                    retire(id)
                }
                let baseName = "\(opts.prefix)_\(df.string(from: Date()))"
                for (i, d) in current.enumerated() where live[d.displayID] == nil && !stop.isRequested {
                    if let t = retryAfter[d.displayID], Date() < t { continue }
                    do {
                        let r = try DisplayRecorder(index: i, display: d, opts: opts, baseName: baseName)
                        try await r.start()
                        live[d.displayID] = r
                        lastProblem = ""
                        log("display\(i): \(r.width)x\(r.height), max \(opts.fps) fps, \(opts.codec == .hevc ? "HEVC" : "H.264") -> \(r.fileURL.path)")
                    } catch {
                        retryAfter[d.displayID] = Date().addingTimeInterval(2)
                        problem("display\(i): start failed: \(brief(error))")
                    }
                }
                if firstScan {
                    guard !live.isEmpty else { exit(stop.isRequested ? 130 : 1) }
                    if !stop.isRequested { log("Recording. Stop with Ctrl-C.") }
                    firstScan = false
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        log("Stopping and finalizing ...")
        // If ScreenCaptureKit hangs while stopping, do not wait forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            log("Finalizing hangs, giving up. The files are readable up to the last fragment.")
            exit(1)
        }
        let all = retired + live.values
        await withTaskGroup(of: Void.self) { group in
            for r in all { group.addTask { await r.finish() } }
        }
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        log("Done.")
        exit(0)
    }
}
