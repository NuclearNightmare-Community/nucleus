// minisign signatures and hashes for the signed catalog (Mod Manager v2 story 2): what verify.ps1 checks itself in
// CheckSignature and what it leaves to `minisign -V`, here in one place.
//   - parse_sig: verify.ps1's own reading of a .minisig (Get-Content's first 4 lines, "untrusted comment:" and
//     "trusted comment:" prefixes ignoring case, line 2 through Convert.FromBase64String: 74 bytes, "Ed" or "ED"), and
//     the key id it names;
//   - verify: what `minisign -V -P <key> -m <file> -x <sig>` (0.12) accepts: its own line reading (fgets, trim, exact
//     prefixes, a printable trusted comment, strict base64), the key id, then Ed25519 over the file ("Ed") or over its
//     BLAKE2b-512 ("ED"), and the global signature over signature || trusted comment. Ed25519 and BLAKE2b are
//     Monocypher 4.0.2's (Windows CNG has no Ed25519); SHA-256 is Windows CNG's (BCrypt).
#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace catalog::sig
{
    // Convert.FromBase64String: ' ', '\t', '\r', '\n' ignored anywhere, '=' padding only at the end.
    bool dotnet_base64(std::string_view s, std::vector<uint8_t>& out);
    std::string hex_upper(const uint8_t* p, size_t n);
    std::string hex_lower(const uint8_t* p, size_t n);

    // verify.ps1's KeyId: base64 of "Ed" + 8-byte key id + 32-byte key (after .Trim()) -> 16 upper-case hex digits.
    std::optional<std::string> key_id(std::string_view b64);
    // The 42 decoded bytes of a minisign public key (same rules as key_id).
    std::optional<std::array<uint8_t, 42>> public_key(std::string_view b64);

    // verify.ps1's checks of a .minisig's text (not its size: the caller caps it at 4096 bytes first).
    struct Parsed
    {
        bool malformed = true;
        std::string key_id; // 16 upper-case hex digits
    };
    Parsed parse_sig(const std::vector<uint8_t>& sig_file);

    // `minisign -V` with public key pk (42 bytes) over message. True only when everything verifies.
    bool verify(const std::vector<uint8_t>& sig_file, const uint8_t* message, size_t message_len, const std::array<uint8_t, 42>& pk);

    // SHA-256 (Windows CNG). Incremental, for files streamed in chunks.
    class Sha256
    {
      public:
        Sha256();
        ~Sha256();
        Sha256(const Sha256&) = delete;
        Sha256& operator=(const Sha256&) = delete;
        bool ok() const { return m_ok; }
        void update(const uint8_t* p, size_t n);
        std::array<uint8_t, 32> finish();

      private:
        void* m_alg = nullptr;
        void* m_hash = nullptr;
        bool m_ok = false;
    };
} // namespace catalog::sig
