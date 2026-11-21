// minisign signatures and SHA-256 (minisig.hpp).
#include "minisig.hpp"

#include <cstring>

#include "text.hpp"

extern "C"
{
#include "monocypher.h"
#include "optional/monocypher-ed25519.h"
}

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <bcrypt.h>

namespace catalog::sig
{
    namespace
    {
        int b64_value(unsigned char c)
        {
            if (c >= 'A' && c <= 'Z') return c - 'A';
            if (c >= 'a' && c <= 'z') return c - 'a' + 26;
            if (c >= '0' && c <= '9') return c - '0' + 52;
            if (c == '+') return 62;
            if (c == '/') return 63;
            return -1;
        }

        // minisign's b64_to_bin (src/base64.c, 0.12), byte for byte in behaviour.
        bool minisign_b64(std::string_view b64, size_t bin_maxlen, std::vector<uint8_t>& out)
        {
            constexpr unsigned NONE = 64U, EOT = 128U;
            auto rev = [&](unsigned char c) -> unsigned {
                if (c == '=') return EOT;
                const int v = b64_value(c);
                return v < 0 ? NONE : static_cast<unsigned>(v);
            };
            const size_t len = b64.size();
            size_t i;
            if (len % 4U != 0U || (i = len / 4U) == 0U) return false;
            const size_t pads = (b64[len - 1] == '=' ? 1U : 0U) + (b64[len - 2] == '=' ? 1U : 0U);
            if (bin_maxlen < i * 3U - pads) return false;
            out.clear();
            size_t at = 0;
            unsigned t0 = 0, t1 = 0, t2 = 0, t3 = 0, mask = 0;
            uint32_t t = 0;
            while (i-- > 0U)
            {
                t0 = rev(static_cast<unsigned char>(b64[at++]));
                t1 = rev(static_cast<unsigned char>(b64[at++]));
                t2 = rev(static_cast<unsigned char>(b64[at++]));
                t3 = rev(static_cast<unsigned char>(b64[at++]));
                t = t3 | (t2 << 6) | (t1 << 12) | (t0 << 18);
                mask = t0 | t1 | t2 | t3;
                if ((mask & (NONE | EOT)) != 0U)
                {
                    if ((mask & NONE) != 0U || i > 0U) return false;
                    break;
                }
                out.push_back(static_cast<uint8_t>(t >> 16));
                out.push_back(static_cast<uint8_t>(t >> 8));
                out.push_back(static_cast<uint8_t>(t));
            }
            if ((mask & EOT) != 0U)
            {
                if (((t0 | t1) & EOT) != 0U || t3 != EOT) return false;
                out.push_back(static_cast<uint8_t>(t >> 16));
                if (t2 != EOT) out.push_back(static_cast<uint8_t>(t >> 8));
            }
            return true;
        }

        // minisign's trim (src/helpers.c): drops one trailing "\n" then one "\r"; 0 when there was no "\n" or a "\r"
        // remains inside.
        bool minisign_trim(std::string& s)
        {
            if (s.empty()) return false;
            bool t = false;
            if (s.back() == '\n')
            {
                s.pop_back();
                t = true;
            }
            if (!s.empty() && s.back() == '\r') s.pop_back();
            if (s.find('\r') != std::string::npos) return false;
            return t;
        }

        // minisign's is_printable: tab, printable ASCII and valid UTF-8 above U+009F.
        bool printable(const std::string& s)
        {
            const auto* p = reinterpret_cast<const unsigned char*>(s.c_str());
            while (*p != 0U)
            {
                const unsigned char c = *p++;
                if (c == '\t' || (c >= 0x20U && c <= 0x7eU)) continue;
                if (c < 0x20U || c == 0x7fU) return false;
                size_t need;
                if (c >= 0xc2U && c <= 0xdfU) need = 1U;
                else if (c >= 0xe0U && c <= 0xefU) need = 2U;
                else if (c >= 0xf0U && c <= 0xf4U) need = 3U;
                else return false;
                for (size_t i = 1U; i <= need; i++)
                {
                    const unsigned char cc = p[i - 1U];
                    if (cc == 0U || (cc & 0xc0U) != 0x80U) return false;
                }
                if ((c == 0xe0U && p[0] < 0xa0U) || (c == 0xedU && p[0] > 0x9fU) || (c == 0xf0U && p[0] < 0x90U) || (c == 0xf4U && p[0] > 0x8fU)) return false;
                uint32_t cp = c & (need == 1U ? 0x1fU : need == 2U ? 0x0fU : 0x07U);
                for (size_t i = 1U; i <= need; i++) cp = (cp << 6) | (p[i - 1U] & 0x3fU);
                if (cp <= 0x1fU || (cp >= 0x7fU && cp <= 0x9fU)) return false;
                p += need;
            }
            return true;
        }

