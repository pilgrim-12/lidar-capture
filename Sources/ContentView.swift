import SwiftUI
import RealityKit
import ARKit

struct ContentView: View {
    @StateObject private var cap = CaptureManager()
    @StateObject private var store = SessionStore()
    @State private var showList = false
    @State private var askName = false
    @State private var newName = ""
    @State private var pendingURL: URL?

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
                    Button(action: { store.reload(); showList = true }) {
                        Text("Сканы (\(store.sessions.count))")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.blue).foregroundColor(.white).cornerRadius(12)
                    }
                    .disabled(cap.isRecording)
                    .opacity(cap.isRecording ? 0.4 : 1)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .padding()
        }
        .onAppear { store.reload() }
        .onChange(of: cap.lastSessionURL) { url in
            guard let url = url else { return }
            pendingURL = url
            let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
            newName = "Скан " + f.string(from: Date())
            askName = true
        }
        .alert("Название скана", isPresented: $askName) {
            TextField("Например: Кухня", text: $newName)
            Button("Сохранить") {
                if let u = pendingURL { store.rename(url: u, to: newName.isEmpty ? u.lastPathComponent : newName) }
                store.reload()
            }
        } message: {
            Text("Скан сохранён. Название можно изменить позже в списке.")
        }
        .sheet(isPresented: $showList) {
            SessionListView(store: store)
        }
    }
}

// MARK: - List of scans

struct SessionListView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var renaming: ScanSession?
    @State private var renameText = ""
    @State private var shareItems: [URL] = []
    @State private var showShare = false
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if store.sessions.isEmpty {
                    Text("Пока нет сканов. Нажмите «Запись» на главном экране.").foregroundColor(.secondary)
                }
                ForEach(store.sessions) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.name).font(.headline)
                        Text("\(Self.dateText(s.date)) · \(s.frames) кадров · \(Self.sizeText(s.bytes))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .tag(s.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard editMode == .inactive else { return }
                        renaming = s; renameText = s.name
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.delete(s) } label: { Label("Удалить", systemImage: "trash") }
                        Button { export([s]) } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }.tint(.blue)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Сканы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(editMode == .active ? "Готово" : "Выбрать") {
                        editMode = editMode == .active ? .inactive : .active
                        if editMode == .inactive { selection.removeAll() }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if editMode == .active {
                        Button(role: .destructive) {
                            for s in store.sessions where selection.contains(s.id) { try? FileManager.default.removeItem(at: s.url) }
                            selection.removeAll(); store.reload()
                        } label: { Text("Удалить (\(selection.count))") }
                        .disabled(selection.isEmpty)
                        Spacer()
                        Button(exporting ? "Упаковка…" : "Экспорт (\(selection.count))") {
                            export(store.sessions.filter { selection.contains($0.id) })
                        }
                        .disabled(selection.isEmpty || exporting)
                    } else {
                        Text("Нажмите на скан, чтобы переименовать · свайп влево — экспорт/удаление")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Название", text: $renameText)
                Button("Сохранить") { if let s = renaming { store.rename(s, to: renameText) }; renaming = nil }
                Button("Отмена", role: .cancel) { renaming = nil }
            }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
            .onAppear { store.reload() }
        }
    }

    private func export(_ list: [ScanSession]) {
        guard !list.isEmpty else { return }
        exporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = list.compactMap { Exporter.zip(directory: $0.url, fileName: SessionStore.safeFileName($0.name)) }
            DispatchQueue.main.async {
                exporting = false
                shareItems = urls
                showShare = !urls.isEmpty
            }
        }
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; return f.string(from: d)
    }
    static func sizeText(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

// MARK: - AR view, share sheet, zip

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
    static func zip(directory: URL, fileName: String? = nil) -> URL? {
        var result: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [.forUploading], error: &err) { zipURL in
            let base = fileName ?? directory.lastPathComponent
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(base + ".zip")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: zipURL, to: dest); result = dest } catch { result = nil }
        }
        return result
    }
}
