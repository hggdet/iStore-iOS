#include "common.h"
#include "bundle.h"
#include "openssl.h"
#include "archive.h"
#include "macho.h"
#include "log.h"

#if defined(ZSIGN_SYSTEM_MINIZIP_NG)
#include <unzip.h>
#elif defined(ZSIGN_SYSTEM_MINIZIP)
#include <minizip/unzip.h>
#else
#include "third-party/minizip/unzip.h"
#endif
#include <string>
#include <vector>
#include <time.h>
#include <dirent.h>
#include <CoreFoundation/CoreFoundation.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/evp.h>

using namespace std;

// Reads a string value from plist bytes (XML or binary) using CoreFoundation.
static string FSReadPlistStringFromData(const string& contents, const string& key)
{
    if (contents.empty()) return "";

    CFDataRef data = CFDataCreate(NULL, (const UInt8*)contents.data(), (CFIndex)contents.size());
    if (!data) return "";
    CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    if (!plist) return "";

    string result;
    if (CFDictionaryGetTypeID() == CFGetTypeID(plist)) {
        CFStringRef cfkey = CFStringCreateWithCString(NULL, key.c_str(), kCFStringEncodingUTF8);
        CFTypeRef val = CFDictionaryGetValue((CFDictionaryRef)plist, cfkey);
        if (val && CFStringGetTypeID() == CFGetTypeID(val)) {
            char tmp[1024];
            if (CFStringGetCString((CFStringRef)val, tmp, sizeof(tmp), kCFStringEncodingUTF8)) {
                result = tmp;
            }
        }
        CFRelease(cfkey);
    }
    CFRelease(plist);
    return result;
}

// Reads a string value from a plist file (XML or binary) using CoreFoundation.
static string FSReadPlistString(const string& path, const string& key)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return "";
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return ""; }
    string buf((size_t)sz, 0);
    size_t rd = fread(&buf[0], 1, (size_t)sz, f);
    fclose(f);
    if (rd != (size_t)sz) return "";

    return FSReadPlistStringFromData(buf, key);
}

static string FSFindAppFolder(const string& extractedFolder)
{
    string payload = extractedFolder + "/Payload";
    DIR* dir = opendir(payload.c_str());
    if (!dir) return "";
    string result;
    while (dirent* entry = readdir(dir)) {
        string name = entry->d_name;
        if (name == "." || name == "..") continue;
        if (name.size() > 4 && name.substr(name.size() - 4) == ".app") {
            string candidate = payload + "/" + name;
            if (ZFile::IsFolder(candidate.c_str())) {
                result = candidate;
                break;
            }
        }
    }
    closedir(dir);
    return result;
}

static bool FSWritePlistString(const string& path, const string& key, const string& value)
{
    jvalue plist;
    if (!plist.read_plist_from_file(path.c_str())) return false;
    plist[key] = jvalue(value);
    return plist.style_write_plist_to_file(path.c_str());
}

