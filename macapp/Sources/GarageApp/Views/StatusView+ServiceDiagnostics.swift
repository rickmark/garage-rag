import SwiftUI
import AppKit
import PythonXPCService

/// The Status page's service list: the gRPC backend and every XPC helper, each
/// expandable into its status report, self tests, managed services and a
/// functional test.
extension StatusView {
    // MARK: - XPC Helper Services Section

    var xpcServicesSection: some View {
        GroupBox("Services & Daemon Health Diagnostics") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Real-time operational status and deep functional diagnostic testing beyond basic ping for all helpers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastRefreshed = appState.xpcServices.lastRefreshedAt {
                            Text("Last checked \(lastRefreshed, style: .time)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if appState.xpcServices.isRefreshingAll || appState.xpcServices.isTestingAll || isTestingGrpc {
                        ProgressView().controlSize(.small)
                    }

                    Button {
                        runAllFunctionalTests()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.circle.fill")
                            Text("Run All Tests")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(appState.xpcServices.isTestingAll || isTestingGrpc)

                    Button {
                        toggleExpandAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: allExpanded ? "chevron.up.circle" : "chevron.down.circle")
                            Text(allExpanded ? "Collapse All" : "Expand All")
                        }
                    }
                    .controlSize(.small)

                    Button {
                        Task {
                            await appState.xpcServices.refreshAll()
                            await appState.grpc.refreshStatus()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh All")
                        }
                    }
                    .controlSize(.small)
                    .disabled(appState.xpcServices.isRefreshingAll || appState.xpcServices.isRestartingAll)

                    Button {
                        Task { await appState.xpcServices.restartAll() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise.circle")
                            Text("Restart All")
                        }
                    }
                    .controlSize(.small)
                    .disabled(appState.xpcServices.isRefreshingAll || appState.xpcServices.isRestartingAll)
                }

                Divider()

