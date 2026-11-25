import AppKit
import SwiftUI

// Self-contained: frame.py ships inside the .app, the Python env is built per Mac on first run.
// FRAME_DEPLOY_HOME lets screenshots and tests run against a throwaway home.
let homeDir = ProcessInfo.processInfo.environment["FRAME_DEPLOY_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
let venvDir = homeDir.appending(path: ".frame-deploy/venv")
let pythonBin = venvDir.appending(path: "bin/python")
let coreScript = Bundle.main.url(forResource: "frame", withExtension: "py")!
let galleryDir = homeDir.appending(path: "Pictures/Frame Gallery")

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do { try proc.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// First run on a new Mac: venv + samsungtvws via the system python3 (needs Xcode command line tools).
func ensurePython() -> String? {
    if FileManager.default.fileExists(atPath: pythonBin.path) { return nil }
    let (c1, o1) = run("/usr/bin/python3", ["-m", "venv", venvDir.path])
    if c1 != 0 { return "Python setup failed (install Xcode command line tools: xcode-select --install): \(o1)" }
    let (c2, o2) = run(pythonBin.path, ["-m", "pip", "install", "-q", "samsungtvws"])
    if c2 != 0 { try? FileManager.default.removeItem(at: venvDir); return "pip install failed: \(o2)" }
    return nil
}

/// Runs `frame.py <args>` and returns (exit code, combined output).
func runCore(_ args: [String]) -> (Int32, String) {
    if let err = ensurePython() { return (-1, err) }
    let proc = Process()
    proc.executableURL = pythonBin
    proc.arguments = [coreScript.path] + args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do { try proc.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
}

struct Meta: Decodable {
    let file, title, artist, date, licence, source, ratio: String
    let width, height: Int
    let native: Bool
}

@MainActor
final class GalleryModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var selected: URL?
    @Published var query = ""
    @Published var status = "Pick a picture, then Deploy."
    @Published var busy = false
    @Published var devices: [String] = []
    @Published var active = ""
    @Published var meta: [String: Meta] = [:]

    /// Title/artist/date/ratio for every picture, from `frame.py info`.
    func loadMeta() {
        Task {
            let (code, out) = await Task.detached { runCore(["info"]) }.value
            guard code == 0, let line = out.split(separator: "\n").last,
                  let rows = try? JSONDecoder().decode([Meta].self, from: Data(line.utf8)) else { return }
            meta = Dictionary(uniqueKeysWithValues: rows.map { ($0.file, $0) })
        }
    }

    func loadDevices() {
        Task {
            let (code, out) = await Task.detached { runCore(["devices"]) }.value
            guard code == 0, let line = out.split(separator: "\n").last,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                status = "Error: \(out.split(separator: "\n").last.map(String.init) ?? out)"
                return
            }
            devices = (obj["devices"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            active = obj["active"] as? String ?? ""
        }
    }

    func use(_ name: String) {
        active = name
        Task { _ = await Task.detached { runCore(["use", name]) }.value }
    }

    @Published var found: [(ip: String, name: String, model: String)] = []
    @Published var scanning = false

    /// Last non-warning line of core output.
    private func lastLine(_ out: String) -> String {
        out.split(separator: "\n").last.map(String.init) ?? out
    }

    func scan() {
        scanning = true
        found = []
        Task {
            let (code, out) = await Task.detached { runCore(["scan"]) }.value
            scanning = false
            guard code == 0, let line = out.split(separator: "\n").last,
                  let arr = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: String]] else {
                status = "Scan failed: \(lastLine(out))"
                return
            }
            found = arr.map { ($0["ip"] ?? "", $0["name"] ?? "", $0["model"] ?? "") }
        }
    }

    /// Pairs a TV; calls back with nil on success or an error message.
    func add(name: String, ip: String, done: @escaping (String?) -> Void) {
        busy = true
        Task {
            let (code, out) = await Task.detached { runCore(["add", name, ip]) }.value
            busy = false
            if code == 0 { status = "Added \(name). It is now the active device."; loadDevices() }
            done(code == 0 ? nil : lastLine(out))
        }
    }

    func remove(_ name: String) {
        perform(["remove", name], success: "Removed \(name).") { self.loadDevices() }
    }

    func reload() {
        let exts = ["jpg", "jpeg", "png"]
        let urls = (try? FileManager.default.contentsOfDirectory(at: galleryDir, includingPropertiesForKeys: nil)) ?? []
        files = urls
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let sel = selected, !files.contains(sel) { selected = nil }
        loadMeta()
    }

    /// Licence/source text saved beside a fetched image.
    var selectedInfo: String {
        guard let sel = selected else { return "" }
        let txt = sel.deletingPathExtension().appendingPathExtension("txt")
        return (try? String(contentsOf: txt, encoding: .utf8)) ?? "No licence info saved for this image."
    }

    func deploy() {
        guard let sel = selected else { return }
        perform(["deploy", sel.lastPathComponent, "--device", active], success: "Deployed \(sel.lastPathComponent) to \(active).")
    }

    func fetch() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        perform(["fetch", term], success: "Fetched a picture for \"\(term)\".")
    }

    private func perform(_ args: [String], success: String, then: (() -> Void)? = nil) {
        busy = true
        status = "Working…"
        Task {
            let (code, out) = await Task.detached { runCore(args) }.value
            busy = false
            let lastLine = out.split(separator: "\n").last.map(String.init) ?? ""
            status = code == 0 ? success : "Error: \(lastLine.isEmpty ? out : lastLine)"
            reload()
            then?()
        }
    }
}

