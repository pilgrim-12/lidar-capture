import Foundation
import ARKit
import RealityKit
import CoreImage
import UIKit

/// Records raw LiDAR capture: RGB JPEG + depth (uint16 mm) + confidence (uint8) + camera pose/intrinsics.
final class CaptureManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isRecording = false
    @Published var frameCount = 0
    @Published var status = "Наведите камеру на комнату"
    @Published var lastSessionURL: URL?
    @Published var showMesh = true { didSet { applyMeshOverlay() } }

    /// Seconds between saved frames (0.2 = 5 fps). Enough overlap for walking slowly.
    var interval: TimeInterval = 0.2

    private weak var arView: ARView?
    private let ioQueue = DispatchQueue(label: "capture.io", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var sessionDir: URL?
    private var framesDir: URL?
    private var poseHandle: FileHandle?
    private var lastSaved: TimeInterval = 0
    private var nextIndex = 0
    private var pending = 0
    private let lock = NSLock()

    // MARK: - Session

    func start(view: ARView) {
        arView = view
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            status = "На этом устройстве нет LiDAR"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh      // live mesh = coverage overlay
        }
        config.environmentTexturing = .none
        view.session.delegate = self
        view.session.run(config)
        applyMeshOverlay()
    }

    private func applyMeshOverlay() {
        guard let view = arView else { return }
        if showMesh { view.debugOptions.insert(.showSceneUnderstanding) }
        else { view.debugOptions.remove(.showSceneUnderstanding) }
    }

    // MARK: - Recording

    func toggleRecording() { isRecording ? stop() : begin() }

    private func begin() {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("scan_" + fmt.string(from: Date()))
        let frames = dir.appendingPathComponent("frames")
        do {
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            let posesURL = dir.appendingPathComponent("poses.jsonl")
            FileManager.default.createFile(atPath: posesURL.path, contents: nil)
            poseHandle = try FileHandle(forWritingTo: posesURL)
        } catch {
            status = "Ошибка создания папки: \(error.localizedDescription)"
            return
        }
        sessionDir = dir; framesDir = frames
        nextIndex = 0; lastSaved = 0; frameCount = 0
        writeMeta(to: dir)
        UIApplication.shared.isIdleTimerDisabled = true
        isRecording = true
        status = "Запись… ходите медленно"
    }

    private func stop() {
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        let dir = sessionDir
        ioQueue.async { [weak self] in
            try? self?.poseHandle?.close()
            self?.poseHandle = nil
            DispatchQueue.main.async {
                self?.lastSessionURL = dir
                self?.status = "Сохранено: \(dir?.lastPathComponent ?? "")"
            }
        }
    }

    private func writeMeta(to dir: URL) {
        let meta: [String: Any] = [
            "format": "lidarcapture-v1",
            "device": UIDevice.current.model,
            "system": UIDevice.current.systemVersion,
            "created": ISO8601DateFormatter().string(from: Date()),
            "interval_s": interval,
            "files": [
                "rgb": "frames/NNNNNN.jpg — raw sensor orientation (landscape), matches intrinsics",
                "depth": "frames/NNNNNN.depth — uint16 little-endian, millimetres, width x height from poses.jsonl (dw, dh); 0 = invalid",
                "conf": "frames/NNNNNN.conf — uint8 per depth pixel: 0 low, 1 medium, 2 high",
                "poses": "poses.jsonl — one JSON per frame: i, t, w, h, fx, fy, cx, cy (for RGB size), dw, dh, T (4x4 camera-to-world, column-major, ARKit: x right, y up, z back)"
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording, let framesDir = framesDir else { return }
        guard case .normal = frame.camera.trackingState else { return }   // skip frames with bad tracking
        guard frame.timestamp - lastSaved >= interval, let depth = frame.sceneDepth else { return }

        lock.lock()
        if pending > 4 { lock.unlock(); return }   // don't hold too many ARFrames (would stall ARKit)
        pending += 1
        lock.unlock()

        lastSaved = frame.timestamp
        let idx = nextIndex; nextIndex += 1
        let image = frame.capturedImage
        let depthMap = depth.depthMap
        let confMap = depth.confidenceMap
        let cam = frame.camera
        let T = cam.transform
        let K = cam.intrinsics
        let res = cam.imageResolution
        let ts = frame.timestamp

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let name = String(format: "%06d", idx)
            self.saveJPEG(image, to: framesDir.appendingPathComponent(name + ".jpg"))
            let (dw, dh) = self.saveDepth(depthMap, to: framesDir.appendingPathComponent(name + ".depth"))
            if let confMap = confMap { self.saveConfidence(confMap, to: framesDir.appendingPathComponent(name + ".conf")) }

            let c = T.columns
            let tArr: [Float] = [c.0.x, c.0.y, c.0.z, c.0.w, c.1.x, c.1.y, c.1.z, c.1.w,
                                 c.2.x, c.2.y, c.2.z, c.2.w, c.3.x, c.3.y, c.3.z, c.3.w]
            let rec: [String: Any] = [
                "i": idx, "t": ts,
                "w": Int(res.width), "h": Int(res.height),
                "fx": K[0][0], "fy": K[1][1], "cx": K[2][0], "cy": K[2][1],
                "dw": dw, "dh": dh, "T": tArr
            ]
            if let data = try? JSONSerialization.data(withJSONObject: rec) {
                self.poseHandle?.write(data)
                self.poseHandle?.write("\n".data(using: .utf8)!)
            }
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
            DispatchQueue.main.async { self.frameCount = idx + 1 }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal: if !isRecording { status = "Готово к записи" }
        case .limited(let r):
            switch r {
            case .excessiveMotion: status = "Слишком быстро — медленнее"
            case .insufficientFeatures: status = "Мало деталей в кадре"
            case .initializing, .relocalizing: status = "Инициализация…"
            @unknown default: status = "Трекинг ограничен"
            }
        case .notAvailable: status = "Трекинг недоступен"
        }
    }

    // MARK: - Writers

    private func saveJPEG(_ buffer: CVPixelBuffer, to url: URL) {
        let ci = CIImage(cvPixelBuffer: buffer)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let opts = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        if let data = ciContext.jpegRepresentation(of: ci, colorSpace: cs, options: opts) {
            try? data.write(to: url)
        }
    }

    /// Float32 metres -> uint16 millimetres.
    private func saveDepth(_ buffer: CVPixelBuffer, to url: URL) -> (Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (w, h) }
        var out = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                let m = row[x]
                out[y * w + x] = (m.isFinite && m > 0) ? UInt16(min(65535, (m * 1000).rounded())) : 0
            }
        }
        out.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: url) }
        return (w, h)
    }

    private func saveConfidence(_ buffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        var out = Data(capacity: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            out.append(row, count: w)
        }
        try? out.write(to: url)
    }
}