                VStack(spacing: 10) {
                    // gRPC Core Daemon Service Row
                    grpcServiceRow

                    // XPC Helper Services Rows
                    ForEach(appState.xpcServices.services) { service in
                        xpcServiceRow(for: service)
                    }
                }
            }
            .padding(8)
        }
    }

    var allExpanded: Bool {
        let allIds = Set(appState.xpcServices.services.map { $0.id }).union(["grpc"])
        return allIds.isSubset(of: expandedServiceIds) && isGrpcExpanded
    }

    func toggleExpandAll() {
        if allExpanded {
            expandedServiceIds.removeAll()
            isGrpcExpanded = false
        } else {
            expandedServiceIds = Set(appState.xpcServices.services.map { $0.id })
            isGrpcExpanded = true
        }
    }

    func runAllFunctionalTests() {
        Task {
            isTestingGrpc = true
            let grpcResult = await appState.grpc.testServiceQuery()
            grpcTestResult = grpcResult
            isTestingGrpc = false
            await appState.xpcServices.runAllDiagnosticTests()
        }
    }

    // MARK: - gRPC Service Row with Expandable Diagnostics

    var grpcServiceRow: some View {
        let isExpanded = isGrpcExpanded
        let isRunning = appState.grpc.status == .running

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isGrpcExpanded.toggle()
                    }
                } label: {
                    DisclosureChevron(isExpanded: isExpanded)
                }
                .accessibilityLabel(isExpanded ? "Collapse details" : "Expand details")
                .buttonStyle(.plain)

                // Status Icon
                Group {
                    switch appState.grpc.status {
                    case .running:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .starting, .stopping:
                        ProgressView().controlSize(.small)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    case .stopped:
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.title3)
                .frame(width: 24)

                // Service Metadata
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Garage gRPC Daemon")
                            .font(.subheadline.bold())

                        Text(verbatim: "\(appState.grpc.host):\(appState.grpc.port)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        if isRunning {
                            StatusBadge("RUNNING", tint: .green)
                        } else if case .failed = appState.grpc.status {
                            StatusBadge("FAILED", tint: .red)
                        } else {
                            StatusBadge("STOPPED", tint: .orange)
                        }

                        if let res = grpcTestResult {
                            if res.isSuccess {
                                StatusBadge("TEST PASSED", tint: .green)
                            } else {
                                StatusBadge("TEST FAILED", tint: .red)
                            }
                        }
                    }

                    Text("Provides gRPC endpoints for document search, models registry, corpus statistics, and daemon control.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Actions
                HStack(spacing: 6) {
                    Button {
                        Task {
                            isTestingGrpc = true
                            grpcTestResult = await appState.grpc.testServiceQuery()
                            isTestingGrpc = false
                            if !isGrpcExpanded {
                                withAnimation {
                                    isGrpcExpanded = true
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isTestingGrpc {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("Query Services")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(isTestingGrpc)
                }
            }

            // Expanded Functional Diagnostics View
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Beyond-Ping Functional Test: gRPC Services Query")
                                    .font(.caption.bold())
                                StatusBadge("gRPC RPC", tint: .purple)
                            }
                            Text("Executes GetStatus, GetVersion, ListModels, ListSources, and GetStats to verify gRPC server subsystem integrity.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                isTestingGrpc = true
                                grpcTestResult = await appState.grpc.testServiceQuery()
                                isTestingGrpc = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isTestingGrpc {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "play.circle")
                                }
                                Text("Run Query Test")
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(isTestingGrpc)
                    }

                    if let res = grpcTestResult {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: res.isSuccess ? "checkmark.seal.fill" : "xmark.seal.fill")
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                    Text(res.summary)
                                        .font(.caption.bold())
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                }

                                Spacer()

                                Button {
                                    NSPasteboard.general.copy(res.details)
                                    copiedServiceId = "grpc"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        if copiedServiceId == "grpc" { copiedServiceId = nil }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedServiceId == "grpc" ? "checkmark" : "doc.on.doc")
                                        Text(copiedServiceId == "grpc" ? "Copied!" : "Copy Output")
                                    }
                                }
                                .controlSize(.small)
                            }

                            MonospaceOutputBox(res.details, maxHeight: 140)
                        }
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - XPC Helper Service Row with Expandable Diagnostics

    func xpcServiceRow(for service: XPCServiceInfo) -> some View {
        let isExpanded = expandedServiceIds.contains(service.id)
        let isTesting = appState.xpcServices.testingServiceIds.contains(service.id)
        let diagResult = appState.xpcServices.diagnosticResults[service.id]
        let statusReport = appState.xpcServices.statusReports[service.id]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedServiceIds.remove(service.id)
                        } else {
                            expandedServiceIds.insert(service.id)
                        }
                    }
                } label: {
                    DisclosureChevron(isExpanded: isExpanded)
                }
                .accessibilityLabel(isExpanded ? "Collapse details" : "Expand details")
                .buttonStyle(.plain)

                // Status Icon
                Group {
                    switch service.state {
                    case .running:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .checking, .restarting:
                        ProgressView().controlSize(.small)
                    case .unreachable:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    case .unknown:
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title3)
                .frame(width: 24)

                // Service Metadata
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(service.name)
                            .font(.subheadline.bold())

                        Text(service.bundleId)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        if let pid = service.pid {
                            StatusBadge("PID: \(pid)", tint: .blue)
                        }

                        if let latency = service.latencyMs {
                            StatusBadge(String(format: "%.1f ms", latency), tint: .green)
                        }

                        if let report = statusReport, !report.tests.isEmpty {
                            let passedCount = report.tests.filter { $0.status == .passed }.count
                            let hasFailures = !report.failedTests.isEmpty
                            StatusBadge("\(passedCount)/\(report.tests.count) tests passed", tint: hasFailures ? .red : .green)
                        }

                        if service.state == .restarting {
                            StatusBadge("RESTARTING", tint: .orange)
                        } else if service.state == .checking {
                            StatusBadge("CHECKING", tint: .blue)
                        } else if case .unreachable = service.state {
                            StatusBadge("UNREACHABLE", tint: .red)
                        }

                        if let res = diagResult {
                            if res.isSuccess {
                                StatusBadge("TEST PASSED", tint: .green)
                            } else {
                                StatusBadge("TEST FAILED", tint: .red)
                            }
                        }
                    }

                    Text(service.serviceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let err = service.errorMessage {
                        Text("Error: \(err)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if let resp = service.pingResponse, !resp.isEmpty {
                        Text("Ping reply: \(resp)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 6) {
                    Button {
                        Task {
                            _ = await appState.xpcServices.runDiagnosticTest(for: service.id)
                            if !isExpanded {
                                withAnimation {
                                    _ = expandedServiceIds.insert(service.id)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("Test")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(isTesting || service.isChecking)

                    Button("Ping") {
                        Task { await appState.xpcServices.refresh(serviceId: service.id) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(service.isChecking || appState.xpcServices.isRefreshingAll)

                    Button("Restart") {
                        Task { await appState.xpcServices.restart(serviceId: service.id) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(service.isRunning ? .orange : .blue)
                    .disabled(service.isChecking || appState.xpcServices.isRestartingAll)
                }
            }

            // Expanded Functional Test View
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    xpcServiceReportSection(for: service, report: statusReport)

                    Divider()

                    let testInfo = ServiceDiagnosticTest.primary(for: service.id)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Beyond-Ping Functional Test: \(testInfo.name)")
                                    .font(.caption.bold())
                                StatusBadge("Beyond Ping", tint: .blue)
                            }
                            Text(testInfo.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                _ = await appState.xpcServices.runDiagnosticTest(for: service.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isTesting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "play.circle")
                                }
                                Text("Run Functional Test")
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(isTesting)
                    }

                    if let res = diagResult {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: res.isSuccess ? "checkmark.seal.fill" : "xmark.seal.fill")
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                    Text(res.summary)
                                        .font(.caption.bold())
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                }

                                Spacer()

                                Text(String(format: "%.1f ms", res.durationMs))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)

                                Button {
                                    NSPasteboard.general.copy(res.details)
                                    copiedServiceId = service.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        if copiedServiceId == service.id { copiedServiceId = nil }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedServiceId == service.id ? "checkmark" : "doc.on.doc")
                                        Text(copiedServiceId == service.id ? "Copied!" : "Copy Output")
                                    }
                                }
                                .controlSize(.small)
                            }

                            MonospaceOutputBox(res.details, maxHeight: 140)
                        }
                    }
                }
                .padding(8)
                .background(Color.blue.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - In-Service Status Report, Self Tests & Managed Service Actions

    func xpcServiceReportSection(for service: XPCServiceInfo, report: GarageXPCStatusReport?) -> some View {
        let isTesting = appState.xpcServices.testingServiceIds.contains(service.id)
        let isRestarting = appState.xpcServices.restartingServiceIds.contains(service.id)
        let actionsDisabled = isTesting || isRestarting || service.isChecking

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text("In-Service Diagnostics")
                    .font(.caption.bold())

                if let report = report {
                    StatusBadge(report.lifecycle.uppercased(), tint: lifecycleColor(report.lifecycle))
                    StatusBadge("UP \(formatUptime(report.uptimeSeconds))", tint: .secondary)
                    if let lastRun = report.lastTestRun {
                        Text("Tests ran \(Date(timeIntervalSince1970: lastRun), style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isRestarting {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task { _ = await appState.xpcServices.runServiceSelfTests(serviceId: service.id) }
                } label: {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checklist")
                        }
                        Text("Run Tests")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(actionsDisabled)

                Button {
                    Task { _ = await appState.xpcServices.restartManagedServices(serviceId: service.id, graceful: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Restart Services")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(actionsDisabled)

                Button {
                    Task { _ = await appState.xpcServices.restartManagedServices(serviceId: service.id, graceful: false) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.circle")
                        Text("Force Restart")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(actionsDisabled)

                Button {
                    Task { await appState.xpcServices.restart(serviceId: service.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power.circle")
                        Text("Restart Process")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(actionsDisabled || appState.xpcServices.isRestartingAll)
            }

            if let report = report {
                xpcPythonStatusLine(report.python)

                if !report.services.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Managed Services")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        ForEach(report.services, id: \.name) { managed in
                            xpcManagedServiceRow(managed)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    let passedCount = report.tests.filter { $0.status == .passed }.count
                    HStack(spacing: 6) {
                        Text("Self Tests")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        if !report.tests.isEmpty {
                            Text("\(passedCount) of \(report.tests.count) passed")
                                .font(.caption2)
                                .foregroundStyle(report.allTestsPassed ? .green : .red)
                        }
                    }
                    if report.tests.isEmpty {
                        Text("No self tests have been reported yet. Use “Run Tests” to execute them.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(report.tests.enumerated()), id: \.offset) { _, test in
                            xpcSelfTestRow(test)
                        }
                    }
                }

                if !report.recentErrorLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent Errors (\(report.recentErrorLines.count))")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                        MonospaceOutputBox(report.recentErrorLines.joined(separator: "\n"), maxHeight: 200)
                    }
                }

                if let crash = report.lastCrashReport, !crash.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                            Text("Crash Report")
                                .font(.caption2.bold())
                                .foregroundStyle(.red)
                        }
                        MonospaceOutputBox(crash, maxHeight: 200)
                    }
                }

                if let logPath = report.logFilePath {
                    Text("Log file: \(logPath)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            } else {
                Text("No status report received from this helper yet. Ping the service or run its tests to collect diagnostics.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func xpcPythonStatusLine(_ python: GarageXPCPythonStatus) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: python.error == nil ? "terminal" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(python.error == nil ? Color.secondary : Color.red)
            if let error = python.error, !error.isEmpty {
                Text("Python \(python.state): \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                Text(pythonSummaryLine(python))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    func pythonSummaryLine(_ python: GarageXPCPythonStatus) -> String {
        let version = python.version?.split(separator: " ").first.map { String($0) } ?? python.state
        var line = "Python \(version)"
        if let home = python.home, !home.isEmpty { line += " · home: \(home)" }
        if let initMs = python.initializationMs { line += String(format: " · init %.0f ms", initMs) }
        return line
    }

    func xpcManagedServiceRow(_ managed: GarageXPCManagedServiceStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(managedServiceColor(managed.state))
                .frame(width: 7, height: 7)
            Text(managed.name)
                .font(.caption2.bold())
            StatusBadge(managed.state.uppercased(), tint: managedServiceColor(managed.state))
            if managed.restartCount > 0 {
                Text("restarts: \(managed.restartCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }
            if let detail = managed.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    func xpcSelfTestRow(_ test: GarageXPCTestResult) -> some View {
        let (icon, color): (String, Color) = {
            switch test.status {
            case .passed: return ("checkmark.circle", .green)
            case .failed: return ("xmark.circle", .red)
            case .skipped: return ("minus.circle", .gray)
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(test.name)
                    .font(.caption.bold())
                Text(String(format: "%.1f ms", test.durationMs))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(test.summary)
                    .font(.caption2)
                    .foregroundStyle(test.status == .failed ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
            }

            if test.status == .failed {
                if let error = test.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !test.details.isEmpty {
                    MonospaceOutputBox(test.details, maxHeight: 160)
                }
            } else if !test.details.isEmpty {
                DisclosureGroup {
                    MonospaceOutputBox(test.details, maxHeight: 120)
                } label: {
                    Text("Details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        }
        .padding(.leading, 2)
    }


    func lifecycleColor(_ lifecycle: String) -> Color {
        switch lifecycle.lowercased() {
        case "ready": return .green
        case "degraded": return .orange
        case "failed": return .red
        case "bootstrapping": return .blue
        default: return .secondary
        }
    }

    func managedServiceColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "running": return .green
        case "starting", "restarting", "stopping": return .blue
        case "failed": return .red
        case "stopped": return .orange
        default: return .secondary
        }
    }

    func formatUptime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        if total < 86400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86400)d \((total % 86400) / 3600)h"
    }
}