// ForgeSign on-device signing bridge.
// Signs an IPA using zsign (userspace codesign) with a .p12 + password + profile.
// Returns 0 on success, non-zero on failure. Writes a short status message into
// msgBuf (NUL-terminated) for the UI.
extern "C" int forgesign_sign_ipa(const char* ipaPath,
                                  const char* p12Path,
                                  const char* password,
                                  const char* provPath,
                                  const char* bundleId,
                                  const char* displayName,
                                  const char* shortVersion,
                                  const char* iconPath,
                                  const char* outputPath,
                                  const char* tempFolder,
                                  int removeExtensions,
                                  int enableDocuments,
                                  const char* dylibPath,
                                  int injectExtensions,
                                  char* msgBuf,
                                  int msgBufLen,
                                  char* bundleIdBuf,
                                  int bundleIdBufLen,
                                  char* versionBuf,
                                  int versionBufLen)
{
    auto setMsg = [&](const string& m) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", m.c_str());
        }
    };

    ZLog::SetLogLever(ZLog::E_WARN);

    string strIpa = ipaPath ? ipaPath : "";
    string strP12 = p12Path ? p12Path : "";
    string strPassword = password ? password : "";
    string strProv = provPath ? provPath : "";
    string strBundleId = bundleId ? bundleId : "";
    string strDisplayName = displayName ? displayName : "";
    string strShortVersion = shortVersion ? shortVersion : "";
    string strIconPath = iconPath ? iconPath : "";
    string strOutput = outputPath ? outputPath : "";
    string strTemp = tempFolder ? tempFolder : "";

    if (strIpa.empty() || strP12.empty() || strProv.empty() || strOutput.empty()) {
        setMsg("Missing input path, certificate, profile, or output path.");
        return 1;
    }
    if (!ZFile::IsFileExists(strIpa.c_str())) {
        setMsg("IPA not found: " + strIpa);
        return 2;
    }
    if (!ZFile::IsFileExists(strP12.c_str())) {
        setMsg("Certificate (.p12) not found.");
        return 3;
    }
    if (!ZFile::IsFileExists(strProv.c_str())) {
        setMsg("Provisioning profile not found.");
        return 4;
    }
    if (!ZFile::IsZipFile(strIpa.c_str())) {
        setMsg("Input is not a valid IPA/zip.");
        return 5;
    }
    if (strTemp.empty() || !ZFile::IsFolder(strTemp.c_str())) {
        setMsg("Invalid temp folder.");
        return 6;
    }

    // Init signing asset from p12 + password + profile.
    ZSignAsset zsa;
    if (!zsa.Init("", strP12, strProv, "", strPassword, false, true, false)) {
        setMsg("Failed to load certificate/profile. Check the P12 password and that the profile matches the certificate.");
        return 10;
    }

    // Fat wildcard profiles often ship empty iCloud/ubiquity container lists
    // with icloud-services=*. Stamping those onto an app that never used iCloud
    // breaks UIDocumentPicker (Open enabled, does nothing) after resign, while
    // AltServer's lean profiles do not. Strip the empty-container iCloud keys.
    if (!zsa.m_strEntitleData.empty()) {
        jvalue jvEnt;
        if (jvEnt.read_plist(zsa.m_strEntitleData)) {
            auto emptyArray = [](jvalue& v) {
                return !v.is_array() || v.size() == 0;
            };
            bool changed = false;
            const char* containerKeys[] = {
                "com.apple.developer.icloud-container-identifiers",
                "com.apple.developer.ubiquity-container-identifiers",
                "com.apple.developer.icloud-container-development-container-identifiers",
            };
            bool containersEmpty = true;
            bool hadContainerKey = false;
            for (const char* key : containerKeys) {
                if (!jvEnt.has(key)) continue;
                hadContainerKey = true;
                if (!emptyArray(jvEnt[key])) {
                    containersEmpty = false;
                    break;
                }
            }
            if (hadContainerKey && containersEmpty) {
                for (const char* key : containerKeys) {
                    if (jvEnt.has(key)) {
                        jvEnt.erase(key);
                        changed = true;
                    }
                }
                if (jvEnt.has("com.apple.developer.icloud-services")) {
                    jvEnt.erase("com.apple.developer.icloud-services");
                    changed = true;
                }
                if (jvEnt.has("com.apple.developer.ubiquity-kvstore-identifier")) {
                    // Keep kvstore only when real containers exist.
                    jvEnt.erase("com.apple.developer.ubiquity-kvstore-identifier");
                    changed = true;
                }
            }
            if (changed) {
                zsa.m_strEntitleData.clear();
                jvEnt.style_write_plist(zsa.m_strEntitleData);
                ZLog::Print(">>> Stripped empty iCloud container entitlements (Files picker fix)\n");
            }
        }
    }

    // Extract IPA to a working folder.
    string strFolder = ZFile::GetRealPathV("%s/fs_folder_%llu", strTemp.c_str(), ZUtil::GetMicroSecond());
    if (!Zip::Extract(strIpa.c_str(), strFolder.c_str())) {
        setMsg("Failed to extract IPA.");
        return 11;
    }

    // Apply user metadata before signing so the final CodeResources/signature covers it.
    if (!strDisplayName.empty() || !strShortVersion.empty() || !strIconPath.empty()) {
        string appFolder = FSFindAppFolder(strFolder);
        if (appFolder.empty()) {
            ZFile::RemoveFolder(strFolder.c_str());
            setMsg("Could not locate the app bundle in Payload.");
            return 12;
        }
        string infoPlist = appFolder + "/Info.plist";
        bool metadataOK = true;
        if (!strDisplayName.empty()) {
            metadataOK = FSWritePlistString(infoPlist, "CFBundleDisplayName", strDisplayName)
                && FSWritePlistString(infoPlist, "CFBundleName", strDisplayName);
        }
        if (metadataOK && !strShortVersion.empty()) {
            metadataOK = FSWritePlistString(infoPlist, "CFBundleShortVersionString", strShortVersion);
        }
        if (metadataOK && !strIconPath.empty()) {
            const string customIconName = "FinallyCustomIcon.png";
            const string customIconPath = appFolder + "/" + customIconName;
            metadataOK = ZFile::CopyFile(strIconPath.c_str(), customIconPath.c_str());
            if (metadataOK) {
                jvalue iconPlist;
                metadataOK = iconPlist.read_plist_from_file(infoPlist.c_str());
                if (metadataOK) {
                    iconPlist["CFBundleIconFiles"][0] = jvalue(customIconName);
                    iconPlist["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"][0] = jvalue("FinallyCustomIcon");
                    metadataOK = iconPlist.style_write_plist_to_file(infoPlist.c_str());
                }
            }
        }
        if (!metadataOK) {
            ZFile::RemoveFolder(strFolder.c_str());
            setMsg("Could not update app metadata before signing.");
            return 12;
        }
    }

    // Sign the folder.
    ZBundle bundle;
    bundle.m_bEnableDocuments = (enableDocuments != 0);
    bundle.m_bRemoveExtensions = (removeExtensions != 0);
    bundle.m_bRemoveWatchApp = false;
    bundle.m_bRemoveUISupportedDevices = false;
    bundle.m_bInjectExtensions = (injectExtensions != 0);

    vector<string> arrDylibs;
    vector<string> arrRemoveDylibs;
    // zsign copies the dylib into the bundle and rewrites the load commands as
    // part of signing, so a separate extract/repack pass is unnecessary.
    if (dylibPath && *dylibPath) {
        arrDylibs.push_back(dylibPath);
    }
    bool bRet = bundle.SignFolder(&zsa, strFolder, strBundleId, "", "",
                                  arrDylibs, arrRemoveDylibs,
                                  true,   // force
                                  false,  // weak inject
                                  false,  // cache
                                  false); // remove provision
    if (!bRet) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("Signing failed. See log for details.");
        return 12;
    }

    // Report the signed bundle identifier and version (needed for the install manifest).
    if (bundleIdBuf && bundleIdBufLen > 0) {
        string signedId = FSReadPlistString(bundle.m_strAppFolder + "/Info.plist", "CFBundleIdentifier");
        snprintf(bundleIdBuf, bundleIdBufLen, "%s", signedId.c_str());
    }
    if (versionBuf && versionBufLen > 0) {
        string signedVersion = FSReadPlistString(bundle.m_strAppFolder + "/Info.plist", "CFBundleVersion");
        if (signedVersion.empty()) {
            signedVersion = FSReadPlistString(bundle.m_strAppFolder + "/Info.plist", "CFBundleShortVersionString");
        }
        snprintf(versionBuf, versionBufLen, "%s", signedVersion.c_str());
    }

    // Repackage to IPA.
    size_t pos = bundle.m_strAppFolder.rfind("Payload");
    if (string::npos == pos || 0 == pos) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("Could not locate Payload directory after signing.");
        return 13;
    }
    string strBaseFolder = bundle.m_strAppFolder.substr(0, pos - 1);
    if (!Zip::Archive(strBaseFolder.c_str(), strOutput.c_str(), 0)) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg("Failed to package the signed IPA.");
        return 14;
    }

    ZFile::RemoveFolder(strFolder.c_str());
    setMsg("Signed OK: " + strOutput);
    return 0;
}

