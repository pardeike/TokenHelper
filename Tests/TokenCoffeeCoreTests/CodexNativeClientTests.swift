import Foundation
import XCTest
@testable import TokenCoffeeCore

final class CodexNativeClientTests: XCTestCase {
    func testUsageServiceMapsPrimaryCreditsAndAdditionalBuckets() async throws {
        let http = MockCodexHTTPClient(responses: [
            .json("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 42,
                  "limit_window_seconds": 3600,
                  "reset_after_seconds": 120,
                  "reset_at": 1735689720
                },
                "secondary_window": {
                  "used_percent": 5,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 43200,
                  "reset_at": 1736294400
                }
              },
              "credits": {
                "has_credits": true,
                "unlimited": false,
                "balance": "12"
              },
              "rate_limit_reached_type": {
                "type": "workspace_member_usage_limit_reached"
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "metered_feature": "codex_bengalfox",
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 8,
                      "limit_window_seconds": 1800,
                      "reset_after_seconds": 600,
                      "reset_at": 1735693200
                    }
                  }
                }
              ]
            }
            """),
        ])
        let service = CodexNativeUsageService(configuration: testConfiguration(), httpClient: http)
        let tokens = CodexAuthTokens(
            idToken: makeJWT(auth: [
                "chatgpt_account_id": "account-123",
                "chatgpt_plan_type": "pro",
                "chatgpt_account_is_fedramp": true,
            ]),
            accessToken: "access-token",
            refreshToken: "refresh-token",
            lastRefresh: Date()
        )

        let response = try await service.fetchRateLimits(tokens: tokens)

        XCTAssertEqual(response.codexSnapshot.limitId, "codex")
        XCTAssertEqual(response.codexSnapshot.primary?.usedPercent, 42)
        XCTAssertEqual(response.codexSnapshot.primary?.windowDurationMins, 60)
        XCTAssertEqual(response.codexSnapshot.secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(response.codexSnapshot.credits, CreditsSnapshot(hasCredits: true, unlimited: false, balance: "12"))
        XCTAssertEqual(response.codexSnapshot.planType, "pro")
        XCTAssertEqual(response.codexSnapshot.rateLimitReachedType, "workspace_member_usage_limit_reached")
        XCTAssertEqual(response.rateLimitsByLimitId?["codex_bengalfox"]?.limitName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(response.rateLimitsByLimitId?["codex_bengalfox"]?.primary?.windowDurationMins, 30)

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://example.test/backend-api/wham/usage")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-123")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-OpenAI-Fedramp"), "true")
    }

    func testUsageServiceMapsWeeklyOnlyPrimaryWindowToWeeklyRole() async throws {
        let http = MockCodexHTTPClient(responses: [
            .json("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 1,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 603273,
                  "reset_at": 1784527276
                },
                "secondary_window": null
              }
            }
            """),
        ])
        let service = CodexNativeUsageService(configuration: testConfiguration(), httpClient: http)
        let tokens = CodexAuthTokens(
            idToken: makeJWT(auth: ["chatgpt_account_id": "account-123"]),
            accessToken: "access-token",
            refreshToken: "refresh-token",
            lastRefresh: Date()
        )

        let response = try await service.fetchRateLimits(tokens: tokens)

        XCTAssertNil(response.codexSnapshot.primary)
        XCTAssertEqual(response.codexSnapshot.secondary?.usedPercent, 1)
        XCTAssertEqual(response.codexSnapshot.secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(response.codexSnapshot.secondary?.resetsAt, 1_784_527_276)
    }

    func testUsageServiceNormalizesReversedShortAndWeeklyWindows() async throws {
        let http = MockCodexHTTPClient(responses: [
            .json("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 20,
                  "limit_window_seconds": 604800,
                  "reset_at": 1784527276
                },
                "secondary_window": {
                  "used_percent": 4,
                  "limit_window_seconds": 18000,
                  "reset_at": 1783924276
                }
              }
            }
            """),
        ])
        let service = CodexNativeUsageService(configuration: testConfiguration(), httpClient: http)
        let tokens = CodexAuthTokens(
            idToken: makeJWT(auth: ["chatgpt_account_id": "account-123"]),
            accessToken: "access-token",
            refreshToken: "refresh-token",
            lastRefresh: Date()
        )

        let response = try await service.fetchRateLimits(tokens: tokens)

        XCTAssertEqual(response.codexSnapshot.primary?.usedPercent, 4)
        XCTAssertEqual(response.codexSnapshot.primary?.windowDurationMins, 300)
        XCTAssertEqual(response.codexSnapshot.secondary?.usedPercent, 20)
        XCTAssertEqual(response.codexSnapshot.secondary?.windowDurationMins, 10_080)
    }

    func testFetchWithoutTokensRequiresSignIn() async throws {
        let client = CodexRateLimitClient(
            configuration: testConfiguration(),
            httpClient: MockCodexHTTPClient(responses: []),
            tokenStore: InMemoryCodexAuthTokenStore()
        )

        do {
            _ = try await client.fetch()
            XCTFail("fetch should require sign-in")
        } catch let error as CodexRateLimitClient.ClientError {
            XCTAssertEqual(error, .needsSignIn)
        }
    }

    func testUsageServiceRejectsEmptyUsageResponse() async throws {
        let http = MockCodexHTTPClient(responses: [
            .json("""
            {
              "plan_type": "pro"
            }
            """),
        ])
        let service = CodexNativeUsageService(configuration: testConfiguration(), httpClient: http)
        let tokens = CodexAuthTokens(
            idToken: makeJWT(auth: ["chatgpt_account_id": "account-123"]),
            accessToken: "access-token",
            refreshToken: "refresh-token",
            lastRefresh: Date()
        )

        do {
            _ = try await service.fetchRateLimits(tokens: tokens)
            XCTFail("fetch should reject an empty usage response")
        } catch let error as CodexNativeUsageError {
            XCTAssertEqual(error.localizedDescription, "Invalid Codex usage response: Codex usage response contained no rate-limit buckets.")
        }
    }

    func testFetchRefreshesAfterUsageUnauthorizedAndRetriesOnce() async throws {
        let originalTokens = CodexAuthTokens(
            idToken: makeJWT(auth: ["chatgpt_account_id": "account-123", "chatgpt_plan_type": "pro"]),
            accessToken: "old-access",
            refreshToken: "old-refresh",
            lastRefresh: Date()
        )
        let refreshedIdToken = makeJWT(auth: ["chatgpt_account_id": "account-123", "chatgpt_plan_type": "pro"])
        let http = MockCodexHTTPClient(responses: [
            .json("{}", statusCode: 401),
            .json("""
            {
              "id_token": "\(refreshedIdToken)",
              "access_token": "new-access",
              "refresh_token": "new-refresh"
            }
            """),
            .json("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 9,
                  "limit_window_seconds": 300,
                  "reset_after_seconds": 120,
                  "reset_at": 1735689720
                }
              }
            }
            """),
        ])
        let store = InMemoryCodexAuthTokenStore(tokens: originalTokens)
        let client = CodexRateLimitClient(
            configuration: testConfiguration(),
            httpClient: http,
            tokenStore: store
        )

        let result = try await client.fetch()

        XCTAssertEqual(result.response.codexSnapshot.primary?.usedPercent, 9)
        XCTAssertEqual(result.account?.planType, "pro")
        let saved = await store.savedTokens()
        XCTAssertEqual(saved?.accessToken, "new-access")
        XCTAssertEqual(saved?.refreshToken, "new-refresh")

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path ?? "" }, ["/backend-api/wham/usage", "/oauth/token", "/backend-api/wham/usage"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
    }

    func testFetchRefreshesAfterUsageForbiddenAndRetriesOnce() async throws {
        let originalTokens = CodexAuthTokens(
            idToken: makeJWT(auth: ["chatgpt_account_id": "account-123", "chatgpt_plan_type": "pro"]),
            accessToken: "old-access",
            refreshToken: "old-refresh",
            lastRefresh: Date()
        )
        let refreshedIdToken = makeJWT(auth: ["chatgpt_account_id": "account-123", "chatgpt_plan_type": "pro"])
        let http = MockCodexHTTPClient(responses: [
            .json("{}", statusCode: 403),
            .json("""
            {
              "id_token": "\(refreshedIdToken)",
              "access_token": "new-access",
              "refresh_token": "new-refresh"
            }
            """),
            .json("""
            {
              "plan_type": "pro",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 11,
                  "limit_window_seconds": 300,
                  "reset_after_seconds": 120,
                  "reset_at": 1735689720
                }
              }
            }
            """),
        ])
        let store = InMemoryCodexAuthTokenStore(tokens: originalTokens)
        let client = CodexRateLimitClient(
            configuration: testConfiguration(),
            httpClient: http,
            tokenStore: store
        )

        let result = try await client.fetch()

        XCTAssertEqual(result.response.codexSnapshot.primary?.usedPercent, 11)
        let saved = await store.savedTokens()
        XCTAssertEqual(saved?.accessToken, "new-access")
    }

    func testDeviceCodeFlowPollsAndPersistsTokens() async throws {
        let idToken = makeJWT(email: "andreas@example.test", auth: [
            "chatgpt_account_id": "account-123",
            "chatgpt_plan_type": "pro",
        ])
        let http = MockCodexHTTPClient(responses: [
            .json("""
            {
              "device_auth_id": "device-123",
              "user_code": "ABCD-1234",
              "interval": "0"
            }
            """),
            .json("{}", statusCode: 403),
            .json("""
            {
              "authorization_code": "auth-code",
              "code_challenge": "challenge",
              "code_verifier": "verifier"
            }
            """),
            .json("""
            {
              "id_token": "\(idToken)",
              "access_token": "access-token",
              "refresh_token": "refresh-token"
            }
            """),
        ])
        let store = InMemoryCodexAuthTokenStore()
        let service = CodexNativeAuthService(
            configuration: testConfiguration(devicePollIntervalOverride: 0),
            httpClient: http,
            tokenStore: store
        )

        let deviceCode = try await service.requestDeviceCode()
        let tokens = try await service.completeDeviceCodeLogin(deviceCode)

        XCTAssertEqual(deviceCode.deviceAuthId, "device-123")
        XCTAssertEqual(deviceCode.userCode, "ABCD-1234")
        XCTAssertEqual(deviceCode.verificationURL.absoluteString, "https://auth.example.test/codex/device")
        XCTAssertEqual(tokens.accessToken, "access-token")
        let savedTokens = await store.savedTokens()
        XCTAssertEqual(savedTokens?.refreshToken, "refresh-token")
        XCTAssertEqual(service.accountSnapshot(for: tokens), CodexAccountSnapshot(type: "chatgpt", email: "andreas@example.test", planType: "pro"))

        let requests = await http.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path ?? "" }, [
            "/api/accounts/deviceauth/usercode",
            "/api/accounts/deviceauth/token",
            "/api/accounts/deviceauth/token",
            "/oauth/token",
        ])
    }
}

