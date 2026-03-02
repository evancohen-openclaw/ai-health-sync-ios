// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import SwiftData
import SwiftUI

// MARK: - PushConfigView

struct PushConfigView: View {
    @Environment(AppState.self) private var appState

    @State private var serverURL: String = ""
    @State private var authToken: String = ""
    @State private var pushEnabled: Bool = false
    @State private var intervalMinutes: Int = 15
    @State private var isPushingNow: Bool = false
    @State private var showSavedFeedback: Bool = false

    var body: some View {
        List {
            configSection
            statusSection
            actionsSection
            infoSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Push Mode")
        .onAppear { loadFromService() }
    }

    // MARK: - Sections

    private var configSection: some View {
        Section {
            Toggle("Push Mode", isOn: $pushEnabled)
                .tint(.green)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://192.168.1.X:18789/hooks/health", text: $serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Auth Token").font(.caption).foregroundStyle(.secondary)
                SecureField("webhook_token", text: $authToken)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Stepper("Every \(intervalMinutes) min", value: $intervalMinutes, in: 5...60, step: 5)

            Button {
                HapticFeedback.impact(.medium)
                saveConfiguration()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showSavedFeedback ? "checkmark.circle.fill" : "square.and.arrow.down")
                    Text(showSavedFeedback ? "Saved!" : "Save Configuration")
                }
            }
            .liquidGlassButtonStyle(.prominent)
        } header: {
            Text("Configuration")
        } footer: {
            Text("The server uses a self-signed TLS certificate. Push mode accepts it automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Push Mode") {
                Text(appState.pushService.isPushEnabled ? "Enabled" : "Disabled")
                    .foregroundStyle(appState.pushService.isPushEnabled ? .green : .secondary)
            }

            LabeledContent("Last Push") {
                if let lastPush = appState.pushService.lastPushAt {
                    Text(lastPush.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: syncStateIcon)
                    .foregroundStyle(syncStateColor)
                Text(syncStateLabel)
                    .foregroundStyle(syncStateColor)
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                HapticFeedback.impact(.medium)
                Task {
                    isPushingNow = true
                    await appState.pushNow()
                    isPushingNow = false
                }
            } label: {
                if isPushingNow {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Pushing...")
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Push Now")
                    }
                }
            }
            .liquidGlassButtonStyle(.standard)
            .disabled(isPushingNow || appState.pushService.pushURL.isEmpty)
        }
    }

    private var infoSection: some View {
        Section("How Push Mode Works") {
            Label("iPhone pushes data to your Mac mini — no inbound connections needed.", systemImage: "arrow.up.forward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("Pushes happen on a timer and when HealthKit receives new data.", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("Configure the webhook on your Mac mini at port 18789.", systemImage: "server.rack")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sync State Display

    private var syncStateIcon: String {
        switch appState.pushService.syncState {
        case .idle: return "circle"
        case .pushing: return "arrow.up.circle"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.circle.fill"
        }
    }

    private var syncStateColor: Color {
        switch appState.pushService.syncState {
        case .idle: return .secondary
        case .pushing: return .blue
        case .success: return .green
        case .failure: return .red
        }
    }

    private var syncStateLabel: String {
        switch appState.pushService.syncState {
        case .idle: return "Idle"
        case .pushing: return "Pushing..."
        case .success(let date): return "Last push: \(date.formatted(date: .omitted, time: .shortened))"
        case .failure(let msg, _): return "Error: \(msg)"
        }
    }

    // MARK: - Helpers

    private func loadFromService() {
        let svc = appState.pushService
        serverURL = svc.pushURL
        authToken = svc.pushToken
        pushEnabled = svc.isPushEnabled
        intervalMinutes = svc.pushIntervalMinutes
    }

    private func saveConfiguration() {
        appState.savePushConfiguration(
            url: serverURL,
            token: authToken,
            enabled: pushEnabled,
            intervalMinutes: intervalMinutes
        )
        showSavedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { showSavedFeedback = false }
        }
    }
}

#Preview {
    let schema = Schema([SyncConfiguration.self, PairedDevice.self, AuditEventRecord.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: config)
    NavigationStack {
        PushConfigView()
            .environment(AppState(modelContainer: container))
            .modelContainer(container)
    }
}