        // fopen(..., "r") + fgets on Windows: the CRT's text mode ends the file at Ctrl+Z and reads CR LF as LF.
        struct TextReader
        {
            std::string data;
            size_t pos = 0;
            explicit TextReader(const std::vector<uint8_t>& raw)
            {
                for (size_t i = 0; i < raw.size(); ++i)
                {
                    const char c = static_cast<char>(raw[i]);
                    if (c == 0x1A) break;
                    if (c == '\r' && i + 1 < raw.size() && raw[i + 1] == '\n') continue;
                    data.push_back(c);
                }
            }
            // fgets(buf, n): at most n-1 bytes, through the first '\n'; false at end of file. The result is the C
            // string (up to the first NUL byte), as the caller's strlen sees it.
            bool fgets(size_t n, std::string& out)
            {
                if (pos >= data.size()) return false;
                const size_t start = pos;
                while (pos < data.size() && pos - start < n - 1)
                {
                    if (data[pos++] == '\n') break;
                }
                out.assign(data, start, pos - start);
                const auto nul = out.find('\0');
                if (nul != std::string::npos) out.resize(nul);
                return true;
            }
        };

        // Get-Content's lines: split at CR LF, LF or CR; a last terminator ends the last line.
        std::vector<std::string> ps_lines(const std::string& s, size_t max)
        {
            std::vector<std::string> lines;
            size_t i = 0;
            std::string cur;
            while (i < s.size() && lines.size() < max)
            {
                const char c = s[i];
                if (c == '\r' || c == '\n')
                {
                    lines.push_back(cur);
                    cur.clear();
                    if (c == '\r' && i + 1 < s.size() && s[i + 1] == '\n') ++i;
                    ++i;
                    continue;
                }
                cur.push_back(c);
                ++i;
            }
            if (lines.size() < max && !cur.empty()) lines.push_back(cur);
            return lines;
        }
    } // namespace

    bool dotnet_base64(std::string_view s, std::vector<uint8_t>& out)
    {
        std::string c;
        for (const char ch : s)
        {
            if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') continue;
            c.push_back(ch);
        }
        out.clear();
        if (c.size() % 4 != 0) return false;
        size_t pads = 0;
        while (pads < c.size() && c[c.size() - 1 - pads] == '=') ++pads;
        if (pads > 2) return false;
        const size_t body = c.size() - pads;
        uint32_t acc = 0;
        int bits = 0;
        for (size_t i = 0; i < body; ++i)
        {
            const int v = b64_value(static_cast<unsigned char>(c[i]));
            if (v < 0) return false;
            acc = (acc << 6) | static_cast<uint32_t>(v);
            bits += 6;
            if (bits >= 8)
            {
                bits -= 8;
                out.push_back(static_cast<uint8_t>((acc >> bits) & 0xFF));
            }
        }
        return true;
    }

    std::string hex_upper(const uint8_t* p, size_t n)
    {
        static const char* d = "0123456789ABCDEF";
        std::string o;
        for (size_t i = 0; i < n; ++i)
        {
            o.push_back(d[p[i] >> 4]);
            o.push_back(d[p[i] & 15]);
        }
        return o;
    }
    std::string hex_lower(const uint8_t* p, size_t n) { return text::lower(hex_upper(p, n)); }

    std::optional<std::array<uint8_t, 42>> public_key(std::string_view b64)
    {
        std::vector<uint8_t> b;
        if (!dotnet_base64(text::trim(b64), b) || b.size() != 42 || b[0] != 0x45 || b[1] != 0x64) return std::nullopt;
        std::array<uint8_t, 42> k{};
        std::memcpy(k.data(), b.data(), 42);
        return k;
    }

    std::optional<std::string> key_id(std::string_view b64)
    {
        const auto k = public_key(b64);
        if (!k) return std::nullopt;
        return hex_upper(k->data() + 2, 8);
    }

