#!/usr/bin/env python3
"""
patch_istore.py — أربع تعديلات لتقليل تأخير التوقيع في iStore-iOS.

الاستخدام:
    python3 patch_istore.py /path/to/iStore-iOS
    python3 patch_istore.py /path/to/iStore-iOS --check   # فحص بدون كتابة

كل تعديل يتحقق من وجود المرساة قبل التطبيق، ويتخطى نفسه اذا كان مطبّق مسبقاً.
"""

import sys, os, argparse

PATCHES = []

def patch(name, relpath, old, new):
    PATCHES.append((name, relpath, old, new))


# ---------------------------------------------------------------- Patch A
# stage() كانت @MainActor-isolated وتنسخ الملف كامل على الثريد الرئيسي.
# صارت nonisolated + تستخدم النقل/الرابط الصلب بدل النسخ حيثما أمكن.
patch(
    "A: stage() nonisolated + move/hardlink fast path",
    "App/SigningService.swift",
    """    /// Copies a security-scoped picked file into the app container, returning the local path.
    func stage(_ url: URL, as name: String? = nil) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = workDir.appendingPathComponent(name ?? url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
""",
    """    /// Brings a picked or downloaded file into the app container.
    ///
    /// `takeOwnership` must be true only when the caller owns the source file
    /// (e.g. the temporary file handed back by `URLSession.download`). In that
    /// case the file is moved, which is O(1) on the same volume instead of a
    /// full byte copy. Otherwise a hard link is attempted first and a copy is
    /// used as the fallback for cross-volume sources such as the Files
    /// provider.
    ///
    /// `nonisolated` because this can move hundreds of megabytes and must
    /// never run on the main actor.
    nonisolated func stage(_ url: URL, as name: String? = nil, takeOwnership: Bool = false) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = workDir.appendingPathComponent(name ?? url.lastPathComponent)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)

        if takeOwnership {
            if (try? fm.moveItem(at: url, to: dest)) != nil { return dest }
        } else {
            // Same-volume hard link: no bytes are read or written.
            if (try? fm.linkItem(at: url, to: dest)) != nil { return dest }
        }

        do {
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
""",
)


# ---------------------------------------------------------------- Patch B
# مسار التحميل من رابط: الملف أصلاً مملوك للتطبيق في tmp، فلا داعي لنسخه.
patch(
    "B1: stageIPA gains takeOwnership",
    "App/ContentView.swift",
    """    private func stageIPA(_ source: URL,
                          fallbackToSource: Bool = false,
                          alreadyStaged: Bool = false) {
        let localURL = alreadyStaged
            ? source
            : (signer.stage(source) ?? (fallbackToSource ? source : nil))""",
    """    private func stageIPA(_ source: URL,
                          fallbackToSource: Bool = false,
                          alreadyStaged: Bool = false,
                          takeOwnership: Bool = false) {
        let localURL = alreadyStaged
            ? source
            : (signer.stage(source, takeOwnership: takeOwnership)
               ?? (fallbackToSource ? source : nil))""",
)

patch(
    "B2: downloaded IPA is moved, not copied",
    "App/ContentView.swift",
    """                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return }
                stageIPA(downloadedURL)""",
    """                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return }
                // URLSession's temporary file is ours; move it instead of
                // copying so a 400 MB import costs no extra pass over the data.
                stageIPA(downloadedURL, takeOwnership: true)""",
)


# ---------------------------------------------------------------- Patch C
# كاش المخرجات على مستوى التطبيق.
# ملاحظة: كاش zsign الداخلي (bEnableCache) لا ينفع هنا — مفتاحه SHA1 لمسار
# المجلد، والغلاف يولّد مجلداً فريداً بكل مرة، كما أنه يكتب إلى "./.zsign_cache"
# النسبي وهو غير قابل للكتابة داخل صندوق iOS.
patch(
    "C: signed-output cache keyed by IPA + certificate + parameters",
    "App/SigningService.swift",
    """import Foundation
import UniformTypeIdentifiers
""",
    """import Foundation
import CryptoKit
import UniformTypeIdentifiers
""",
)

