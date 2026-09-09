import Foundation
import CryptoKit

/// Minimal S3 SigV4 signing and R2 client for uploads, deletes, and listing.
/// Uses URLSession with a delegate to report upload progress.
@MainActor
final class R2Client: NSObject {
    static let shared = R2Client()

    private let endpoint: URL
    private let accessKey: String
    private let secretKey: String
    private let bucket: String
    private let region: String

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private let progressQueue = DispatchQueue(label: "com.hggdet.iStore.R2Client.progress")

    private override init() {
        // Read credentials from generated Config.swift (copy Config.example.swift -> Config.swift)
        guard let url = URL(string: R2Config.endpoint) else {
            fatalError("Invalid R2 endpoint in Config")
        }
        endpoint = url
        accessKey = R2Config.accessKeyId
        secretKey = R2Config.secretAccessKey
        bucket = R2Config.bucket
        region = R2Config.region
        super.init()
    }

    enum R2Error: Error {
        case network(Error)
        case server(Int, Data?)
        case badURL
        case signingError
        case cancelled
    }

    // MARK: - Debug logging helper
    private func debugLog(_ message: String) {
        #if DEBUG
        print("[R2Client] \(message)")
        #else
        // Keep a lightweight log in non-DEBUG builds as well if needed
        // Use os_log when more structured logging is desired.
        #endif
    }

    // MARK: - Public helpers

    /// Uploads the file at localURL to R2 using PUT to /<bucket>/<key> with SigV4 Authorization.
    /// Reports progress (0.0 .. 1.0) via the onProgress closure. Returns the objectKey on success.
    func upload(file localURL: URL, objectKey: String, onProgress: @escaping (Double) -> Void) async throws -> String {
        let targetURL = endpoint.appendingPathComponent("\(bucket)/\(objectKey)")
        guard var comps = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) else {
            throw R2Error.badURL
        }
        // Build request
        var req = URLRequest(url: targetURL)
        req.httpMethod = "PUT"
        // set minimal headers
        let now = Date()
        let isoDate = iso8601Basic(date: now)
        req.addValue(isoDate, forHTTPHeaderField: "x-amz-date")
        req.addValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // Compute payload hash
        let data = try Data(contentsOf: localURL)
        let payloadHash = sha256Hex(data: data)
        req.addValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Sign request
        do {
            let auth = try sign(request: req, payloadHash: payloadHash, date: now, region: region)
            req.addValue(auth, forHTTPHeaderField: "Authorization")
        } catch {
            throw R2Error.signingError
        }

        debugLog("Starting upload: key=\(objectKey) size=\(data.count) bytes to \(targetURL)")

