// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import HealthKit
import Foundation
import os
import UIKit

// MARK: - Push Payload

struct PushPayload: Codable, Sendable {
    let samples: [PushSampleDTO]
    let deviceId: String
    let pushTimestamp: Date
}

struct PushSampleDTO: Codable, Sendable {
    let type: String
    let value: Double
    let unit: String
    let startDate: Date
    let endDate: Date
    let sourceName: String
    let device: String?
    let metadata: [String: String]?

    init(from dto: HealthSampleDTO, device: String? = nil) {
        self.type = dto.type
        self.value = dto.value
        self.unit = dto.unit
        self.startDate = dto.startDate
        self.endDate = dto.endDate
        self.sourceName = dto.sourceName
        self.device = device
        self.metadata = dto.metadata
    }
}

// MARK: - Push Configuration Keys

enum PushKeychainKey {
    static let service = "org.healthsync.push"
    static let urlAccount = "pushURL"
    static let tokenAccount = "pushToken"
}

// MARK: - Push Sync State

enum PushSyncState: Sendable, Equatable {
    case idle
    case pushing
    case success(Date)
    case failure(String, Date)

    static func == (lhs: PushSyncState, rhs: PushSyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.pushing, .pushing): return true
        case (.success(let a), .success(let b)): return a == b
        case (.failure(let a1, let a2), .failure(let b1, let b2)): return a1 == b1 && a2 == b2
        default: return false
        }
    }
}

// MARK: - Self-Signed TLS Delegate

/// URLSession delegate that accepts self-signed certificates.
/// ONLY used for push mode where user has explicitly configured a self-signed server.
final class SelfSignedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

// MARK: - PushSyncService

/// Pushes HealthKit samples to a configured HTTPS endpoint.
@MainActor
final class PushSyncService {
    private static let logger = Logger(subsystem: "org.healthsync", category: "PushSyncService")

    // Configuration
    private(set) var pushURL: String = ""
    private(set) var pushToken: String = ""
    private(set) var isPushEnabled: Bool = false
    private(set) var pushIntervalMinutes: Int = 15

    // State
    private(set) var syncState: PushSyncState = .idle
    private(set) var lastPushAt: Date?
    private(set) var isPushing: Bool = false