private actor InMemoryCodexAuthTokenStore: CodexAuthTokenStore {
    private var tokens: CodexAuthTokens?

    init(tokens: CodexAuthTokens? = nil) {
        self.tokens = tokens
    }

    func load() async throws -> CodexAuthTokens? {
        tokens
    }

    func save(_ tokens: CodexAuthTokens) async throws {
        self.tokens = tokens
    }

    func delete() async throws {
        tokens = nil
    }

    func savedTokens() async -> CodexAuthTokens? {
        tokens
    }
}

private actor MockCodexHTTPClient: CodexHTTPClient {
    private var responses: [MockCodexHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [MockCodexHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw MockCodexHTTPError.noResponse(request.url?.absoluteString ?? "<nil>")
        }
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        return (response.data, httpResponse)
    }

    func recordedRequests() async -> [URLRequest] {
        requests
    }
}

private struct MockCodexHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    static func json(_ value: String, statusCode: Int = 200) -> MockCodexHTTPResponse {
        MockCodexHTTPResponse(
            statusCode: statusCode,
            data: Data(value.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }
}

private enum MockCodexHTTPError: Error {
    case noResponse(String)
}

private func testConfiguration(devicePollIntervalOverride: TimeInterval? = nil) -> CodexNativeConfiguration {
    CodexNativeConfiguration(
        issuerBaseURL: URL(string: "https://auth.example.test")!,
        backendBaseURL: URL(string: "https://example.test/backend-api")!,
        clientID: "test-client",
        deviceLoginTimeout: 1,
        tokenRefreshInterval: 8 * 24 * 60 * 60,
        accessTokenRefreshSkew: 5 * 60,
        devicePollIntervalOverride: devicePollIntervalOverride,
        userAgent: "TokenCoffeeTests"
    )
}

private func makeJWT(email: String? = nil, auth: [String: Any]) -> String {
    var payload: [String: Any] = [
        "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        "https://api.openai.com/auth": auth,
    ]
    if let email {
        payload["email"] = email
    }
    return [
        base64URL(["alg": "none", "typ": "JWT"]),
        base64URL(payload),
        "signature",
    ].joined(separator: ".")
}

private func base64URL(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return data
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
