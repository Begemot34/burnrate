// JSON over HTTPS: one ephemeral session, 429 → retryAfter, short scrubbed error bodies.
import Foundation

enum HTTP {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    static let urlSession: Deps.Transport = { req in
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.failed("not an HTTP response") }
        return (data, http)
    }

    static func request(_ url: String, _ headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Does the request and decodes the body.
    static func getJSON<T: Decodable>(_ d: Deps, _ req: URLRequest, as: T.Type = T.self) async throws -> T {
        try decode(T.self, from: try await get(d, req), path: req.url?.path ?? "")
    }

    /// The raw body of a 2xx response.
    static func get(_ d: Deps, _ req: URLRequest) async throws -> Data {
        var req = req
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("burnrate/1.0", forHTTPHeaderField: "User-Agent")
        }
        let data: Data, resp: HTTPURLResponse
        do {
            (data, resp) = try await d.transport(req)
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError.failed(Scrub.text(error.localizedDescription))
        }
        let body = data.prefix(4 << 20)
        if resp.statusCode == 429 {
            throw ProviderError.retryAfter(retryAfter(resp.value(forHTTPHeaderField: "Retry-After"), now: d.now()))
        }
        guard resp.statusCode / 100 == 2 else {
            var b = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if b.hasPrefix("<") { b = "" }  // html error page
            throw ProviderError.http(resp.statusCode, Scrub.text(String(b.prefix(200))))
        }
        return Data(body)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.failed("parse \(path): \(describe(error))")
        }
    }

    /// Seconds, or an HTTP date.
    static func retryAfter(_ h: String?, now: Date) -> TimeInterval {
        guard let h = h?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return 0 }
        if let s = Int(h) { return TimeInterval(s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let t = f.date(from: h) { return t.timeIntervalSince(now) }
        return 0
    }
}

/// A short reason for a JSON decoding failure.
func describe(_ error: Error) -> String {
    switch error as? DecodingError {
    case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
        let path = c.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
    case .keyNotFound(let k, _):
        return "missing \(k.stringValue)"
    default:
        return "\(error)"
    }
}
