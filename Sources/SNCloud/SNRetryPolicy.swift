// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The wait between attempts. A separate type so that tests do not really sleep.
public protocol SNSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SNSystemSleeper: SNSleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// When to repeat a request and after how long.
public struct SNRetryPolicy: Sendable {
    /// Attempts in total, the first one included.
    public var maxAttempts: Int
    /// The delay before the second attempt.
    public var baseDelay: Duration
    /// How many times over the delay grows.
    public var multiplier: Double
    /// The delay ceiling: a server that asks to wait an hour must not hang the
    /// caller — better to return the error and try again on schedule.
    public var maxDelay: Duration
    /// The random spread around the computed delay, as a fraction of it, so
    /// that several requests failed by one hiccup do not come back in step.
    public var jitter: Double

    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(300),
        multiplier: Double = 3,
        maxDelay: Duration = .seconds(20),
        jitter: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public static let `default` = SNRetryPolicy()

    /// Whether `error` may go through on a second try of a request that is
    /// safe to send twice.
    ///
    /// Only the network, a 5xx and an explicit request to wait. Everything the
    /// envelope says is the service's considered answer — a wrong password does
    /// not become right by being sent again, and the account locks after six.
    public func shouldRetry(_ error: SNError) -> Bool {
        switch error {
        case .transport, .rateLimited:
            true
        case .http(let status, _):
            (500...599).contains(status)
        case .notLoggedIn, .sessionExpired, .invalidCredentials, .accountLocked,
             .verificationRequired, .invalidVerificationCode, .noVerificationPending,
             .alreadyExists, .notFound, .syncLocked, .rejected, .malformedResponse,
             .checksumMismatch, .oversizedResponse:
            false
        }
    }

    /// Whether `error` may be retried on a request that changes something.
    ///
    /// Narrower than `shouldRetry`, and the narrowness is the point. A move, a
    /// copy or a new folder that met a 5xx or a dropped connection may well
    /// have been carried out — the answer is what was lost — and sending it
    /// again copies a thousand files twice or fails with `E0322` over a folder
    /// the first attempt made. A 429 is the one refusal that says the request
    /// was not acted on.
    public func shouldRetryChange(_ error: SNError) -> Bool {
        if case .rateLimited = error { return true }
        return false
    }

    /// The delay before attempt number `attempt` (numbered from 1). The
    /// server's `Retry-After` outranks the formula and gets no jitter, but is
    /// held under the ceiling too.
    public func delay(
        beforeAttempt attempt: Int,
        retryAfter: TimeInterval?,
        random: (ClosedRange<Double>) -> Double = { .random(in: $0) }
    ) -> Duration {
        // Clamped as numbers, before any becomes a `Duration`: the header is
        // the server's to write, and `.seconds(_:)` traps on an infinite or
        // enormous value instead of saturating.
        let ceiling = maxDelay.snSeconds
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return .seconds(min(retryAfter, ceiling))
        }
        let exponent = max(0, attempt - 2)
        let seconds = min(baseDelay.snSeconds * pow(multiplier, Double(exponent)), ceiling)
        let spread = seconds * jitter
        let delay = seconds + random(-spread...spread)
        return .seconds(delay.isFinite ? min(max(delay, 0), ceiling) : ceiling)
    }
}

extension Duration {
    /// Seconds as a number, for delay arithmetic. Internal and prefixed: `RMCloud`
    /// publishes `seconds` on the same type, and two public extensions of one
    /// name collide in any module that imports both.
    var snSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Run an operation with retries according to a policy and a rule for which
/// errors are worth another attempt.
///
/// Returns the result of the first successful attempt; when the attempts run
/// out it throws the last error rather than one of its own: the caller needs
/// the reason, not the fact of exhaustion.
func withRetry<T>(
    policy: SNRetryPolicy,
    sleeper: any SNSleeping,
    retrying: (SNError) -> Bool,
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch let error as SNError {
            guard attempt < policy.maxAttempts, retrying(error) else { throw error }
            var retryAfter: TimeInterval?
            if case .rateLimited(let interval) = error { retryAfter = interval }
            attempt += 1
            try await sleeper.sleep(for: policy.delay(beforeAttempt: attempt, retryAfter: retryAfter))
        }
    }
}