// Read-only IPA inspection used by the UI before signing. This deliberately
// has its own bridge entry point: it extracts into a disposable folder and
// never creates, modifies, signs, or repackages an IPA.
static bool FSHasMachOMagic(const string& path)
{
    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) return false;
    uint32_t magic = 0;
    bool ok = (fread(&magic, sizeof(magic), 1, fp) == 1) &&
              (magic == MH_MAGIC || magic == MH_CIGAM ||
               magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
               magic == FAT_MAGIC || magic == FAT_CIGAM);
    fclose(fp);
    return ok;
}

static string FSFindPayloadApp(const string& folder)
{
    string payload = folder + "/Payload";
    string appFolder;
    ZFile::EnumFolder(payload.c_str(), false, NULL, [&](bool bFolder, const string& path) {
        if (bFolder && ZFile::IsPathSuffix(path, ".app")) {
            appFolder = path;
            return true;
        }
        return false;
    });
    return appFolder;
}

// IPA icons are declared in Info.plist and stored as PNG files directly inside
// the app bundle. The preflight reads the declared names so it can pick the
// largest matching rendition out of the archive.
static void FSGetIconNames(const string& infoPlistData, vector<string>& iconNames)
{
    jvalue info;
    if (!info.read_plist(infoPlistData)) return;

    if (info.has("CFBundleIcons")) {
        jvalue& icons = info["CFBundleIcons"];
        if (icons.has("CFBundlePrimaryIcon")) {
            jvalue& primary = icons["CFBundlePrimaryIcon"];
            if (primary.has("CFBundleIconFiles") && primary["CFBundleIconFiles"].is_array()) {
                jvalue& files = primary["CFBundleIconFiles"];
                for (size_t i = 0; i < files.size(); ++i) {
                    string name = files[i];
                    if (!name.empty()) iconNames.push_back(name);
                }
            }
        }
    }

    if (iconNames.empty() && info.has("CFBundleIconFiles") && info["CFBundleIconFiles"].is_array()) {
        jvalue& files = info["CFBundleIconFiles"];
        for (size_t i = 0; i < files.size(); ++i) {
            string name = files[i];
            if (!name.empty()) iconNames.push_back(name);
        }
    }

    if (iconNames.empty() && info.has("CFBundleIconFile")) {
        string name = info["CFBundleIconFile"];
        if (!name.empty()) iconNames.push_back(name);
    }
}

static bool FSIsTopLevelAppExtension(const string& appFolder, const string& path)
{
    if (!ZFile::IsPathSuffix(path, ".appex") || path.size() <= appFolder.size() + 1) {
        return false;
    }
    string relative = path.substr(appFolder.size() + 1);
    if (1 != count(relative.begin(), relative.end(), '/')) {
        return false;
    }
    return (0 == relative.rfind("PlugIns/", 0) ||
            0 == relative.rfind("Extensions/", 0));
}

static bool FSInjectMachO(const string& path,
                          const string& loadPath,
                          string& error)
{
    if (!FSHasMachOMagic(path)) {
        error = "Target is not a Mach-O executable: " + path;
        return false;
    }

    ZMachO macho;
    if (!macho.Init(path.c_str())) {
        error = "Could not parse Mach-O executable: " + path;
        return false;
    }
    if (macho.IsEncrypted()) {
        error = "Encrypted Mach-O cannot be injected: " + path;
        macho.Free();
        return false;
    }

    bool injected = macho.InjectDylib(false, loadPath.c_str());
    bool closed = macho.Free();
    if (!injected || !closed) {
        error = "Could not add the dylib load command. The executable may not have enough load-command space: " + path;
        return false;
    }
    return true;
}

