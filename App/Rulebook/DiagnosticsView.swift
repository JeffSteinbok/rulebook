import SwiftUI
import UIKit

/// Shows the in-memory log and hands it to the user.
///
/// TestFlight collects crash logs on its own, but never the app's own logging,
/// and its feedback form takes no attachments — it does take pasted text. So
/// Copy is the primary action here: copy, screenshot, paste into TestFlight
/// feedback, and the log arrives in App Store Connect beside the screenshot
/// with no backend involved. Sharing covers everyone who would rather email it.
struct DiagnosticsView: View {
    @State private var report = ""
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("If something went wrong, copy this into an email to support, or share it. Email addresses are left out, and nothing leaves your device until you send it.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)

                Text(report)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Metric.controlRadius))
            }
            .padding(DS.Metric.gutter)
        }
        .background(DS.Palette.ground)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        // Snapshot once on appear, so the text cannot change under the user
        // between reading it and sharing it.
        .task { report = DiagnosticsLog.shared.report() }
        .safeAreaInset(edge: .bottom) { actions }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = report
                didCopy = true
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(DS.Font.button)
                    .frame(maxWidth: .infinity, minHeight: DS.Metric.controlHeight)
            }
            .buttonStyle(.borderedProminent)

            ShareLink(item: report) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(DS.Font.button)
                    .frame(maxWidth: .infinity, minHeight: DS.Metric.controlHeight)
            }
            .buttonStyle(.bordered)
        }
        .tint(DS.Palette.accent700)
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

#Preview("Diagnostics") {
    NavigationStack { DiagnosticsView() }
}
