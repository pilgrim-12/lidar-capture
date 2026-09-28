import SwiftUI
import RealityKit
import ARKit

struct ContentView: View {
    @StateObject private var cap = CaptureManager()
    @State private var shareURL: URL?
    @State private var exporting = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainer(cap: cap).ignoresSafeArea()

            VStack(spacing: 10) {
                Text(cap.status).font(.subheadline)
                Text("Кадров: \(cap.frameCount)").font(.title3.monospacedDigit())
                Toggle("Показывать сетку покрытия", isOn: $cap.showMesh).font(.footnote)
                HStack(spacing: 12) {
                    Button(action: { cap.toggleRecording() }) {
                        Text(cap.isRecording ? "Стоп" : "Запись")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(cap.isRecording ? Color.red : Color.green)
                            .foregroundColor(.white).cornerRadius(12)
                    }
                    Button(action: export) {
                        Text(exporting ? "Упаковка…" : "Экспорт")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.blue).foregroundColor(.white).cornerRadius(12)
                    }
                    .disabled(cap.isRecording || cap.lastSessionURL == nil || exporting)
                    .opacity(cap.isRecording || cap.lastSessionURL == nil ? 0.4 : 1)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .padding()
        }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
    }

    private func export() {
        guard let dir = cap.lastSessionURL else { return }
        exporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let zip = Exporter.zip(directory: dir)
            DispatchQueue.main.async {
                exporting = false
                shareURL = zip
            }
        }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct ARContainer: UIViewRepresentable {
    let cap: CaptureManager
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        cap.start(view: view)
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

enum Exporter {
    /// Zips a directory using the system's built-in "for uploading" coordinator (no third-party libs).
    static func zip(directory: URL) -> URL? {
        var result: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [.forUploading], error: &err) { zipURL in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(directory.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: zipURL, to: dest); result = dest } catch { result = nil }
        }
        return result
    }
}