    Parsed parse_sig(const std::vector<uint8_t>& sig_file)
    {
        Parsed r;
        std::string_view all{reinterpret_cast<const char*>(sig_file.data()), sig_file.size()};
        if (all.size() >= 3 && static_cast<unsigned char>(all[0]) == 0xEF && static_cast<unsigned char>(all[1]) == 0xBB &&
            static_cast<unsigned char>(all[2]) == 0xBF)
        {
            all.remove_prefix(3);
        }
        const auto lines = ps_lines(std::string{all}, 4);
        if (lines.size() < 4 || !text::istarts(lines[0], "untrusted comment:") || !text::istarts(lines[2], "trusted comment:")) return r;
        std::vector<uint8_t> sig;
        if (!dotnet_base64(text::trim(lines[1]), sig) || sig.size() != 74 || sig[0] != 0x45 || (sig[1] != 0x44 && sig[1] != 0x64)) return r;
        r.malformed = false;
        r.key_id = hex_upper(sig.data() + 2, 8);
        return r;
    }

    bool verify(const std::vector<uint8_t>& sig_file, const uint8_t* message, size_t message_len, const std::array<uint8_t, 42>& pk)
    {
        TextReader rd{sig_file};
        std::string comment, sig_s, trusted, global_s;
        // sig_load
        if (!rd.fgets(1024, comment) || !minisign_trim(comment)) return false;
        if (comment.rfind("untrusted comment: ", 0) != 0) return false;
        if (!rd.fgets(((74 + 2) / 3) * 4 + 1 + 2, sig_s) || !minisign_trim(sig_s)) return false;
        if (!rd.fgets(8192, trusted)) return false;
        if (trusted.rfind("trusted comment: ", 0) != 0) return false;
        trusted.erase(0, std::strlen("trusted comment: "));
        if (!minisign_trim(trusted) || !printable(trusted)) return false;
        if (!rd.fgets(((64 + 2) / 3) * 4 + 1 + 2, global_s)) return false;
        (void)minisign_trim(global_s);
        std::vector<uint8_t> sig, global;
        if (!minisign_b64(sig_s, 74, sig) || sig.size() != 74) return false;
        bool hashed;
        if (sig[0] == 'E' && sig[1] == 'd') hashed = false;
        else if (sig[0] == 'E' && sig[1] == 'D') hashed = true;
        else return false;
        if (!minisign_b64(global_s, 64, global) || global.size() != 64) return false;
        // verify: key id, the signature over the file (or its BLAKE2b-512), then the global signature.
        if (std::memcmp(sig.data() + 2, pk.data() + 2, 8) != 0) return false;
        const uint8_t* key = pk.data() + 10;
        uint8_t hash[64];
        const uint8_t* signed_msg = message;
        size_t signed_len = message_len;
        if (hashed)
        {
            crypto_blake2b(hash, sizeof hash, message, message_len);
            signed_msg = hash;
            signed_len = sizeof hash;
        }
        if (crypto_ed25519_check(sig.data() + 10, key, signed_msg, signed_len) != 0) return false;
        std::vector<uint8_t> st(sig.begin() + 10, sig.end());
        st.insert(st.end(), trusted.begin(), trusted.end());
        return crypto_ed25519_check(global.data(), key, st.data(), st.size()) == 0;
    }

    Sha256::Sha256()
    {
        BCRYPT_ALG_HANDLE alg = nullptr;
        BCRYPT_HASH_HANDLE h = nullptr;
        if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return;
        if (BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) != 0)
        {
            BCryptCloseAlgorithmProvider(alg, 0);
            return;
        }
        m_alg = alg;
        m_hash = h;
        m_ok = true;
    }
    Sha256::~Sha256()
    {
        if (m_hash) BCryptDestroyHash(static_cast<BCRYPT_HASH_HANDLE>(m_hash));
        if (m_alg) BCryptCloseAlgorithmProvider(static_cast<BCRYPT_ALG_HANDLE>(m_alg), 0);
    }
    void Sha256::update(const uint8_t* p, size_t n)
    {
        while (m_ok && n > 0)
        {
            const ULONG chunk = n > 0x40000000 ? 0x40000000UL : static_cast<ULONG>(n);
            if (BCryptHashData(static_cast<BCRYPT_HASH_HANDLE>(m_hash), const_cast<PUCHAR>(p), chunk, 0) != 0) m_ok = false;
            p += chunk;
            n -= chunk;
        }
    }
    std::array<uint8_t, 32> Sha256::finish()
    {
        std::array<uint8_t, 32> out{};
        if (m_ok && BCryptFinishHash(static_cast<BCRYPT_HASH_HANDLE>(m_hash), out.data(), 32, 0) != 0) m_ok = false;
        return out;
    }
} // namespace catalog::sig