    // Internals
    private let healthStore = HKHealthStore()
    private var timer: Timer?
    private var observerQueries: [HKObserverQuery] = []
    private let selfSignedDelegate = SelfSignedCertificateDelegate()
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default, delegate: selfSignedDelegate, delegateQueue: nil)
    }()

    private static let observedQuantityTypeIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .heartRateVariabilitySDNN,
        .restingHeartRate,
        .walkingHeartRateAverage,
        .stepCount,
        .activeEnergyBurned,
        .basalEnergyBurned,
        .distanceWalkingRunning,
        .distanceCycling,
        .flightsClimbed,
        .respiratoryRate,
        .oxygenSaturation,
        .bodyMass,
        .bodyMassIndex,
        .bodyFatPercentage,
        .leanBodyMass,
        .vo2Max,
        .height
    ]

    private static let pushDataTypes: [HealthDataType] = [
        // Vitals
        .heartRate, .heartRateVariability, .restingHeartRate,
        .walkingHeartRateAverage, .respiratoryRate, .bloodOxygen,
        // Sleep
        .sleepAnalysis,
        // Activity
        .steps, .activeEnergyBurned, .basalEnergyBurned,
        .distanceWalkingRunning, .distanceCycling, .flightsClimbed,
        // Fitness
        .vo2Max,
        // Body
        .weight, .height, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass
    ]

    // MARK: - Configuration

    func loadConfiguration() {
        if let urlData = try? KeychainStore.load(service: PushKeychainKey.service, account: PushKeychainKey.urlAccount),
           let url = String(data: urlData, encoding: .utf8) {
            pushURL = url
        }
        if let tokenData = try? KeychainStore.load(service: PushKeychainKey.service, account: PushKeychainKey.tokenAccount),
           let token = String(data: tokenData, encoding: .utf8) {
            pushToken = token
        }
        isPushEnabled = UserDefaults.standard.bool(forKey: "pushMode.enabled")
        let storedInterval = UserDefaults.standard.integer(forKey: "pushMode.intervalMinutes")
        pushIntervalMinutes = storedInterval > 0 ? storedInterval : 15
        lastPushAt = UserDefaults.standard.object(forKey: "pushMode.lastPushAt") as? Date
    }

    func saveConfiguration(url: String, token: String, enabled: Bool, intervalMinutes: Int) {
        pushURL = url
        pushToken = token
        isPushEnabled = enabled
        pushIntervalMinutes = intervalMinutes > 0 ? intervalMinutes : 15

        if let data = url.data(using: .utf8) {
            try? KeychainStore.save(data, service: PushKeychainKey.service, account: PushKeychainKey.urlAccount)
        }
        if let data = token.data(using: .utf8) {
            try? KeychainStore.save(data, service: PushKeychainKey.service, account: PushKeychainKey.tokenAccount)
        }
        UserDefaults.standard.set(enabled, forKey: "pushMode.enabled")
        UserDefaults.standard.set(pushIntervalMinutes, forKey: "pushMode.intervalMinutes")

        stop()
        if enabled { start() }
    }

    // MARK: - Lifecycle

    func start() {
        guard isPushEnabled, !pushURL.isEmpty else { return }
        startTimer()
        registerObservers()
        Self.logger.info("PushSyncService started; interval=\(self.pushIntervalMinutes)min")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        unregisterObservers()
        Self.logger.info("PushSyncService stopped.")
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        let interval = TimeInterval(pushIntervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.push(reason: "timer")
            }
        }
    }

    // MARK: - HealthKit Observers

    private func registerObservers() {
        unregisterObservers()

        for identifier in Self.observedQuantityTypeIdentifiers {
            guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            let query = HKObserverQuery(sampleType: quantityType, predicate: nil) { [weak self] _, completionHandler, error in
                defer { completionHandler() }
                guard error == nil else { return }
                Task { @MainActor [weak self] in
                    await self?.push(reason: "observer:\(identifier.rawValue)")
                }
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }

        if let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            let sleepQuery = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, completionHandler, error in
                defer { completionHandler() }
                guard error == nil else { return }
                Task { @MainActor [weak self] in
                    await self?.push(reason: "observer:sleepAnalysis")
                }
            }
            healthStore.execute(sleepQuery)
            observerQueries.append(sleepQuery)
        }

        Self.logger.info("Registered \(self.observerQueries.count) HK observer queries.")
    }

    private func unregisterObservers() {
        for query in observerQueries { healthStore.stop(query) }
        observerQueries.removeAll()
    }

    // MARK: - Push

    func push(reason: String = "manual") async {
        guard !isPushing else { return }
        guard !pushURL.isEmpty else {
            syncState = .failure("No push URL configured.", Date())
            return
        }

        isPushing = true
        syncState = .pushing
        Self.logger.info("Push starting; reason=\(reason, privacy: .public)")

        do {
            let samples = try await fetchNewSamples()
            if samples.isEmpty && reason != "manual" {
                isPushing = false
                syncState = .idle
                return
            }

            let payload = PushPayload(
                samples: samples.map { PushSampleDTO(from: $0) },
                deviceId: deviceIdentifier(),
                pushTimestamp: Date()
            )

            try await sendPayload(payload)

            let now = Date()
            lastPushAt = now
            UserDefaults.standard.set(now, forKey: "pushMode.lastPushAt")
            syncState = .success(now)
            Self.logger.info("Push succeeded; \(samples.count) samples sent.")
        } catch {
            syncState = .failure(error.localizedDescription, Date())
            Self.logger.error("Push failed: \(error.localizedDescription, privacy: .public)")
        }

        isPushing = false
    }

    // MARK: - Fetch

    private func fetchNewSamples() async throws -> [HealthSampleDTO] {
        let startDate = lastPushAt ?? Date().addingTimeInterval(-24 * 3600)
        let endDate = Date()
        var allSamples: [HealthSampleDTO] = []

        for dataType in Self.pushDataTypes {
            guard let sampleType = dataType.sampleType else { continue }
            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
            let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: sampleType,
                    predicate: predicate,
                    limit: 500,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
                ) { _, results, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: results ?? [])
                    }
                }
                self.healthStore.execute(query)
            }

            for sample in samples {
                if let dto = HealthSampleMapper.mapSample(sample, requestedType: dataType) {
                    allSamples.append(dto)
                }
            }
        }

        return allSamples
    }

    // MARK: - Network

    private func sendPayload(_ payload: PushPayload, retryCount: Int = 0) async throws {
        guard let url = URL(string: pushURL) else {
            throw PushError.invalidURL(pushURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !pushToken.isEmpty {
            request.setValue("Bearer \(pushToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        request.timeoutInterval = 30

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PushError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw PushError.httpError(http.statusCode) }
        } catch let error as PushError {
            throw error
        } catch {
            guard retryCount < 3 else { throw error }
            let delay = pow(2.0, Double(retryCount))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            try await sendPayload(payload, retryCount: retryCount + 1)
        }
    }

    // MARK: - Helpers

    private func deviceIdentifier() -> String {
        UIDevice.current.identifierForVendor?.uuidString.prefix(8).lowercased().description ?? "iphone"
    }
}

// MARK: - Errors

enum PushError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid push URL: \(url)"
        case .invalidResponse: return "Invalid response from server."
        case .httpError(let code): return "Server returned HTTP \(code)."
        }
    }
}