patch(
    "C2: cache implementation",
    "App/SigningService.swift",
    """    func cleanStaged() {""",
    """    // MARK: - Signed-output cache

    /// Streaming SHA-256 so a 400 MB IPA is never held in memory.
    nonisolated static func fileDigest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 4 * 1024 * 1024),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func cacheDirectory() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iStore/signed-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Wraps `sign` with a content-addressed cache. Identical input IPA plus
    /// identical certificate plus identical parameters returns the previous
    /// result without touching zsign at all.
    nonisolated static func signCached(ipa: URL, p12: URL, password: String, profile: URL,
                                       bundleId: String, displayName: String, shortVersion: String,
                                       icon: URL?, output: URL, tempDir: URL,
                                       removeExtensions: Bool, enableDocuments: Bool,
                                       dylib: URL?, injectIntoExtensions: Bool)
        -> (ok: Bool, message: String, signedBundleId: String, signedVersion: String) {

        let parameterFingerprint = [
            bundleId, displayName, shortVersion,
            icon?.lastPathComponent ?? "-",
            dylib.flatMap { fileDigest($0) } ?? "-",
            injectIntoExtensions ? "1" : "0",
            removeExtensions ? "1" : "0",
            enableDocuments ? "1" : "0",
        ].joined(separator: "|")

        var key: String?
        if let ipaDigest = fileDigest(ipa), let p12Digest = fileDigest(p12) {
            var hasher = SHA256()
            hasher.update(data: Data("\\(ipaDigest)|\\(p12Digest)|\\(parameterFingerprint)".utf8))
            key = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        let fm = FileManager.default
        let cacheDir = cacheDirectory()

        // Cache hit: link the stored artifact to the caller's fresh output
        // path. Each install attempt still gets its own path, as the existing
        // attemptID logic requires, but no bytes are rewritten.
        if let key {
            let cached = cacheDir.appendingPathComponent("\\(key).ipa")
            let meta = cacheDir.appendingPathComponent("\\(key).meta")
            if fm.fileExists(atPath: cached.path),
               let raw = try? String(contentsOf: meta, encoding: .utf8) {
                let parts = raw.components(separatedBy: "\\n")
                if parts.count >= 2 {
                    try? fm.removeItem(at: output)
                    let linked = (try? fm.linkItem(at: cached, to: output)) != nil
                        || (try? fm.copyItem(at: cached, to: output)) != nil
                    if linked {
                        return (true, "Signed (cached).", parts[0], parts[1])
                    }
                }
            }
        }

        let result = sign(ipa: ipa, p12: p12, password: password, profile: profile,
                          bundleId: bundleId, displayName: displayName,
                          shortVersion: shortVersion, icon: icon, output: output,
                          tempDir: tempDir, removeExtensions: removeExtensions,
                          enableDocuments: enableDocuments,
                          dylib: dylib, injectIntoExtensions: injectIntoExtensions)

        if result.ok, let key, fm.fileExists(atPath: output.path) {
            let cached = cacheDir.appendingPathComponent("\\(key).ipa")
            try? fm.removeItem(at: cached)
            if (try? fm.linkItem(at: output, to: cached)) != nil
                || (try? fm.copyItem(at: output, to: cached)) != nil {
                try? "\\(result.signedBundleId)\\n\\(result.signedVersion)"
                    .write(to: cacheDir.appendingPathComponent("\\(key).meta"),
                           atomically: true, encoding: .utf8)
            }
        }

        return result
    }

    /// Drops cached artifacts once the cache exceeds `limit` bytes, oldest first.
    nonisolated static func trimCache(limit: Int64 = 4 * 1024 * 1024 * 1024) {
        let fm = FileManager.default
        let dir = cacheDirectory()
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]) else { return }
        var items: [(url: URL, size: Int64, accessed: Date)] = entries.compactMap {
            guard let values = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]) else { return nil }
            return ($0, Int64(values.fileSize ?? 0), values.contentAccessDate ?? .distantPast)
        }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        items.sort { $0.accessed < $1.accessed }
        for item in items where total > limit {
            try? fm.removeItem(at: item.url)
            try? fm.removeItem(at: item.url.deletingPathExtension().appendingPathExtension("meta"))
            total -= item.size
        }
    }

    func cleanStaged() {""",
)


# ---------------------------------------------------------------- Patch D
# zsign يحقن الـdylib أثناء التوقيع أصلاً (arrInjectDylibs + m_bInjectExtensions).
# لذلك تمريرة forgesign_inject_dylib_ipa المستقلة (فك + إعادة حزم كاملة) زائدة.
patch(
    "D1: bridge header takes the dylib directly",
    "Bridge/ForgeSignBridge.h",
    """                       int removeExtensions,
                       int enableDocuments,
                       char* msgBuf,
                       int msgBufLen,
                       char* bundleIdBuf,""",
    """                       int removeExtensions,
                       int enableDocuments,
                       const char* dylibPath,
                       int injectExtensions,
                       char* msgBuf,
                       int msgBufLen,
                       char* bundleIdBuf,""",
)

patch(
    "D2: wrapper signature",
    "Bridge/zsign_wrapper.cpp",
    """                                  int removeExtensions,
                                  int enableDocuments,
                                  char* msgBuf,
                                  int msgBufLen,
                                  char* bundleIdBuf,""",
    """                                  int removeExtensions,
                                  int enableDocuments,
                                  const char* dylibPath,
                                  int injectExtensions,
                                  char* msgBuf,
                                  int msgBufLen,
                                  char* bundleIdBuf,""",
)

