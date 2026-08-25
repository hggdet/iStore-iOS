#include "sha.h"
#include "base64.h"
#include <openssl/sha.h>

bool ZSHA::SHA1(uint8_t* data, size_t size, string& strOutput)
{
	strOutput.clear();
	uint8_t hash[20];
	::SHA1(data, size, hash);
	strOutput.append((const char*)hash, 20);
	return true;
}

bool ZSHA::SHA256(uint8_t* data, size_t size, string& strOutput)
{
	strOutput.clear();
	uint8_t hash[32];
	::SHA256(data, size, hash);
	strOutput.append((const char*)hash, 32);
	return true;
}

bool ZSHA::SHA1(const string& strData, string& strOutput)
{
	return ZSHA::SHA1((uint8_t*)strData.data(), strData.size(), strOutput);
}

bool ZSHA::SHA256(const string& strData, string& strOutput)
{
	return ZSHA::SHA256((uint8_t*)strData.data(), strData.size(), strOutput);
}

// Feeds both digests from one walk over the data. Hashing SHA1 and SHA256 in
// separate passes streams every byte twice, which is a real cost on the
// multi-hundred-megabyte bundles this signer seals.
static bool SHADual(const uint8_t* data, size_t size, string& strSHA1, string& strSHA256)
{
	strSHA1.clear();
	strSHA256.clear();

	SHA_CTX ctxSHA1;
	SHA256_CTX ctxSHA256;
	if (1 != SHA1_Init(&ctxSHA1) || 1 != SHA256_Init(&ctxSHA256)) {
		return false;
	}

	// Chunked so both digests consume the same bytes while they are still in
	// cache, rather than each sweeping the whole mapping end to end.
	const size_t sChunk = 1024 * 1024;
	for (size_t sOffset = 0; sOffset < size; sOffset += sChunk) {
		size_t sLength = ((size - sOffset) < sChunk) ? (size - sOffset) : sChunk;
		if (1 != SHA1_Update(&ctxSHA1, data + sOffset, sLength) ||
			1 != SHA256_Update(&ctxSHA256, data + sOffset, sLength)) {
			return false;
		}
	}

	uint8_t hashSHA1[20];
	uint8_t hashSHA256[32];
	if (1 != SHA1_Final(hashSHA1, &ctxSHA1) || 1 != SHA256_Final(hashSHA256, &ctxSHA256)) {
		return false;
	}

	strSHA1.append((const char*)hashSHA1, sizeof(hashSHA1));
	strSHA256.append((const char*)hashSHA256, sizeof(hashSHA256));
	return true;
}

bool ZSHA::SHA(const string& strData, string& strSHA1, string& strSHA256)
{
	SHADual((const uint8_t*)strData.data(), strData.size(), strSHA1, strSHA256);
	return (!strSHA1.empty() && !strSHA256.empty());
}

bool ZSHA::SHA1Text(const string& strData, string& strOutput)
{
	string strSHASum;
	ZSHA::SHA1(strData, strSHASum);

	static const char hex_lower[] = "0123456789abcdef";
	strOutput.clear();
	strOutput.reserve(strSHASum.size() * 2);
	for (size_t i = 0; i < strSHASum.size(); i++) {
		uint8_t c = (uint8_t)strSHASum[i];
		strOutput += hex_lower[c >> 4];
		strOutput += hex_lower[c & 0x0F];
	}
	return (!strOutput.empty());
}

bool ZSHA::SHAFile(const char* szFile, string& strSHA1, string& strSHA256)
{
	strSHA1.clear();
	strSHA256.clear();
	size_t sSize = 0;
	uint8_t* pBase = (uint8_t*)ZFile::MapFile(szFile, 0, 0, &sSize, true);
	// pBase may be NULL, but it's ok, because the file may be empty
#ifndef _WIN32
	if (NULL != pBase && sSize > 0) {
		// The mapping is read straight through exactly once, so let the kernel
		// read ahead instead of faulting a page at a time.
		posix_madvise(pBase, sSize, POSIX_MADV_SEQUENTIAL);
	}
#endif
	SHADual(pBase, sSize, strSHA1, strSHA256);
	if (NULL != pBase && sSize > 0) {
		ZFile::UnmapFile(pBase, sSize);
	}
	return (!strSHA1.empty() && !strSHA256.empty());
}

bool ZSHA::SHABase64(const string& strData, string& strSHA1Base64, string& strSHA256Base64)
{
	jbase64 b64;
	string strSHA1;
	string strSHA256;
	SHA(strData, strSHA1, strSHA256);
	strSHA1Base64 = b64.encode(strSHA1);
	strSHA256Base64 = b64.encode(strSHA256);
	return (!strSHA1Base64.empty() && !strSHA256Base64.empty());
}

bool ZSHA::SHABase64File(const char* szFile, string& strSHA1Base64, string& strSHA256Base64)
{
	jbase64 b64;
	string strSHA1;
	string strSHA256;
	SHAFile(szFile, strSHA1, strSHA256);
	strSHA1Base64 = b64.encode(strSHA1);
	strSHA256Base64 = b64.encode(strSHA256);
	return (!strSHA1Base64.empty() && !strSHA256Base64.empty());
}

void ZSHA::Print(const char* prefix, const uint8_t* hash, uint32_t size, const char* suffix)
{
	ZLog::PrintV("%s", prefix);
	for (uint32_t i = 0; i < size; i++) {
		ZLog::PrintV("%02x", hash[i]);
	}
	ZLog::PrintV("%s", suffix);
}

void ZSHA::Print(const char* prefix, const string& strSHASum, const char* suffix)
{
	Print(prefix, (const uint8_t*)strSHASum.data(), (uint32_t)strSHASum.size(), suffix);
}

void ZSHA::PrintData1(const char* prefix, const string& strData, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA1(strData, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData1(const char* prefix, uint8_t* data, size_t size, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA1(data, size, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData256(const char* prefix, const string& strData, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA256(strData, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData256(const char* prefix, uint8_t* data, size_t size, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA256(data, size, strSHASum);
	Print(prefix, strSHASum, suffix);
}
