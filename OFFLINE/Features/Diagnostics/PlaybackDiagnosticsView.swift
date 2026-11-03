import SwiftUI
import UIKit

struct PlaybackDiagnosticsView: View {
    @ObservedObject var service: AudioPlayerService
    @ObservedObject var diagnostics: PlaybackDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback diagnostics").font(.headline)
            Text("Session only • last 300 events • track identifiers are anonymized. No titles, file paths or secrets.").font(.caption).foregroundStyle(.secondary)
            Text(service.diagnosticSnapshot.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("Copy trace") { UIPasteboard.general.setItems([["public.utf8-plain-text": diagnostics.export(currentState: service.diagnosticSnapshot)]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]) }
                ShareLink("Export trace", item: diagnostics.export(currentState: service.diagnosticSnapshot))
                Button("Clear", role: .destructive) { diagnostics.clear() }
            }.font(.caption)
            ForEach(diagnostics.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.timestamp.formatted(date: .omitted, time: .standard))  \(event.action)")
                    Text("\(event.fields["reason"] ?? "") • \(event.fields["status"] ?? "") • gen \(event.fields["generation"] ?? "")")
                }.font(.system(.caption2, design: .monospaced))
            }
        }.foregroundStyle(.white)
    }
}