patch(
    "D3: inject during the existing sign pass",
    "Bridge/zsign_wrapper.cpp",
    """    bundle.m_bInjectExtensions = false;

    vector<string> arrDylibs;
    vector<string> arrRemoveDylibs;""",
    """    bundle.m_bInjectExtensions = (injectExtensions != 0);

    vector<string> arrDylibs;
    vector<string> arrRemoveDylibs;
    // zsign copies the dylib into the bundle and rewrites the load commands as
    // part of signing, so a separate extract/repack pass is unnecessary.
    if (dylibPath && *dylibPath) {
        arrDylibs.push_back(dylibPath);
    }""",
)

patch(
    "D4: Swift sign() forwards the dylib",
    "App/SigningService.swift",
    """                     bundleId: String, displayName: String, shortVersion: String,
                     icon: URL?, output: URL, tempDir: URL,
                     removeExtensions: Bool, enableDocuments: Bool)
        -> (ok: Bool, message: String, signedBundleId: String, signedVersion: String) {""",
    """                     bundleId: String, displayName: String, shortVersion: String,
                     icon: URL?, output: URL, tempDir: URL,
                     removeExtensions: Bool, enableDocuments: Bool,
                     dylib: URL? = nil, injectIntoExtensions: Bool = false)
        -> (ok: Bool, message: String, signedBundleId: String, signedVersion: String) {""",
)

patch(
    "D5: Swift sign() passes the new arguments",
    "App/SigningService.swift",
    """            removeExtensions ? 1 : 0,
            enableDocuments ? 1 : 0,
            &msgBuf, Int32(msgBuf.count),""",
    """            removeExtensions ? 1 : 0,
            enableDocuments ? 1 : 0,
            dylib?.path,
            injectIntoExtensions ? 1 : 0,
            &msgBuf, Int32(msgBuf.count),""",
)

patch(
    "D6: drop the standalone injection pass at the call site",
    "App/ContentView.swift",
    """        Task.detached(priority: .userInitiated) {
            let signingIPA: URL
            var preparedIPA: URL?
            if let selectedDylib {
                let prepared = tempDir.appendingPathComponent("fs-injected-\\(UUID().uuidString).ipa")
                switch DylibInjectionService.prepare(ipa: ipa,
                                                      dylib: selectedDylib,
                                                      output: prepared,
                                                      temporaryDirectory: tempDir,
                                                      injectIntoExtensions: injectExt) {
                case .success:
                    signingIPA = prepared
                    preparedIPA = prepared
                case .failure(let error):
                    await MainActor.run {
                        repoStore.completeInstallAttempt(automaticInstallAppID, error: error.localizedDescription)
                        automaticInstallAppID = nil
                        automaticInstallAsAdditionalCopy = false
                        signer.phase = .failed(error.localizedDescription)
                    }
                    return
                }
            } else {
                signingIPA = ipa
            }

            let result = await SigningService.sign(ipa: signingIPA, p12: p12, password: pw, profile: profileFile,
                                             bundleId: bid,
                                             displayName: appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                             shortVersion: appVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                                             icon: selectedIconURL,
                                             output: output, tempDir: tempDir,
                                             removeExtensions: rmExt, enableDocuments: enDocs)
            if let preparedIPA {
                try? FileManager.default.removeItem(at: preparedIPA)
            }
""",
    """        Task.detached(priority: .userInitiated) {
            // The dylib is now injected inside the signing pass itself, so the
            // IPA is extracted and repacked once instead of twice.
            let result = SigningService.signCached(ipa: ipa, p12: p12, password: pw, profile: profileFile,
                                             bundleId: bid,
                                             displayName: appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                             shortVersion: appVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                                             icon: selectedIconURL,
                                             output: output, tempDir: tempDir,
                                             removeExtensions: rmExt, enableDocuments: enDocs,
                                             dylib: selectedDylib, injectIntoExtensions: injectExt)
            SigningService.trimCache()
""",
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--check", action="store_true", help="report only, do not write")
    args = ap.parse_args()

    applied = skipped = missing = 0
    edits = {}

    for name, rel, old, new in PATCHES:
        path = os.path.join(args.root, rel)
        if not os.path.exists(path):
            print(f"[MISSING FILE] {name}  ->  {rel}")
            missing += 1
            continue
        text = edits.get(path)
        if text is None:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        if new in text:
            print(f"[already applied] {name}")
            skipped += 1
            continue
        count = text.count(old)
        if count == 0:
            print(f"[ANCHOR NOT FOUND] {name}  ->  {rel}")
            missing += 1
            continue
        if count > 1:
            print(f"[AMBIGUOUS x{count}] {name}  ->  {rel}")
            missing += 1
            continue
        edits[path] = text.replace(old, new, 1)
        print(f"[ok] {name}")
        applied += 1

    if args.check:
        print(f"\ncheck only — {applied} applicable, {skipped} already applied, {missing} problem(s)")
        return 0 if missing == 0 else 1

    if missing:
        print(f"\nabort: {missing} problem(s), nothing written")
        return 1

    for path, text in edits.items():
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    print(f"\nwrote {len(edits)} file(s) — {applied} patch(es) applied, {skipped} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