struct ContentView: View {
    @StateObject private var model = GalleryModel()
    @State private var adding = false
    @State private var newName = ""
    @State private var newIP = ""
    @State private var addError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search Wikimedia Commons, e.g. Monet water lilies", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.fetch() }
                Button("Fetch") { model.fetch() }
                    .disabled(model.busy || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.files.isEmpty {
                Spacer()
                Text("No pictures yet. Fetch one above or drop images into ~/Pictures/Frame Gallery.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(model.files, id: \.self) { url in
                            ThumbnailCell(url: url, meta: model.meta[url.lastPathComponent], selected: model.selected == url)
                                .onTapGesture { model.selected = url }
                        }
                    }
                }
            }

            if let sel = model.selected {
                if let m = model.meta[sel.lastPathComponent] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).font(.headline).lineLimit(1)
                        Text("\(m.artist)  ·  \(m.date)").font(.subheadline)
                        HStack(spacing: 4) {
                            Image(systemName: m.native ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(m.native ? .green : .orange)
                            Text("\(m.width)×\(m.height)  ·  \(m.ratio)  ·  " + (m.native
                                 ? "native Frame ratio (16:9)"
                                 : "not 16:9: shown inside a black matte on older Frames, scaled by the TV on newer ones"))
                        }
                        .font(.caption)
                        Text(m.licence.isEmpty ? "No licence info saved for this image." : "Licence: \(m.licence)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(model.selectedInfo).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }

            HStack {
                Text(model.status)
                    .lineLimit(2)
                    .foregroundStyle(model.status.hasPrefix("Error") ? .red : .primary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if !model.devices.isEmpty {
                    Picker("", selection: Binding(get: { model.active }, set: { model.use($0) })) {
                        ForEach(model.devices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    Button("Remove") { model.remove(model.active) }.disabled(model.busy)
                }
                Button("Add device…") { adding = true }.disabled(model.busy)
                Button(model.active.isEmpty ? "Deploy" : "Deploy to \(model.active)") { model.deploy() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected == nil || model.busy || model.active.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            model.reload()
            model.loadDevices()
            if let out = ProcessInfo.processInfo.environment["FRAME_DEPLOY_SHOT"] { snapshot(model, to: out) }
        }
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a Frame").font(.headline)
                HStack {
                    Button(model.scanning ? "Scanning…" : "Scan network") { model.scan() }
                        .disabled(model.scanning || model.busy)
                    if model.scanning { ProgressView().controlSize(.small) }
                }
                ForEach(model.found, id: \.ip) { tv in
                    Button("\(tv.name) – \(tv.model) – \(tv.ip)") {
                        newIP = tv.ip
                        if newName.isEmpty { newName = tv.name.replacingOccurrences(of: "[TV] ", with: "") }
                    }
                    .buttonStyle(.link)
                }
                if !model.scanning && model.found.isEmpty {
                    Text("Nothing found yet. Scan, or type the IP from TV Settings > Network.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Name, e.g. Living Room", text: $newName)
                TextField("TV IP address", text: $newIP)
                if model.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Pairing… accept the 'Allow' prompt on the TV (up to 60 s).").font(.caption)
                    }
                }
                if !addError.isEmpty {
                    Text(addError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { adding = false }.disabled(model.busy)
                    Button("Add") {
                        addError = ""
                        model.add(name: newName.trimmingCharacters(in: .whitespaces),
                                  ip: newIP.trimmingCharacters(in: .whitespaces)) { err in
                            if let err { addError = err } else { adding = false; newName = ""; newIP = "" }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newIP.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding()
            .frame(width: 440)
        }
    }
}

/// Draws the app's own window to a PNG (no screen-recording permission needed), then quits.
@MainActor func snapshot(_ model: GalleryModel, to path: String) {
    NSApp.appearance = NSAppearance(named: .aqua)
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        model.selected = model.files.first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let v = NSApp.windows.first?.contentView?.superview,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

struct ThumbnailCell: View {
    let url: URL
    let meta: Meta?
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if let m = meta {
                    HStack(spacing: 3) {
                        Image(systemName: m.native ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        Text(m.ratio)
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(m.native ? Color.green : Color.orange, in: Capsule())
                    .padding(4)
                }
            }
            Text(meta?.title ?? url.deletingPathExtension().lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
            if let m = meta {
                Text(m.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(6)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
    }
}

@main
struct FrameDeployApp: App {
    var body: some Scene {
        WindowGroup("Frame Deploy") {
            ContentView()
        }
    }
}