        // Create upload task with delegate to track progress
        return try await withCheckedThrowingContinuation { cont in
            let task = session.uploadTask(with: req, from: data) { [weak self] respData, response, error in
                if let err = error {
                    self?.debugLog("Upload error for key=\(objectKey): \(err)")
                    cont.resume(throwing: R2Error.network(err))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self?.debugLog("Upload unexpected response for key=\(objectKey)")
                    cont.resume(throwing: R2Error.badURL)
                    return
                }
                if http.statusCode >= 200 && http.statusCode < 300 {
                    self?.debugLog("Upload succeeded for key=\(objectKey) status=\(http.statusCode)")
                    cont.resume(returning: objectKey)
                } else {
                    self?.debugLog("Upload failed for key=\(objectKey) status=\(http.statusCode)")
                    cont.resume(throwing: R2Error.server(http.statusCode, respData))
                }
                // remove any progress handler
                self?.progressQueue.async {
                    self?.progressHandlers[task.taskIdentifier] = nil
                }
            }
            // store progress handler
            progressQueue.async {
                self.progressHandlers[task.taskIdentifier] = onProgress
            }
            task.resume()
        }
    }

    /// Returns a presigned GET URL valid for `expires` seconds (max ~3600 recommended) for the given object key.
    func presignedGetURL(for objectKey: String, expires: TimeInterval = 60 * 30) throws -> URL {
        // SigV4 presign: build canonical query with X-Amz-Algorithm, X-Amz-Credential, X-Amz-Date, X-Amz-Expires, X-Amz-SignedHeaders
        guard let host = endpoint.host else { throw R2Error.badURL }
        let now = Date()
        let amzDate = iso8601Basic(date: now)
        let shortDate = String(amzDate.prefix(8))
        let service = "s3"
        let algorithm = "AWS4-HMAC-SHA256"
        let credential = "\(accessKey)/\(shortDate)/\(region)/\(service)/aws4_request"

        // Query params
        var q: [String: String] = [:]
        q["X-Amz-Algorithm"] = algorithm
        q["X-Amz-Credential"] = credential.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? credential
        q["X-Amz-Date"] = amzDate
        q["X-Amz-Expires"] = "\(Int(expires))"
        q["X-Amz-SignedHeaders"] = "host"

        // Build canonical query string
        let sortedKeys = q.keys.sorted()
        let canonicalQuery = sortedKeys.map { "\($0)=\(q[$0]!)" }.joined(separator: "&")

        // Canonical request
        let canonicalURI = "/\(bucket)/\(objectKey)"
        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"
        let payloadHash = "UNSIGNED-PAYLOAD"
        let canonicalRequest = ["GET", canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let canonicalHash = sha256Hex(string: canonicalRequest)

        // String to sign
        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = [algorithm, amzDate, scope, canonicalHash].joined(separator: "\n")

        // Signing key
        let kDate = hmacSHA256(key: "AWS4\(secretKey)", data: shortDate)
        let kRegion = hmacSHA256(keyData: kDate, data: region)
        let kService = hmacSHA256(keyData: kRegion, data: service)
        let kSigning = hmacSHA256(keyData: kService, data: "aws4_request")
        let signature = hmacSHA256Hex(keyData: kSigning, data: stringToSign)

        // Final URL
        let scheme = endpoint.scheme ?? "https"
        let qs = canonicalQuery + "&X-Amz-Signature=\(signature)"
        let urlStr = "\(scheme)://\(host)\(canonicalURI)?\(qs)"
        guard let url = URL(string: urlStr) else { throw R2Error.badURL }
        debugLog("Generated presigned URL for key=\(objectKey) expires=\(Int(expires))s url=\(url)")
        return url
    }

    /// Delete object key (with retries and exponential backoff)
    func delete(objectKey: String) async throws {
        let maxAttempts = 4
        let baseDelayNanos: UInt64 = 300_000_000 // 300ms

        var lastError: Error?
        for attempt in 1...maxAttempts {
            let targetURL = endpoint.appendingPathComponent("\(bucket)/\(objectKey)")
            var req = URLRequest(url: targetURL)
            req.httpMethod = "DELETE"
            let now = Date()
            let iso = iso8601Basic(date: now)
            req.addValue(iso, forHTTPHeaderField: "x-amz-date")
            let payloadHash = sha256Hex(string: "")
            req.addValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
            do {
                let auth = try sign(request: req, payloadHash: payloadHash, date: now, region: region)
                req.addValue(auth, forHTTPHeaderField: "Authorization")
            } catch {
                throw R2Error.signingError
            }

            debugLog("Delete attempt \(attempt) for key=\(objectKey) to \(targetURL)")

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw R2Error.badURL }
                debugLog("Delete response for key=\(objectKey): status=\(http.statusCode)")
                if (200...299).contains(http.statusCode) {
                    debugLog("Delete succeeded for key=\(objectKey)")
                    return
                }
                if http.statusCode == 404 {
                    // Already gone; treat as success.
                    debugLog("Delete: key not found (404) for key=\(objectKey)")
                    return
                }
                if (500...599).contains(http.statusCode) {
                    lastError = R2Error.server(http.statusCode, data)
                    debugLog("Delete server error (will retry): status=\(http.statusCode) for key=\(objectKey)")
                    // retry
                } else {
                    // 4xx other than 404: likely not retriable
                    debugLog("Delete failed (non-retriable) for key=\(objectKey) status=\(http.statusCode)")
                    throw R2Error.server(http.statusCode, data)
                }
            } catch {
                // Network errors -> retry
                lastError = error
                debugLog("Delete network/error for key=\(objectKey): \(error)")
            }

            if attempt < maxAttempts {
                // exponential backoff with jitter
                let exp = UInt64(1) << UInt64(attempt - 1)
                let jitter = UInt64.random(in: 0..<(baseDelayNanos / 2))
                let sleepNanos = min(5_000_000_000, baseDelayNanos * exp + jitter) // cap at 5s
                debugLog("Delete retry sleeping for \(sleepNanos)ns before next attempt for key=\(objectKey)")
                try? await Task.sleep(nanoseconds: sleepNanos)
                continue
            }
        }

        // If we reach here, all attempts failed
        if let e = lastError as? Error {
            debugLog("Delete ultimately failed for key=\(objectKey): \(e)")
            throw e
        } else {
            debugLog("Delete ultimately failed for key=\(objectKey): unknown error")
            throw R2Error.cancelled
        }
    }

    /// List objects with optional prefix; returns array of (key, lastModified as Date)
    func list(prefix: String?) async throws -> [(String, Date)] {
        // Use the S3 ListObjectsV2 endpoint: GET /?list-type=2&prefix=...
        guard let host = endpoint.host else { throw R2Error.badURL }
        var comps = URLComponents()
        comps.scheme = endpoint.scheme
        comps.host = host
        comps.path = "/\(bucket)/"
        var queryItems = [URLQueryItem(name: "list-type", value: "2")]
        if let p = prefix { queryItems.append(URLQueryItem(name: "prefix", value: p)) }
        comps.queryItems = queryItems
        guard let url = comps.url else { throw R2Error.badURL }

        debugLog("Listing objects with prefix=\(prefix ?? "") at \(url)")

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let now = Date()
        req.addValue(iso8601Basic(date: now), forHTTPHeaderField: "x-amz-date")
        let payloadHash = sha256Hex(string: "")
        req.addValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        let auth = try sign(request: req, payloadHash: payloadHash, date: now, region: region)
        req.addValue(auth, forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            debugLog("List network error: \(error)")
            throw R2Error.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw R2Error.badURL }
        if !(200...299).contains(http.statusCode) {
            debugLog("List failed with status=\(http.statusCode)")
            throw R2Error.server(http.statusCode, data)
        }
        // Parse XML response (ListBucketResult) — simple parser to get Key and LastModified
        var results: [(String, Date)] = []
        if let xml = String(data: data, encoding: .utf8) {
            // crude parse: find <Contents> blocks
            let entries = xml.components(separatedBy: "<Contents>")
            for part in entries.dropFirst() {
                if let keyStart = part.range(of: "<Key>"), let keyEnd = part.range(of: "</Key>"), let lmStart = part.range(of: "<LastModified>"), let lmEnd = part.range(of: "</LastModified>") {
                    let key = String(part[keyStart.upperBound..<keyEnd.lowerBound])
                    let lm = String(part[lmStart.upperBound..<lmEnd.lowerBound])
                    let df = ISO8601DateFormatter()
                    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var date = df.date(from: lm)
                    if date == nil {
                        // try without fractional seconds
                        df.formatOptions = [.withInternetDateTime]
                        date = df.date(from: lm)
                    }
                    if let d = date {
                        results.append((key, d))
                    }
                }
            }
        }
        debugLog("List returned \(results.count) items for prefix=\(prefix ?? "")")
        return results
    }

    // MARK: - Signing helpers (SigV4)

    private func sign(request: URLRequest, payloadHash: String, date: Date, region: String) throws -> String {
        guard let url = request.url, let host = url.host else { throw R2Error.badURL }
        let amzDate = iso8601Basic(date: date)
        let shortDate = String(amzDate.prefix(8))
        let service = "s3"
        let canonicalURI = url.path
        // canonical query
        let canonicalQuery = url.query ?? ""
        // headers
        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"
        let canonicalRequest = [request.httpMethod ?? "GET", canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let hashedCanonical = sha256Hex(string: canonicalRequest)
        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hashedCanonical].joined(separator: "\n")

        let kDate = hmacSHA256(key: "AWS4\(secretKey)", data: shortDate)
        let kRegion = hmacSHA256(keyData: kDate, data: region)
        let kService = hmacSHA256(keyData: kRegion, data: service)
        let kSigning = hmacSHA256(keyData: kService, data: "aws4_request")
        let signature = hmacSHA256Hex(keyData: kSigning, data: stringToSign)

        let credential = "\(accessKey)/\(shortDate)/\(region)/\(service)/aws4_request"
        let auth = "AWS4-HMAC-SHA256 Credential=\(credential), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return auth
    }

    // MARK: - Crypto helpers
    private func iso8601Basic(date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return df.string(from: date)
    }

    private func sha256Hex(string: String) -> String {
        return sha256Hex(data: Data(string.utf8))
    }
    private func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: String, data: String) -> Data {
        let keyData = Data(key.utf8)
        return hmacSHA256(keyData: keyData, data: data)
    }

    private func hmacSHA256(keyData: Data, data: String) -> Data {
        let d = Data(data.utf8)
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<SHA256>.authenticationCode(for: d, using: key)
        return Data(mac)
    }

    private func hmacSHA256Hex(keyData: Data, data: String) -> String {
        let sig = hmacSHA256(keyData: keyData, data: data)
        return sig.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSessionTaskDelegate to capture upload progress
extension R2Client: @MainActor URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress: Double
        if totalBytesExpectedToSend > 0 {
            progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        } else {
            progress = 0.0
        }
        progressQueue.async {
            if let h = self.progressHandlers[task.taskIdentifier] {
                DispatchQueue.main.async { h(progress) }
            }
        }
    }
}
