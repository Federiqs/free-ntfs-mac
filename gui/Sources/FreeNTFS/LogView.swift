import SwiftUI
import AppKit
import Combine
import FreeNTFSCore

struct LogView: View {
    private enum Source: String, CaseIterable, Identifiable {
        case daemon, mount
        var id: String { rawValue }
        var path: String { self == .daemon ? Paths.daemonLog : Paths.mountLog }
        var title: String { self == .daemon ? "Auto-mount service" : "Last ntfs-mount run" }
    }

    @State private var source: Source = .daemon
    @State private var text = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(source.path).font(.caption).foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "(empty or not readable)" : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) { _ in proxy.scrollTo("bottom") }
                .onAppear { proxy.scrollTo("bottom") }
            }

            HStack {
                Text("The service's messages come from the scripts themselves, in Italian.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
                }
                Button("Open in Console") {
                    let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
                    NSWorkspace.shared.open([URL(fileURLWithPath: source.path)], withApplicationAt: console,
                                            configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear(perform: load)
        .onChange(of: source) { _ in load() }
        .onReceive(timer) { _ in load() }
    }

    private func load() {
        let new = AutowatchLog.tail(ofFile: source.path, maxBytes: 64 * 1024) ?? ""
        if new != text { text = new }
    }
}