// Prepares a disposable IPA for the existing signing pass. The original IPA
// is never modified and no provisioning/signature work happens here.
extern "C" int forgesign_inject_dylib_ipa(const char* ipaPath,
                                          const char* dylibPath,
                                          const char* outputPath,
                                          const char* tempFolder,
                                          int injectExtensions,
                                          char* msgBuf,
                                          int msgBufLen)
{
    auto setMsg = [&](const string& message) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", message.c_str());
        }
    };

    string strIpa = ipaPath ? ipaPath : "";
    string strDylib = dylibPath ? dylibPath : "";
    string strOutput = outputPath ? outputPath : "";
    string strTemp = tempFolder ? tempFolder : "";

    if (strIpa.empty() || strDylib.empty() || strOutput.empty() || strTemp.empty()) {
        setMsg("Missing IPA, dylib, output, or temporary folder.");
        return 1;
    }
    if (!ZFile::IsFileExists(strIpa.c_str()) || !ZFile::IsZipFile(strIpa.c_str())) {
        setMsg("Input is not a valid IPA/zip.");
        return 2;
    }
    if (!ZFile::IsFileExists(strDylib.c_str()) ||
        !ZFile::IsPathSuffix(strDylib, ".dylib") ||
        !FSHasMachOMagic(strDylib)) {
        setMsg("The selected file is not a valid Mach-O .dylib.");
        return 3;
    }
    if (!ZFile::IsFolder(strTemp.c_str())) {
        setMsg("Invalid temporary folder.");
        return 4;
    }

    ZMachO dylib;
    if (!dylib.Init(strDylib.c_str())) {
        setMsg("Could not parse the selected dylib.");
        return 5;
    }
    if (dylib.IsEncrypted()) {
        dylib.Free();
        setMsg("The selected dylib is encrypted and cannot be injected.");
        return 6;
    }
    dylib.Free();

    string strFolder = ZFile::GetRealPathV("%s/fs_inject_%llu", strTemp.c_str(), ZUtil::GetMicroSecond());
    if (!Zip::Extract(strIpa.c_str(), strFolder.c_str())) {
        setMsg("Failed to extract IPA for dylib injection.");
        return 7;
    }

    auto fail = [&](int code, const string& message) {
        ZFile::RemoveFolder(strFolder.c_str());
        setMsg(message);
        return code;
    };

    string appFolder = FSFindPayloadApp(strFolder);
    if (appFolder.empty()) {
        return fail(8, "No Payload/*.app bundle was found.");
    }

    string dylibName = ZUtil::GetBaseName(strDylib.c_str());
    if (dylibName.empty() || dylibName == "." || dylibName == "..") {
        return fail(9, "Could not determine the dylib filename.");
    }

    string bundledDylib = appFolder + "/" + dylibName;
    if (ZFile::IsFileExists(bundledDylib.c_str())) {
        return fail(10, "The app already contains a file named " + dylibName + ". Rename the dylib before injecting.");
    }
    if (!ZFile::CopyFile(strDylib.c_str(), bundledDylib.c_str())) {
        return fail(11, "Could not copy the dylib into the app bundle.");
    }

    string executable = FSReadPlistString(appFolder + "/Info.plist", "CFBundleExecutable");
    if (executable.empty()) {
        return fail(12, "The app bundle has no CFBundleExecutable.");
    }

    string error;
    if (!FSInjectMachO(appFolder + "/" + executable,
                       "@executable_path/" + dylibName,
                       error)) {
        return fail(13, error);
    }

    int injectedTargets = 1;
    if (injectExtensions != 0) {
        vector<string> extensions;
        ZFile::EnumFolder(appFolder.c_str(), true, NULL, [&](bool bFolder, const string& path) {
            if (bFolder && FSIsTopLevelAppExtension(appFolder, path)) {
                extensions.push_back(path);
            }
            return false;
        });

        for (const string& extension : extensions) {
            string extensionExecutable = FSReadPlistString(extension + "/Info.plist", "CFBundleExecutable");
            if (extensionExecutable.empty()) {
                return fail(14, "An app extension has no CFBundleExecutable: " + extension);
            }

            string relative = extension.substr(appFolder.size() + 1);
            string prefix;
            for (size_t i = 0, n = 1 + (size_t)count(relative.begin(), relative.end(), '/'); i < n; i++) {
                prefix += "../";
            }
            string extensionLoadPath = "@executable_path/" + prefix + dylibName;
            if (!FSInjectMachO(extension + "/" + extensionExecutable,
                               extensionLoadPath,
                               error)) {
                return fail(15, error);
            }
            injectedTargets += 1;
        }
    }

    size_t payloadPos = appFolder.rfind("Payload");
    if (string::npos == payloadPos || 0 == payloadPos) {
        return fail(16, "Could not locate the Payload directory after injection.");
    }
    string baseFolder = appFolder.substr(0, payloadPos - 1);
    ZFile::RemoveFile(strOutput.c_str());
    if (!Zip::Archive(baseFolder.c_str(), strOutput.c_str(), 0)) {
        return fail(17, "Failed to package the IPA after dylib injection.");
    }

    ZFile::RemoveFolder(strFolder.c_str());
    setMsg("Prepared IPA with " + dylibName + " in " + to_string(injectedTargets) + " executable(s).");
    return 0;
}

// ---------------------------------------------------------------------------
// Read-only IPA inspection used by the UI before signing.
//
// This works straight off the zip's central directory and decompresses only the
// few entries it actually needs. Unpacking the whole archive to disk just to
// read Info.plist and count Mach-O files cost a full extract-and-delete cycle of
// tens of thousands of small files, which the signing pass then repeated. This
// path never creates, modifies, signs, or repackages an IPA.
// ---------------------------------------------------------------------------

namespace {

// Bounds on how much of a single entry the classifier will decompress. A thin
// arm64 slice needs only its load commands; multi-slice binaries are all but
// extinct on iOS, so the fat cap keeps a pathological archive from stalling the
// preflight rather than serving any real app.
const size_t   kMachOProbeBytes     = 4096;
const uint32_t kMaxLoadCommandBytes = 8u * 1024 * 1024;
const uint64_t kMaxFatScanBytes     = 64ull * 1024 * 1024;
const uint64_t kMaxInfoPlistBytes   = 16ull * 1024 * 1024;
const uint64_t kMaxIconBytes        = 32ull * 1024 * 1024;

struct FSZipEntry
{
    string          path;
    uint64_t        uncompressedSize;
    bool            isDirectory;
    unz64_file_pos  pos;
};

// Forward-only reader over one zip entry. Decompresses in place without
// materialising the whole file.
class FSZipStream
{
public:
    explicit FSZipStream(unzFile uf) : m_uf(uf), m_bOpen(false), m_uPos(0) {}
    ~FSZipStream() { Close(); }

