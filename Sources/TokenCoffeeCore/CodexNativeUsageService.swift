import Foundation

enum CodexNativeUsageError: Error, LocalizedError, Sendable {
    case unauthorized
    case invalidResponse(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Codex sign-in expired."
        case let .invalidResponse(message):
            "Invalid Codex usage response: \(message)"
        case let .server(message):
            message
        }
    }
}

struct CodexNativeUsageService: Sendable {
    private let configuration: CodexNativeConfiguration
    private let httpClient: CodexHTTPClient

    init(configuration: CodexNativeConfiguration, httpClient: CodexHTTPClient) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    func fetchRateLimits(tokens: CodexAuthTokens) async throws -> CodexRateLimitsResponse {
        var request = URLRequest(url: configuration.usageURL)
        request.httpMethod = "GET"
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")

        let claims = CodexJWTClaims.parse(tokens.idToken)
        if let accountID = claims.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        if claims.isFedRAMP {
            request.setValue("true", forHTTPHeaderField: "X-OpenAI-Fedramp")
        }

        do {
            let data = try await httpClient.validatedData(for: request)
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            return try map(response)
        } catch let error as CodexNativeHTTPError {
            throw mapHTTPError(error)
        } catch let error as DecodingError {
            throw CodexNativeUsageError.invalidResponse(error.localizedDescription)
        } catch {
            throw error
        }
    }

    private func map(_ response: CodexUsageResponse) throws -> CodexRateLimitsResponse {
        let primary = mapBucket(
            limitId: "codex",
            limitName: nil,
            rateLimit: response.rateLimit,
            credits: response.credits,
            planType: response.planType,
            rateLimitReachedType: response.rateLimitReachedType?.kind
        )

        var buckets: [String: RateLimitSnapshot] = ["codex": primary]
        if let additional = response.additionalRateLimits {
            for details in additional {
                let snapshot = mapBucket(
                    limitId: details.meteredFeature,
                    limitName: details.limitName,
                    rateLimit: details.rateLimit,
                    credits: nil,
                    planType: response.planType,
                    rateLimitReachedType: nil
                )
                buckets[details.meteredFeature] = snapshot
            }
        }

        guard buckets.values.contains(where: \.hasUsageData) else {
            throw CodexNativeUsageError.invalidResponse("Codex usage response contained no rate-limit buckets.")
        }

        return CodexRateLimitsResponse(rateLimits: primary, rateLimitsByLimitId: buckets)
    }

    private func mapBucket(
        limitId: String,
        limitName: String?,
        rateLimit: CodexUsageRateLimit?,
        credits: CodexUsageCredits?,
        planType: String,
        rateLimitReachedType: String?
    ) -> RateLimitSnapshot {
        let windows = normalizedWindows(
            primary: mapWindow(rateLimit?.primaryWindow),
            secondary: mapWindow(rateLimit?.secondaryWindow)
        )
        return RateLimitSnapshot(
            limitId: limitId,
            limitName: limitName,
            primary: windows.short,
            secondary: windows.weekly,
            credits: credits.map {
                CreditsSnapshot(
                    hasCredits: $0.hasCredits,
                    unlimited: $0.unlimited,
                    balance: $0.balance?.value
                )
            },
            planType: planType,
            rateLimitReachedType: rateLimitReachedType
        )
    }

    private func normalizedWindows(
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?
    ) -> (short: RateLimitWindow?, weekly: RateLimitWindow?) {
        switch (primary, secondary) {
        case let (primary?, secondary?):
            guard let primaryMinutes = primary.windowDurationMins,
                  let secondaryMinutes = secondary.windowDurationMins,
                  primaryMinutes != secondaryMinutes else {
                return (primary, secondary)
            }
            return primaryMinutes < secondaryMinutes
                ? (primary, secondary)
                : (secondary, primary)

        case let (window?, nil), let (nil, window?):
            if window.windowDurationMins == Self.weeklyWindowMinutes {
                return (nil, window)
            }
            return (window, nil)

        case (nil, nil):
            return (nil, nil)
        }
    }

    private func mapWindow(_ window: CodexUsageWindow?) -> RateLimitWindow? {
        guard let window else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: window.usedPercent.value,
            windowDurationMins: windowMinutes(fromSeconds: window.limitWindowSeconds.value),
            resetsAt: window.resetAt.value
        )
    }

    private func windowMinutes(fromSeconds seconds: Int) -> Int? {
        guard seconds > 0 else {
            return nil
        }
        return (seconds + 59) / 60
    }

    private static let weeklyWindowMinutes = 7 * 24 * 60

    private func mapHTTPError(_ error: CodexNativeHTTPError) -> CodexNativeUsageError {
        switch error {
        case let .invalidResponse(message):
            .invalidResponse(message)
        case let .unexpectedStatus(status, body):
            if status == 401 || status == 403 {
                .unauthorized
            } else {
                .server("HTTP \(status): \(body)")
            }
        }
    }
}

private extension RateLimitSnapshot {
    var hasUsageData: Bool {
        primary != nil || secondary != nil || credits != nil
    }
}

struct CodexUsageResponse: Decodable, Sendable {
    let planType: String
    let rateLimit: CodexUsageRateLimit?
    let credits: CodexUsageCredits?
    let additionalRateLimits: [CodexUsageAdditionalRateLimit]?
    let rateLimitReachedType: CodexUsageRateLimitReachedType?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
        case rateLimitReachedType = "rate_limit_reached_type"
    }
}

struct CodexUsageRateLimit: Decodable, Sendable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexUsageWindow: Decodable, Sendable {
    let usedPercent: FlexibleDouble
    let limitWindowSeconds: FlexibleInt
    let resetAfterSeconds: FlexibleInt?
    let resetAt: FlexibleInt

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

struct CodexUsageCredits: Decodable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: FlexibleString?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

struct CodexUsageAdditionalRateLimit: Decodable, Sendable {
    let limitName: String
    let meteredFeature: String
    let rateLimit: CodexUsageRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

struct CodexUsageRateLimitReachedType: Decodable, Sendable {
    let kind: String

    enum CodingKeys: String, CodingKey {
        case kind = "type"
    }
}
