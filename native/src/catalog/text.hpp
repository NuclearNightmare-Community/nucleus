// Text rules the catalog checks share with verify.ps1, where PowerShell works on .NET strings (UTF-16) and we on UTF-8:
// .Length in UTF-16 code units, .Trim()'s white space (Char.IsWhiteSpace), the regex classes \p{Cc}\p{Cf}\p{Zl}\p{Zp}
// (per UTF-16 unit, so a supplementary character, a surrogate pair, is never Cf), Substring by UTF-16 units, and
// ASCII-only case folding. Header-only, no Windows or UE4SS.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace catalog::text
{
    // Code points of s; a byte that doesn't start a valid UTF-8 sequence becomes U+FFFD (as .NET's decoder does).
    inline std::u32string decode(std::string_view s)
    {
        std::u32string o;
        o.reserve(s.size());
        size_t i = 0;
        while (i < s.size())
        {
            const auto c = static_cast<unsigned char>(s[i]);
            if (c < 0x80)
            {
                o.push_back(c);
                ++i;
                continue;
            }
            int need = 0;
            unsigned char lo = 0x80, hi = 0xBF;
            char32_t cp = 0;
            if (c >= 0xC2 && c <= 0xDF) { need = 1; cp = c & 0x1F; }
            else if (c == 0xE0) { need = 2; lo = 0xA0; cp = c & 0x0F; }
            else if (c == 0xED) { need = 2; hi = 0x9F; cp = c & 0x0F; }
            else if (c >= 0xE1 && c <= 0xEF) { need = 2; cp = c & 0x0F; }
            else if (c == 0xF0) { need = 3; lo = 0x90; cp = c & 0x07; }
            else if (c >= 0xF1 && c <= 0xF3) { need = 3; cp = c & 0x07; }
            else if (c == 0xF4) { need = 3; hi = 0x8F; cp = c & 0x07; }
            bool ok = need > 0 && i + static_cast<size_t>(need) < s.size();
            for (int k = 1; ok && k <= need; ++k)
            {
                const auto ck = static_cast<unsigned char>(s[i + static_cast<size_t>(k)]);
                const unsigned char l = k == 1 ? lo : 0x80, h = k == 1 ? hi : 0xBF;
                if (ck < l || ck > h) ok = false;
                else cp = (cp << 6) | (ck & 0x3F);
            }
            if (!ok)
            {
                o.push_back(0xFFFD);
                ++i;
                continue;
            }
            o.push_back(cp);
            i += static_cast<size_t>(need) + 1;
        }
        return o;
    }

    inline void put(std::string& o, char32_t cp)
    {
        if (cp < 0x80) o.push_back(static_cast<char>(cp));
        else if (cp < 0x800)
        {
            o.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            o.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
        else if (cp < 0x10000)
        {
            o.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            o.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            o.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
        else
        {
            o.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            o.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            o.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            o.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    inline std::string encode(const std::u32string& cps)
    {
        std::string o;
        for (const char32_t c : cps) put(o, c);
        return o;
    }

    // .Length of the .NET string.
    inline size_t utf16_len(std::string_view s)
    {
        size_t n = 0;
        for (const char32_t c : decode(s)) n += c >= 0x10000 ? 2 : 1;
        return n;
    }

    // Char.IsWhiteSpace (what String.Trim() removes).
    inline bool is_space(char32_t c)
    {
        return (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 ||
               c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
    }

    // s.Trim() != s
    inline bool has_outer_space(std::string_view s)
    {
        const auto cps = decode(s);
        return !cps.empty() && (is_space(cps.front()) || is_space(cps.back()));
    }
    inline std::string trim(std::string_view s)
    {
        auto cps = decode(s);
        size_t a = 0, b = cps.size();
        while (a < b && is_space(cps[a])) ++a;
        while (b > a && is_space(cps[b - 1])) --b;
        return encode(cps.substr(a, b - a));
    }

    // Unicode Cf in the BMP (Unicode 15.1, .NET 8/9).
    inline bool is_cf(char32_t c)
    {
        return c == 0xAD || (c >= 0x600 && c <= 0x605) || c == 0x61C || c == 0x6DD || c == 0x70F || c == 0x890 || c == 0x891 || c == 0x8E2 ||
               c == 0x180E || (c >= 0x200B && c <= 0x200F) || (c >= 0x202A && c <= 0x202E) || (c >= 0x2060 && c <= 0x2064) ||
               (c >= 0x2066 && c <= 0x206F) || c == 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB);
    }
    // -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]'
    inline bool has_control(std::string_view s)
    {
        for (const char32_t c : decode(s))
        {
            if (c <= 0x1F || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 || is_cf(c)) return true;
        }
        return false;
    }

    // $s.Substring(0, n) + '...' when $s.Length > n ("<shown>" in messages). A surrogate pair cut in half becomes U+FFFD,
    // as .NET's UTF-8 encoder writes the lone half.
    inline std::string shorten(std::string_view s, size_t n)
    {
        const auto cps = decode(s);
        size_t units = 0;
        for (const char32_t c : cps) units += c >= 0x10000 ? 2 : 1;
        if (units <= n) return std::string{s};
        std::string o;
        size_t used = 0;
        for (const char32_t c : cps)
        {
            const size_t w = c >= 0x10000 ? 2 : 1;
            if (used + w > n)
            {
                if (used < n) put(o, 0xFFFD);
                break;
            }
            put(o, c);
            used += w;
        }
        return o + "...";
    }

    inline char ascii_lower(char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c + 32) : c; }
    inline std::string lower(std::string_view s)
    {
        std::string o{s};
        for (auto& c : o) c = ascii_lower(c);
        return o;
    }
    inline bool iequal(std::string_view a, std::string_view b)
    {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i)
        {
            if (ascii_lower(a[i]) != ascii_lower(b[i])) return false;
        }
        return true;
    }
    inline bool istarts(std::string_view s, std::string_view prefix) { return s.size() >= prefix.size() && iequal(s.substr(0, prefix.size()), prefix); }
    inline bool iends(std::string_view s, std::string_view suffix)
    {
        return s.size() >= suffix.size() && iequal(s.substr(s.size() - suffix.size()), suffix);
    }
    inline bool is_digit(char c) { return c >= '0' && c <= '9'; }
    inline bool is_alnum(char c) { return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
    inline bool is_hex(char c) { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
    inline bool all_hex(std::string_view s, size_t n)
    {
        if (s.size() != n) return false;
        for (const char c : s)
        {
            if (!is_hex(c)) return false;
        }
        return true;
    }

    inline std::string join(const std::vector<std::string>& parts, std::string_view sep)
    {
        std::string o;
        for (size_t i = 0; i < parts.size(); ++i)
        {
            if (i) o += sep;
            o += parts[i];
        }
        return o;
    }
} // namespace catalog::text