    bool Open()
    {
        if (m_bOpen) return true;
        if (UNZ_OK != unzOpenCurrentFile(m_uf)) return false;
        m_bOpen = true;
        m_uPos = 0;
        return true;
    }

    void Close()
    {
        if (m_bOpen) {
            unzCloseCurrentFile(m_uf);
            m_bOpen = false;
        }
    }

    uint64_t Position() const { return m_uPos; }

    // Appends up to length bytes to out. Returns false only on a decode error;
    // a short read means the entry ended.
    bool Read(size_t length, string& out)
    {
        char buffer[64 * 1024];
        size_t got = 0;
        while (got < length) {
            size_t want = length - got;
            if (want > sizeof(buffer)) want = sizeof(buffer);
            int read = unzReadCurrentFile(m_uf, buffer, (unsigned)want);
            if (read < 0) return false;
            if (0 == read) break;
            out.append(buffer, (size_t)read);
            m_uPos += (uint64_t)read;
            got += (size_t)read;
        }
        return true;
    }

    // Discards bytes until the stream sits at offset. Callers must compare
    // Position() afterwards; a truncated entry stops short.
    bool SkipTo(uint64_t offset)
    {
        char buffer[64 * 1024];
        while (m_uPos < offset) {
            uint64_t remain = offset - m_uPos;
            size_t want = (remain > sizeof(buffer)) ? sizeof(buffer) : (size_t)remain;
            int read = unzReadCurrentFile(m_uf, buffer, (unsigned)want);
            if (read < 0) return false;
            if (0 == read) break;
            m_uPos += (uint64_t)read;
        }
        return true;
    }

private:
    FSZipStream(const FSZipStream&);
    FSZipStream& operator=(const FSZipStream&);

    unzFile  m_uf;
    bool     m_bOpen;
    uint64_t m_uPos;
};

enum FSSliceResult
{
    FS_SLICE_NOT_MACHO,
    FS_SLICE_SHORT,     // valid Mach-O, but the caller must supply more bytes
    FS_SLICE_OK,
};

} // namespace

static inline uint32_t FSSwapIf(bool swap, uint32_t value)
{
    return swap ? __builtin_bswap32(value) : value;
}

// Classifies one Mach-O slice from its leading bytes.
//
// `signed` here means the slice carries an LC_CODE_SIGNATURE with a non-empty
// payload, which is what the preflight card's "n/m signed" line reports.
// Confirming the superblob magic would mean inflating every binary to its very
// end -- precisely the cost this path exists to avoid.
static FSSliceResult FSClassifySlice(const string& head,
                                     bool& isSigned,
                                     bool& isEncrypted,
                                     uint32_t& needed)
{
    needed = 0;
    if (head.size() < sizeof(mach_header)) return FS_SLICE_NOT_MACHO;

    const uint8_t* base = (const uint8_t*)head.data();
    uint32_t magic = 0;
    memcpy(&magic, base, sizeof(magic));

    bool is64Bit = false;
    bool swap = false;
    if (MH_MAGIC == magic)          { is64Bit = false; swap = false; }
    else if (MH_CIGAM == magic)     { is64Bit = false; swap = true;  }
    else if (MH_MAGIC_64 == magic)  { is64Bit = true;  swap = false; }
    else if (MH_CIGAM_64 == magic)  { is64Bit = true;  swap = true;  }
    else return FS_SLICE_NOT_MACHO;

    const mach_header* header = (const mach_header*)base;
    uint32_t headerSize = is64Bit ? (uint32_t)sizeof(mach_header_64) : (uint32_t)sizeof(mach_header);
    uint32_t commandCount = FSSwapIf(swap, header->ncmds);
    uint32_t commandsSize = FSSwapIf(swap, header->sizeofcmds);

    if (commandsSize > kMaxLoadCommandBytes) return FS_SLICE_NOT_MACHO;
    needed = headerSize + commandsSize;
    if (head.size() < needed) return FS_SLICE_SHORT;

    uint32_t offset = headerSize;
    for (uint32_t i = 0; i < commandCount; i++) {
        if (offset + sizeof(load_command) > needed) break;

        const load_command* command = (const load_command*)(base + offset);
        uint32_t cmd = FSSwapIf(swap, command->cmd);
        uint32_t cmdSize = FSSwapIf(swap, command->cmdsize);
        if (cmdSize < sizeof(load_command) || offset + cmdSize > needed) break;

        if (LC_CODE_SIGNATURE == cmd) {
            if (cmdSize >= sizeof(codesignature_command)) {
                const codesignature_command* cs = (const codesignature_command*)(base + offset);
                if (FSSwapIf(swap, cs->datasize) > 0) isSigned = true;
            }
        } else if (LC_ENCRYPTION_INFO == cmd || LC_ENCRYPTION_INFO_64 == cmd) {
            if (cmdSize >= sizeof(encryption_info_command)) {
                const encryption_info_command* crypt = (const encryption_info_command*)(base + offset);
                if (FSSwapIf(swap, crypt->cryptid) >= 1) isEncrypted = true;
            }
        }

        offset += cmdSize;
    }

    return FS_SLICE_OK;
}

