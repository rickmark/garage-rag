import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// How the reporter was opened. Coming from the Logs view pre-selects the log
/// stream the user was already staring at, and attaches it by default.
struct BugReportContext: Equatable, Sendable {
    var logSource: LogsView.LogSource = .garage
    var attachLogs: Bool = false

    init(logSource: LogsView.LogSource = .garage, attachLogs: Bool = false) {
        self.logSource = logSource
        self.attachLogs = attachLogs
    }
}

/// Composes a bug report locally and hands it to the user.
///
/// Nothing is transmitted from this sheet. The report is assembled in memory,
/// shown in full before anything happens to it, and then copied, saved, or
/// loaded into GitHub's new-issue form in the user's own browser — where they
/// get one more chance to read it before posting.
@MainActor
struct BugReportView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let version: AppVersionInfo

    @State private var draft: BugReportDraft
    @State private var diagnostics: [DiagnosticSection] = []
    @State private var logLines: [LogLine] = []
    @State private var isPreviewExpanded = false
    @State private var didCopy = false
    @State private var saveError: String?

    private let redactor = BugReportRedactor()

    init(version: AppVersionInfo = AppVersionInfo(), context: BugReportContext = BugReportContext()) {
        self.version = version
        var draft = BugReportDraft()
        draft.logSource = context.logSource
        draft.includeLogs = context.attachLogs
        self._draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    describeSection
                    attachmentsSection
                    privacyNote
                    previewSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .onAppear(perform: refreshAttachments)
        .onChange(of: draft.logSource) { refreshAttachments() }
        .alert("Couldn't save the report", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Report a Bug")
                    .font(.system(size: 17, weight: .semibold))
                Text("Describe what went wrong. Garage assembles the report on this Mac and shows it to you before anything leaves.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openURL(BugReportLinks.securityEmail)
            } label: {
                Label("Security issue?", systemImage: "lock.shield")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            .help("Security problems are disclosed privately by e-mail, not on the public issue tracker.")
            .accessibilityIdentifier("bugReport.security")

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Save…") { saveReport() }
                .disabled(!draft.isSubmittable)
                .accessibilityIdentifier("bugReport.save")

            Button(didCopy ? "Copied" : "Copy Report") { copyReport() }
                .disabled(!draft.isSubmittable)
                .accessibilityIdentifier("bugReport.copy")

            Button("Open GitHub Issue…") { openIssue() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isSubmittable)
                .accessibilityIdentifier("bugReport.openIssue")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Sections

    private var describeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            field(label: "Summary", required: true) {
                TextField("Ingest stops partway through a large folder", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("bugReport.title")
            }

            field(label: "What happened", required: true) {
                editor(text: $draft.whatHappened, minHeight: 78, identifier: "bugReport.whatHappened")
            }

            field(label: "Steps to reproduce") {
                editor(text: $draft.stepsToReproduce, minHeight: 60, identifier: "bugReport.steps")
            }

            field(label: "What you expected") {
                editor(text: $draft.expectedBehavior, minHeight: 46, identifier: "bugReport.expected")
            }
        }
    }

    private var attachmentsSection: some View {
        GroupBox("Attach") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $draft.includeDiagnostics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostics")
                        Text("App and macOS version, database and helper service state, corpus counts, registered models. No file names, no document contents.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("bugReport.includeDiagnostics")

                Toggle(isOn: $draft.includeLogs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent log lines")
                        Text("The last \(BugReportLogDigest.defaultLimit) lines from one log stream. Logs can quote file paths, so read them in the preview first.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("bugReport.includeLogs")

                if draft.includeLogs {
                    HStack(spacing: 8) {
                        Picker("Log stream", selection: $draft.logSource) {
                            ForEach(LogsView.LogSource.allCases) { source in
                                Text(source.rawValue).tag(source)
                            }
                        }
                        .frame(maxWidth: 260)
                        .accessibilityIdentifier("bugReport.logSource")

                        Text(logLines.isEmpty ? "no lines captured" : "\(logLines.count) lines")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("""
                Your home directory, user name, e-mail addresses, and any secrets are replaced with \
                placeholders before the report is assembled. Indexed documents, messages, and search \
                results are never included. Review the preview below — once a report is posted publicly, \
                it stays public.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var previewSection: some View {
        DisclosureGroup(isExpanded: $isPreviewExpanded) {
            ScrollView {
                Text(composedBody)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityIdentifier("bugReport.preview")
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        } label: {
            Text("Preview the exact report")
                .font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: Building blocks

    private func field<Content: View>(
        label: String,
        required: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                if required {
                    Text("required")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat, identifier: String) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12))
            .frame(minHeight: minHeight)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            .accessibilityIdentifier(identifier)
    }

    // MARK: Report

    /// The report exactly as it will be copied, saved, or sent to GitHub — the
    /// same string the preview shows, so there is no hidden payload.
    private var composedBody: String {
        BugReportComposer.compose(
            draft: draft,
            diagnostics: diagnostics,
            logLines: logLines,
            redactor: redactor
        )
    }

    private func refreshAttachments() {
        diagnostics = BugReportDiagnosticsCollector.collect(appState: appState, version: version)
        logLines = BugReportLogDigest.select(from: appState.osLogStreamService.logs(for: draft.logSource))
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(draft.effectiveTitle)\n\n\(composedBody)", forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        panel.title = "Save Bug Report"
        panel.nameFieldStringValue = "garage-bug-report-\(Self.fileTimestamp()).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try "# \(draft.effectiveTitle)\n\n\(composedBody)".write(to: destination, atomically: true, encoding: .utf8)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func openIssue() {
        guard let url = BugReportDestination.newIssueURL(title: draft.effectiveTitle, body: composedBody) else {
            openURL(BugReportLinks.issues)
            return
        }
        // Copied as well: GitHub's form is capped by URL length, and the
        // clipboard always holds the untruncated report.
        copyReport()
        openURL(url)
        dismiss()
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
