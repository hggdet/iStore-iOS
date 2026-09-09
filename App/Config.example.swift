import Foundation

// Config.example.swift — copy to Config.swift and fill with your credentials.
// DO NOT COMMIT Config.swift into source control.

public struct R2Config {
    // Example S3-style endpoint for Cloudflare R2. Replace <account> with your account id.
    // e.g. https://<account>.r2.cloudflarestorage.com
    public static let endpoint = "https://<account>.r2.cloudflarestorage.com"
    public static let accessKeyId = "REPLACE_ME_ACCESS_KEY_ID"
    public static let secretAccessKey = "REPLACE_ME_SECRET_ACCESS_KEY"
    public static let bucket = "REPLACE_ME_BUCKET"
    public static let region = "auto" // R2 doesn't require an AWS region but keep for SigV4
}