// Reads enough of the current entry to classify it. Mirrors ZMachO's reporting:
// a file counts as signed when every slice is signed, and as encrypted when any
// slice is. Returns false when the entry is not a Mach-O at all.
static bool FSClassifyMachOEntry(unzFile uf, bool& isSigned, bool& isEncrypted)
{
    FSZipStream stream(uf);
    if (!stream.Open()) return false;

    string head;
    if (!stream.Read(kMachOProbeBytes, head) || head.size() < sizeof(uint32_t)) return false;

    uint32_t magic = 0;
    memcpy(&magic, head.data(), sizeof(magic));

    if (FAT_MAGIC == magic || FAT_CIGAM == magic) {
        bool fatSwap = (FAT_CIGAM == magic);
        const fat_header* fat = (const fat_header*)head.data();
        uint32_t archCount = FSSwapIf(fatSwap, fat->nfat_arch);
        size_t tableEnd = sizeof(fat_header) + (size_t)archCount * sizeof(fat_arch);
        if (0 == archCount || archCount > 32 || head.size() < tableEnd) return false;

        vector<uint64_t> offsets;
        for (uint32_t i = 0; i < archCount; i++) {
            const fat_arch* arch = (const fat_arch*)(head.data() + sizeof(fat_header) + sizeof(fat_arch) * i);
            offsets.push_back((uint64_t)FSSwapIf(fatSwap, arch->offset));
        }
        // A forward-only stream can visit the slices in file order only.
        sort(offsets.begin(), offsets.end());

        bool sawSlice = false;
        bool allSigned = true;
        for (size_t i = 0; i < offsets.size(); i++) {
            uint64_t offset = offsets[i];
            if (offset < stream.Position() || offset > kMaxFatScanBytes) break;
            if (!stream.SkipTo(offset) || stream.Position() != offset) break;

            string slice;
            if (!stream.Read(kMachOProbeBytes, slice)) break;

            bool sliceSigned = false;
            uint32_t needed = 0;
            FSSliceResult result = FSClassifySlice(slice, sliceSigned, isEncrypted, needed);
            if (FS_SLICE_SHORT == result) {
                if (!stream.Read(needed - slice.size(), slice)) break;
                result = FSClassifySlice(slice, sliceSigned, isEncrypted, needed);
            }
            if (FS_SLICE_OK != result) break;

            sawSlice = true;
            if (!sliceSigned) allSigned = false;
        }

        if (!sawSlice) return false;
        isSigned = allSigned;
        return true;
    }

    bool sliceSigned = false;
    uint32_t needed = 0;
    FSSliceResult result = FSClassifySlice(head, sliceSigned, isEncrypted, needed);
    if (FS_SLICE_SHORT == result) {
        if (!stream.Read(needed - head.size(), head)) return false;
        result = FSClassifySlice(head, sliceSigned, isEncrypted, needed);
    }
    if (FS_SLICE_OK != result) return false;

    isSigned = sliceSigned;
    return true;
}

// Walks the central directory only -- no entry is decompressed here.
static bool FSReadZipIndex(unzFile uf, vector<FSZipEntry>& entries)
{
    if (UNZ_OK != unzGoToFirstFile(uf)) return false;

    do {
        unz_file_info64 info = { 0 };
        char rawPath[PATH_MAX] = { 0 };
        if (UNZ_OK != unzGetCurrentFileInfo64(uf, &info, rawPath, PATH_MAX, NULL, 0, NULL, 0)) {
            return false;
        }

        FSZipEntry entry;
        entry.path = rawPath;
        ZUtil::StringTrim(entry.path);
        ZUtil::StringReplace(entry.path, "\\", "/");
        entry.isDirectory = (!entry.path.empty() && '/' == entry.path.back());
        while (!entry.path.empty() && '/' == entry.path.back()) {
            entry.path.pop_back();
        }
        if (entry.path.empty()) continue;

        entry.uncompressedSize = info.uncompressed_size;
        if (UNZ_OK != unzGetFilePos64(uf, &entry.pos)) return false;

        entries.push_back(entry);
    } while (UNZ_OK == unzGoToNextFile(uf));

    return true;
}

// Reads one entry whole, up to a cap that keeps a crafted archive from
// ballooning memory.
static bool FSReadZipEntry(unzFile uf, const FSZipEntry& entry, uint64_t maxBytes, string& out)
{
    out.clear();
    if (entry.uncompressedSize > maxBytes) return false;
    if (UNZ_OK != unzGoToFilePos64(uf, &entry.pos)) return false;

    FSZipStream stream(uf);
    if (!stream.Open()) return false;
    if (!stream.Read((size_t)maxBytes, out)) return false;

    return true;
}

extern "C" int forgesign_inspect_ipa(const char* ipaPath,
                                      const char* tempFolder,
                                      char* jsonBuf,
                                      int jsonBufLen,
                                      char* msgBuf,
                                      int msgBufLen)
{
    auto setMsg = [&](const string& message) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", message.c_str());
        }
    };

    string strIpa = ipaPath ? ipaPath : "";
    string strTemp = tempFolder ? tempFolder : "";
    if (strIpa.empty() || strTemp.empty()) {
        setMsg("Missing IPA or temporary folder.");
        return 1;
    }
    if (!ZFile::IsFileExists(strIpa.c_str())) {
        setMsg("IPA not found.");
        return 2;
    }
    if (!ZFile::IsZipFile(strIpa.c_str())) {
        setMsg("Input is not a valid IPA/zip.");
        return 3;
    }
    if (!ZFile::IsFolder(strTemp.c_str())) {
        setMsg("Invalid temporary folder.");
        return 4;
    }

    unzFile uf = unzOpen64(strIpa.c_str());
    if (NULL == uf) {
        setMsg("Could not read the IPA. The downloaded file may be incomplete or corrupted.");
        return 5;
    }

    vector<FSZipEntry> entries;
    if (!FSReadZipIndex(uf, entries) || entries.empty()) {
        unzClose(uf);
        setMsg("Could not read the IPA. The downloaded file may be incomplete or corrupted.");
        return 5;
    }

    // Locate Payload/<name>.app. Directory entries are optional in a zip, so
    // the folder is derived from the entry paths themselves.
    string appFolder;
    for (size_t i = 0; i < entries.size(); i++) {
        const string& path = entries[i].path;
        if (0 != path.rfind("Payload/", 0)) continue;

        size_t sep = path.find('/', 8);
        string candidate = (string::npos == sep) ? path : path.substr(0, sep);
        if (!ZFile::IsPathSuffix(candidate, ".app")) continue;
        // Deterministic pick when an archive somehow carries more than one.
        if (appFolder.empty() || candidate < appFolder) appFolder = candidate;
    }
    if (appFolder.empty()) {
        unzClose(uf);
        setMsg("No Payload/*.app bundle was found.");
        return 6;
    }

    const string prefix = appFolder + "/";

    // Every path component below the app folder is a directory, whether or not
    // the archive bothered to store an explicit entry for it.
    set<string> folders;
    for (size_t i = 0; i < entries.size(); i++) {
        const string& path = entries[i].path;
        if (0 != path.rfind(prefix, 0)) continue;

        string relative = path.substr(prefix.size());
        size_t limit = entries[i].isDirectory ? relative.size() : relative.rfind('/');
        if (string::npos == limit) continue;

        for (size_t sep = relative.find('/'); ; sep = relative.find('/', sep + 1)) {
            size_t cut = (string::npos == sep || sep > limit) ? limit : sep;
            if (cut > 0) folders.insert(relative.substr(0, cut));
            if (string::npos == sep || sep >= limit) break;
        }
    }

    jvalue result(jvalue::E_OBJECT);
    int nestedBundleCount = 0;
    int extensionCount = 0;
    int frameworkCount = 0;
    int watchAppCount = 0;

    for (set<string>::const_iterator it = folders.begin(); it != folders.end(); ++it) {
        const string& folder = *it;
        bool isApp = ZFile::IsPathSuffix(folder, ".app");
        if (isApp ||
            ZFile::IsPathSuffix(folder, ".appex") ||
            ZFile::IsPathSuffix(folder, ".framework") ||
            ZFile::IsPathSuffix(folder, ".xctest")) {
            nestedBundleCount += 1;
        }
        if (ZFile::IsPathSuffix(folder, ".appex")) extensionCount += 1;
        if (ZFile::IsPathSuffix(folder, ".framework")) frameworkCount += 1;
        if (isApp) {
            string anchored = "/" + folder;
            if (string::npos != anchored.find("/Watch/") ||
                string::npos != anchored.find("/WatchKit/")) {
                watchAppCount += 1;
            }
        }
    }

    // Info.plist drives the name, identifier, versions and icon lookup. An
    // unreadable one is not fatal: the inspection still reports the structural
    // counts, and the signer reports its own error later, exactly as it did
    // when this ran off an extracted folder.
    string infoPlistData;
    for (size_t i = 0; i < entries.size(); i++) {
        if (entries[i].isDirectory || entries[i].path != prefix + "Info.plist") continue;
        FSReadZipEntry(uf, entries[i], kMaxInfoPlistBytes, infoPlistData);
        break;
    }

    string appName = FSReadPlistStringFromData(infoPlistData, "CFBundleDisplayName");
    if (appName.empty()) appName = FSReadPlistStringFromData(infoPlistData, "CFBundleName");
    if (appName.empty()) appName = ZUtil::GetBaseName(appFolder.c_str());

    // Icons sit as PNG files directly inside the app bundle; copy out the
    // largest declared rendition so SwiftUI can display it.
    vector<string> iconNames;
    FSGetIconNames(infoPlistData, iconNames);

    const FSZipEntry* bestIcon = NULL;
    for (size_t i = 0; i < entries.size(); i++) {
        const FSZipEntry& entry = entries[i];
        if (entry.isDirectory || 0 != entry.path.rfind(prefix, 0)) continue;

        string relative = entry.path.substr(prefix.size());
        if (string::npos != relative.find('/')) continue;   // top level only
        if (!ZFile::IsPathSuffix(relative, ".png")) continue;

        bool isIcon = false;
        for (size_t n = 0; n < iconNames.size(); n++) {
            const string& name = iconNames[n];
            if (relative.size() >= name.size() && 0 == relative.compare(0, name.size(), name)) {
                isIcon = true;
                break;
            }
        }
        // Modern packages occasionally omit icon names from Info.plist. Retain
        // a conservative AppIcon fallback rather than showing a generic symbol.
        if (!isIcon && iconNames.empty() && string::npos != relative.find("AppIcon")) {
            isIcon = true;
        }
        if (!isIcon) continue;

        if (NULL == bestIcon || entry.uncompressedSize > bestIcon->uncompressedSize) {
            bestIcon = &entry;
        }
    }

    string iconPath;
    if (NULL != bestIcon) {
        string iconData;
        if (FSReadZipEntry(uf, *bestIcon, kMaxIconBytes, iconData) && !iconData.empty()) {
            string destination = ZFile::GetRealPathV("%s/fs_icon_%llu.png",
                                                     strTemp.c_str(), ZUtil::GetMicroSecond());
            if (ZFile::WriteFile(destination.c_str(), iconData)) {
                iconPath = destination;
            }
        }
    }

    // Mach-O tallies. Walking the archive in stored order keeps the reads
    // sequential; each candidate stops as soon as its load commands are in.
    int totalMachOCount = 0;
    int signedMachOCount = 0;
    int encryptedExecutableCount = 0;
    jvalue encryptedPaths(jvalue::E_ARRAY);

    for (size_t i = 0; i < entries.size(); i++) {
        const FSZipEntry& entry = entries[i];
        if (entry.isDirectory || 0 == entry.uncompressedSize) continue;
        if (0 != entry.path.rfind(prefix, 0)) continue;
        if (UNZ_OK != unzGoToFilePos64(uf, &entry.pos)) continue;

        bool isSigned = false;
        bool isEncrypted = false;
        if (!FSClassifyMachOEntry(uf, isSigned, isEncrypted)) continue;

        totalMachOCount += 1;
        if (isSigned) signedMachOCount += 1;
        if (isEncrypted) {
            encryptedExecutableCount += 1;
            if (encryptedPaths.size() < 8) {
                encryptedPaths.push_back(entry.path.substr(prefix.size()));
            }
        }
    }

    unzClose(uf);

    result["appName"] = appName;
    result["appIconPath"] = iconPath;
    result["bundleIdentifier"] = FSReadPlistStringFromData(infoPlistData, "CFBundleIdentifier");
    result["shortVersion"] = FSReadPlistStringFromData(infoPlistData, "CFBundleShortVersionString");
    result["buildVersion"] = FSReadPlistStringFromData(infoPlistData, "CFBundleVersion");
    result["minimumOSVersion"] = FSReadPlistStringFromData(infoPlistData, "MinimumOSVersion");
    result["nestedBundleCount"] = nestedBundleCount;
    result["extensionCount"] = extensionCount;
    result["frameworkCount"] = frameworkCount;
    result["watchAppCount"] = watchAppCount;
    result["totalMachOCount"] = totalMachOCount;
    result["signedMachOCount"] = signedMachOCount;
    result["encryptedExecutableCount"] = encryptedExecutableCount;
    result["encryptedPaths"] = encryptedPaths;

    string json;
    result.style_write(json);
    if (!jsonBuf || jsonBufLen <= 0 || json.size() + 1 > (size_t)jsonBufLen) {
        setMsg("Inspection result was too large.");
        return 7;
    }
    snprintf(jsonBuf, jsonBufLen, "%s", json.c_str());
    setMsg("IPA inspected.");
    return 0;
}

// Validates a PKCS#12 with the same OpenSSL engine used for signing (the
// system SecPKCS12Import rejects OpenSSL-3 style AES-256 p12 files) and
// reports subject CN / O / OU plus the notAfter epoch for the UI.
static void FSCopyNameEntry(X509_NAME* name, int nid, char* buf, int len)
{
    if (!name || !buf || len <= 0) return;
    buf[0] = 0;
    int idx = X509_NAME_get_index_by_NID(name, nid, -1);
    if (idx < 0) return;
    X509_NAME_ENTRY* entry = X509_NAME_get_entry(name, idx);
    if (!entry) return;
    ASN1_STRING* data = X509_NAME_ENTRY_get_data(entry);
    if (!data) return;
    unsigned char* utf8 = NULL;
    int n = ASN1_STRING_to_UTF8(&utf8, data);
    if (n < 0 || !utf8) return;
    snprintf(buf, len, "%.*s", n, (const char*)utf8);
    OPENSSL_free(utf8);
}

extern "C" int forgesign_p12_info(const char* p12Path,
                                  const char* password,
                                  char* cnBuf,
                                  int cnLen,
                                  char* oBuf,
                                  int oLen,
                                  char* ouBuf,
                                  int ouLen,
                                  long long* notAfterEpoch,
                                  char* msgBuf,
                                  int msgBufLen)
{
    auto setMsg = [&](const string& m) {
        if (msgBuf && msgBufLen > 0) {
            snprintf(msgBuf, msgBufLen, "%s", m.c_str());
        }
    };

    if (!p12Path) {
        setMsg("Missing certificate path.");
        return 1;
    }
    FILE* fp = fopen(p12Path, "rb");
    if (!fp) {
        setMsg("Certificate file could not be opened.");
        return 2;
    }
    PKCS12* p12 = d2i_PKCS12_fp(fp, NULL);
    fclose(fp);
    if (!p12) {
        setMsg("Not a valid PKCS#12 file.");
        return 3;
    }

    EVP_PKEY* pkey = NULL;
    X509* cert = NULL;
    int ok = PKCS12_parse(p12, password ? password : "", &pkey, &cert, NULL);
    PKCS12_free(p12);
    if (!ok || !cert) {
        if (pkey) EVP_PKEY_free(pkey);
        if (cert) X509_free(cert);
        setMsg("Wrong password, or not a valid signing certificate.");
        return 4;
    }

    X509_NAME* subj = X509_get_subject_name(cert);
    FSCopyNameEntry(subj, NID_commonName, cnBuf, cnLen);
    FSCopyNameEntry(subj, NID_organizationName, oBuf, oLen);
    FSCopyNameEntry(subj, NID_organizationalUnitName, ouBuf, ouLen);

    if (notAfterEpoch) {
        *notAfterEpoch = 0;
        const ASN1_TIME* na = X509_get0_notAfter(cert);
        if (na) {
            struct tm tmv;
            memset(&tmv, 0, sizeof(tmv));
            if (ASN1_TIME_to_tm(na, &tmv)) {
                *notAfterEpoch = (long long)timegm(&tmv);
            }
        }
    }

    if (pkey) EVP_PKEY_free(pkey);
    X509_free(cert);
    return 0;
}

// Returns the zsign version string.
extern "C" const char* forgesign_zsign_version(void)
{
    return "zsign-embedded";
}
