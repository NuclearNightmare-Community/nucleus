// The catalog's file checks (verify.hpp), a port of tools/release/verify.ps1. Function names in comments are
// verify.ps1's; messages are its messages, character for character.
#include "verify.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "minisig.hpp"
#include "text.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

namespace catalog
{
    using json::Value;

    void fail(std::string code, std::string message) { throw Reject{std::move(code), std::move(message)}; }
    void unreach(std::string message) { throw Unreachable{std::move(message)}; }

    // Trusted public keys, the only trust roots: verify.ps1's $BuiltInKeys (tools/release/KEYS.md).
    const BuiltInKey k_builtin_keys[3] = {
        {"release", "release-2026", "RWTMW3t2NIgJibv9elTEM/p2j9B2DrKzVoduupfCeEsSP0bWFXT5M8B3"},
        {"backup", "backup-2026", "RWQcDPnLk/l0BKY4ofTxhZvyEPjSOLs7llh1qJjaXY53fKaWT3yIuuxP"},
        {"revoke", "revoke-2026", "RWTUp/4U9P3jFC1b+ZSruRd583xJKN107RdGsdGO1wIBrBMRqxkuR5uX"},
    };
    // $BuiltInPrimary, $BuiltInFallback, $RedirectHosts
    const char* const k_builtin_primary = "https://nuclearnightmare-community.github.io/catalog/";
    const char* const k_builtin_fallback = "https://github.com/NuclearNightmare-Community/catalog/releases/download/catalog/";
    const char* const k_redirect_hosts[3] = {"github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"};
    const char* const k_catalog_files[6] = {"keys.json", "keys.json.minisig", "index.json", "index.json.minisig", "revoked.json", "revoked.json.minisig"};

    namespace
    {
        const char* const k_kinds[] = {"base", "installer", "mod"};
        const char* const k_actions[] = {"disable", "block"};
        const char* const k_scopes[] = {"client", "host", "host-plus", "both"};
        const char* const k_categories[] = {"gameplay", "content", "visuals", "audio", "ui", "qol", "tools", "library", "performance",
                                            "multiplayer", "localization", "overhaul", "bug-fixes", "maps"};
        const char* const k_forbidden_hosts[] = {"api.github.com", "raw.githubusercontent.com"};
        constexpr int64_t k_screenshot_max = 6;
        constexpr int64_t k_caption_max = 80;
        constexpr int64_t k_ticks_per_day = 864000000000LL;

        template <size_t N>
        bool in_list(const char* const (&list)[N], std::string_view s)
        {
            for (const char* x : list)
            {
                if (s == x) return true;
            }
            return false;
        }
        template <size_t N>
        std::string list_text(const char* const (&list)[N])
        {
            std::string o;
            for (size_t i = 0; i < N; ++i)
            {
                if (i) o += ", ";
                o += list[i];
            }
            return o;
        }

        bool is_str(const Value* v) { return v && v->type == Value::Type::String; }
        bool is_int(const Value* v) { return v && v->type == Value::Type::Int; }
        // Has: a JSON object with a member of exactly this name.
        bool has(const Value* o, std::string_view k) { return o && o->is_obj() && o->has(k); }
        const Value* member(const Value* o, std::string_view k) { return o ? o->get(k) : nullptr; }
        std::string str_of(const Value* v) { return ps_string(v); }

        // Get-Content -Raw | ConvertFrom-Json. nullopt when the text isn't JSON; an empty or blank text is JSON null
        // (ConvertFrom-Json returns nothing for it).
        std::optional<Value> parse_json(const std::vector<uint8_t>& bytes)
        {
            std::string_view t{reinterpret_cast<const char*>(bytes.data()), bytes.size()};
            if (t.size() >= 3 && static_cast<unsigned char>(t[0]) == 0xEF && static_cast<unsigned char>(t[1]) == 0xBB && static_cast<unsigned char>(t[2]) == 0xBF)
            {
                t.remove_prefix(3);
            }
            bool blank = true;
            for (const char c : t)
            {
                if (c != ' ' && c != '\t' && c != '\r' && c != '\n') blank = false;
            }
            if (blank) return Value::null();
            Value v;
            std::string err;
            if (!json::parse(t, v, err, 64)) return std::nullopt;
            return v;
        }

        // [regex]::Match($u, $UrlRx): https://github.com/(<owner>/<name>)/releases/download/(<tag>)/(<file>)
        struct UrlParts
        {
            std::string repo, tag, file;
        };
        std::optional<UrlParts> match_url(std::string_view u)
        {
            constexpr std::string_view pre = "https://github.com/";
            if (u.substr(0, pre.size()) != pre) return std::nullopt;
            size_t p = pre.size();
            const size_t owner_start = p;
            while (p < u.size() && (text::is_alnum(u[p]) || u[p] == '-')) ++p;
            if (p == owner_start || p >= u.size() || u[p] != '/') return std::nullopt;
            ++p;
            const size_t name_start = p;
            while (p < u.size() && (text::is_alnum(u[p]) || u[p] == '.' || u[p] == '_' || u[p] == '-')) ++p;
            if (p == name_start) return std::nullopt;
            UrlParts r;
            r.repo = std::string{u.substr(owner_start, p - owner_start)};
            constexpr std::string_view mid = "/releases/download/";
            if (u.substr(p, mid.size()) != mid) return std::nullopt;
            p += mid.size();
            const size_t tag_start = p;
            while (p < u.size() && u[p] != '/' && u[p] != '?' && u[p] != '#') ++p;
            if (p == tag_start || p >= u.size() || u[p] != '/') return std::nullopt;
            r.tag = std::string{u.substr(tag_start, p - tag_start)};
            ++p;
            const size_t file_start = p;
            while (p < u.size() && (text::is_alnum(u[p]) || u[p] == '.' || u[p] == '_' || u[p] == '+' || u[p] == '-')) ++p;
            if (p == file_start || p != u.size()) return std::nullopt;
            r.file = std::string{u.substr(file_start)};
            return r;
        }

        // $RepoRx: ^[A-Za-z0-9-]+/(?!\.\.?\z)[A-Za-z0-9._-]+\z
        bool is_repo(std::string_view s)
        {
            size_t p = 0;
            while (p < s.size() && (text::is_alnum(s[p]) || s[p] == '-')) ++p;
            if (p == 0 || p >= s.size() || s[p] != '/') return false;
            const std::string_view name = s.substr(p + 1);
            if (name.empty() || name == "." || name == "..") return false;
            for (const char c : name)
            {
                if (!(text::is_alnum(c) || c == '.' || c == '_' || c == '-')) return false;
            }
            return true;
        }

        int64_t floor_div(int64_t a, int64_t b)
        {
            int64_t q = a / b;
            if ((a % b != 0) && ((a < 0) != (b < 0))) --q;
            return q;
        }
        // Days from 0001-01-01 (proleptic Gregorian).
        int64_t days_from_civil(int64_t y, int64_t m, int64_t d)
        {
            y -= m <= 2;
            const int64_t era = floor_div(y, 400);
            const int64_t yoe = y - era * 400;
            const int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
            const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            return era * 146097 + doe - 719468 + 719162; // 1970-01-01 is day 719162
        }
        void civil_from_days(int64_t z, int64_t& y, int64_t& m, int64_t& d)
        {
            z -= 719162;
            z += 719468;
            const int64_t era = floor_div(z, 146097);
            const int64_t doe = z - era * 146097;
            const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            y = yoe + era * 400;
            const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            const int64_t mp = (5 * doy + 2) / 153;
            d = doy - (153 * mp + 2) / 5 + 1;
            m = mp + (mp < 10 ? 3 : -9);
            y += m <= 2;
        }
        bool leap(int64_t y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }
    } // namespace

    // ---------------------------------------------------------------- files
    std::wstring widen(std::string_view s)
    {
        if (s.empty()) return {};
        const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
        std::wstring w(static_cast<size_t>(n > 0 ? n : 0), L'\0');
        if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
        return w;
    }
    std::string narrow(std::wstring_view w)
    {
        if (w.empty()) return {};
        const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
        std::string s(static_cast<size_t>(n > 0 ? n : 0), '\0');
        if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
        return s;
    }
    std::string shown(const fs::path& p) { return narrow(p.native()); }
    fs::path full_path(std::string_view utf8)
    {
        const std::wstring w = widen(utf8);
        const DWORD need = GetFullPathNameW(w.c_str(), 0, nullptr, nullptr);
        if (need == 0) return fs::path{w};
        std::wstring out(need, L'\0');
        const DWORD n = GetFullPathNameW(w.c_str(), need, out.data(), nullptr);
        if (n == 0 || n >= need) return fs::path{w};
        out.resize(n);
        return fs::path{out};
    }
    bool is_file(const fs::path& p)
    {
        if (p.empty()) return false;
        const DWORD a = GetFileAttributesW(p.c_str());
        return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0;
    }
    bool path_exists(const fs::path& p) { return !p.empty() && GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES; }
    bool read_file(const fs::path& p, uint64_t cap, std::vector<uint8_t>& out, bool* too_big)
    {
        if (too_big) *too_big = false;
        out.clear();
        HANDLE h = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE) return false;
        LARGE_INTEGER size{};
        bool ok = GetFileSizeEx(h, &size) != 0;
        if (ok && static_cast<uint64_t>(size.QuadPart) > cap)
        {
            if (too_big) *too_big = true;
            ok = false;
        }
        if (ok)
        {
            out.resize(static_cast<size_t>(size.QuadPart));
            size_t done = 0;
            while (ok && done < out.size())
            {
                DWORD got = 0;
                const DWORD want = static_cast<DWORD>(std::min<size_t>(out.size() - done, 1u << 20));
                if (!ReadFile(h, out.data() + done, want, &got, nullptr) || got == 0) ok = false;
                done += got;
            }
            // Never more than cap, even when the file grew after the size check.
            char extra;
            DWORD got = 0;
            if (ok && ReadFile(h, &extra, 1, &got, nullptr) && got != 0)
            {
                if (too_big) *too_big = true;
                ok = false;
            }
        }
        CloseHandle(h);
        if (!ok) out.clear();
        return ok;
    }
    bool write_file(const fs::path& p, const void* data, size_t n)
    {
        HANDLE h = CreateFileW(p.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE) return false;
        bool ok = true;
        const auto* b = static_cast<const uint8_t*>(data);
        size_t done = 0;
        while (ok && done < n)
        {
            DWORD put = 0;
            const DWORD want = static_cast<DWORD>(std::min<size_t>(n - done, 1u << 20));
            if (!WriteFile(h, b + done, want, &put, nullptr) || put == 0) ok = false;
            done += put;
        }
        if (!CloseHandle(h)) ok = false;
        return ok;
    }

    // ---------------------------------------------------------------- time
    int64_t now_ticks()
    {
        FILETIME ft{};
        GetSystemTimeAsFileTime(&ft);
        const int64_t t = (static_cast<int64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        return t + 504911232000000000LL; // 1601-01-01 in .NET ticks
    }
    bool parse_iso(std::string_view s, int64_t* ticks)
    {
        // $IsoUtc: ^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z\z, then [datetime]::TryParse.
        auto digits = [&](size_t at, size_t n, int64_t& v) {
            if (at + n > s.size()) return false;
            v = 0;
            for (size_t i = at; i < at + n; ++i)
            {
                if (!text::is_digit(s[i])) return false;
                v = v * 10 + (s[i] - '0');
            }
            return true;
        };
        int64_t y, mo, d, h, mi, se;
        if (s.size() < 20 || !digits(0, 4, y) || s[4] != '-' || !digits(5, 2, mo) || s[7] != '-' || !digits(8, 2, d) || s[10] != 'T' ||
            !digits(11, 2, h) || s[13] != ':' || !digits(14, 2, mi) || s[16] != ':' || !digits(17, 2, se))
        {
            return false;
        }
        size_t p = 19;
        int64_t frac = 0;
        if (s[p] == '.')
        {
            ++p;
            size_t n = 0;
            while (p < s.size() && text::is_digit(s[p]) && n < 8)
            {
                frac = frac * 10 + (s[p] - '0');
                ++p;
                ++n;
            }
            if (n < 1 || n > 7) return false;
            for (; n < 7; ++n) frac *= 10;
        }
        if (p + 1 != s.size() || s[p] != 'Z') return false;
        static const int dim[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
        if (y < 1 || mo < 1 || mo > 12 || d < 1 || h > 23 || mi > 59 || se > 59) return false;
        if (d > dim[mo - 1] + ((mo == 2 && leap(y)) ? 1 : 0)) return false;
        if (ticks) *ticks = days_from_civil(y, mo, d) * k_ticks_per_day + ((h * 60 + mi) * 60 + se) * 10000000LL + frac;
        return true;
    }
    bool parse_iso(const Value* v, int64_t* ticks) { return is_str(v) && parse_iso(v->s, ticks); }
    std::string iso(int64_t ticks)
    {
        const int64_t days = floor_div(ticks, k_ticks_per_day);
        int64_t rem = ticks - days * k_ticks_per_day;
        int64_t y, m, d;
        civil_from_days(days, y, m, d);
        const int64_t secs = rem / 10000000LL;
        char buf[32];
        std::snprintf(buf, sizeof buf, "%04lld-%02lld-%02lldT%02lld:%02lld:%02lldZ", static_cast<long long>(y), static_cast<long long>(m),
                      static_cast<long long>(d), static_cast<long long>(secs / 3600), static_cast<long long>((secs / 60) % 60),
                      static_cast<long long>(secs % 60));
        return buf;
    }
    std::string age_of(std::string_view iso_text)
    {
        int64_t t = 0;
        parse_iso(iso_text, &t);
        const int64_t days = floor_div(now_ticks() - t, k_ticks_per_day);
        if (days < 0) return "in the future";
        if (days == 1) return "1 day ago";
        return std::to_string(days) + " days ago";
    }

    // ---------------------------------------------------------------- small rules
    bool is_semver(std::string_view s)
    {
        // $SemverRx: ^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\z
        size_t p = 0;
        for (int part = 0; part < 3; ++part)
        {
            if (p >= s.size() || !text::is_digit(s[p])) return false;
            if (s[p] == '0') ++p;
            else
            {
                while (p < s.size() && text::is_digit(s[p])) ++p;
            }
            if (part < 2)
            {
                if (p >= s.size() || s[p] != '.') return false;
                ++p;
            }
        }
        auto ident = [&](char lead) {
            if (p >= s.size() || s[p] != lead) return true;
            ++p;
            const size_t st = p;
            while (p < s.size() && (text::is_alnum(s[p]) || s[p] == '.' || s[p] == '-')) ++p;
            return p > st;
        };
        if (!ident('-')) return false;
        if (!ident('+')) return false;
        return p == s.size();
    }
    bool is_sha256(std::string_view s) { return text::all_hex(s, 64); }

    std::string ps_string(const Value* v)
    {
        if (!v) return {};
        switch (v->type)
        {
        case Value::Type::Null: return {};
        case Value::Type::Bool: return v->b ? "True" : "False";
        case Value::Type::Int: return std::to_string(v->i);
        case Value::Type::BigInt: return v->s;
        case Value::Type::Float:
        {
            char buf[64];
            const auto r = std::to_chars(buf, buf + sizeof buf, v->f);
            std::string o(buf, r.ptr);
            for (auto& c : o)
            {
                if (c == 'e') c = 'E';
            }
            return o;
        }
        case Value::Type::String: return v->s;
        case Value::Type::Array:
        {
            std::string o;
            for (size_t i = 0; i < v->items.size(); ++i)
            {
                if (i) o += ' ';
                o += v->items[i].is_arr() ? "System.Object[]" : ps_string(&v->items[i]);
            }
            return o;
        }
        case Value::Type::Object:
        {
            std::string o = "@{";
            for (size_t i = 0; i < v->keys.size(); ++i)
            {
                if (i) o += "; ";
                o += v->keys[i] + "=" + (v->vals[i].is_arr() ? "System.Object[]" : ps_string(&v->vals[i]));
            }
            return o + "}";
        }
        }
        return {};
    }

    std::optional<std::string> endpoint_problem(std::string_view u)
    {
        // $EndpointRx: https://<host>[:port]/<path>/ (labels of [A-Za-z0-9-], path segments of [A-Za-z0-9._~%!$&()*+,;=:-]
        // each ending in /), no user info, query or fragment.
        const std::string shown_u{u};
        const std::string bad = "not https://<host>[:port]/<path>/ (ending in /, no user info, query or fragment): " + shown_u;
        constexpr std::string_view pre = "https://";
        if (u.substr(0, pre.size()) != pre) return bad;
        size_t p = pre.size();
        const size_t hs = p;
        while (p < u.size() && (text::is_alnum(u[p]) || u[p] == '-' || u[p] == '.')) ++p;
        const std::string_view host = u.substr(hs, p - hs);
        if (host.empty()) return bad;
        size_t ls = 0;
        while (true)
        {
            size_t le = host.find('.', ls);
            if (le == std::string_view::npos) le = host.size();
            const std::string_view label = host.substr(ls, le - ls);
            if (label.empty() || !text::is_alnum(label.front()) || !text::is_alnum(label.back())) return bad;
            if (le == host.size()) break;
            ls = le + 1;
        }
        std::optional<int64_t> port;
        if (p < u.size() && u[p] == ':')
        {
            ++p;
            const size_t ps = p;
            int64_t v = 0;
            while (p < u.size() && text::is_digit(u[p]) && p - ps < 6)
            {
                v = v * 10 + (u[p] - '0');
                ++p;
            }
            if (p == ps || p - ps > 5) return bad;
            port = v;
        }
        if (p >= u.size() || u[p] != '/') return bad;
        ++p;
        const std::string_view path = u.substr(p);
        size_t ss = 0;
        std::vector<std::string_view> segs;
        while (ss < path.size())
        {
            const size_t se = path.find('/', ss);
            if (se == std::string_view::npos) return bad; // the last segment must end in /
            const std::string_view seg = path.substr(ss, se - ss);
            if (seg.empty()) return bad;
            for (const char c : seg)
            {
                if (!(text::is_alnum(c) || std::strchr("._~%!$&()*+,;=:-", c))) return bad;
            }
            segs.push_back(seg);
            ss = se + 1;
        }
        if (port && (*port < 1 || *port > 65535)) return "port out of range: " + shown_u;
        for (const auto& seg : segs)
        {
            if (seg == "." || seg == "..") return "path has a . or .. segment: " + shown_u;
        }
        if (text::lower(path).find("%2e") != std::string::npos) return "path has a . or .. segment: " + shown_u;
        const std::string hn = text::lower(host);
        for (const char* f : k_forbidden_hosts)
        {
            if (hn == f) return "host " + hn + " is not allowed: " + shown_u;
        }
        return std::nullopt;
    }
    std::optional<std::string> endpoint_problem(const Value* v)
    {
        if (!is_str(v)) return std::string{"not a string"};
        return endpoint_problem(v->s);
    }

    std::string host_of(std::string_view url)
    {
        const size_t sch = url.find("://");
        if (sch == std::string_view::npos) return {};
        std::string_view rest = url.substr(sch + 3);
        const size_t end = rest.find_first_of("/?#");
        std::string_view auth = rest.substr(0, end);
        const size_t at = auth.rfind('@');
        if (at != std::string_view::npos) auth.remove_prefix(at + 1);
        const size_t colon = auth.find(':');
        if (colon != std::string_view::npos) auth = auth.substr(0, colon);
        return text::lower(auth);
    }

    // ---------------------------------------------------------------- the modid block
    namespace modid
    {
        Norm normalize(std::string_view raw)
        {
            const std::string forms = "use <owner>.<mod> or github.com/<owner>.<mod>";
            if (raw.empty()) return {{}, "an id must not be empty"};
            if (text::utf16_len(raw) > 200 || raw.size() > 200) return {{}, "an id must be at most 200 bytes"};
            std::string s = text::lower(raw);
            if (s.rfind("github.com/", 0) == 0) s = s.substr(11);
            if (s.find("://") != std::string::npos || s.rfind("www.", 0) == 0) return {{}, "an id is not a URL; " + forms};
            const size_t slash = s.find('/');
            if (slash != std::string::npos && s.substr(0, slash).find('.') != std::string::npos)
            {
                return {{}, "ids on hosts other than GitHub are not supported yet; " + forms};
            }
            if (s.find('.') == std::string::npos) return {{}, "an id needs a namespace; " + forms};
            // \A[a-z0-9-]+\.[a-z0-9-]+\z
            auto part_ok = [](std::string_view x) {
                if (x.empty()) return false;
                for (const char c : x)
                {
                    if (!((c >= 'a' && c <= 'z') || text::is_digit(c) || c == '-')) return false;
                }
                return true;
            };
            const size_t dot = s.find('.');
            if (!part_ok(std::string_view{s}.substr(0, dot)) || !part_ok(std::string_view{s}.substr(dot + 1)))
            {
                return {{}, "an id must be <owner>.<mod> with only a-z, 0-9 and - in each part; " + forms};
            }
            return {s, {}};
        }
        Norm normalize(const Value* v)
        {
            if (!is_str(v)) return {{}, "an id must be a string"};
            return normalize(v->s);
        }

        std::optional<std::string> display_name_problem(const Value* v)
        {
            if (!is_str(v)) return std::string{"displayName must be a string"};
            const size_t n = text::utf16_len(v->s);
            if (n < 1 || n > 64) return std::string{"displayName must be 1 to 64 characters"};
            for (const char c : v->s)
            {
                if ((static_cast<unsigned char>(c) <= 0x1F) || c == 0x7F) return std::string{"displayName must not contain control characters"};
            }
            if (v->s.front() == ' ' || v->s.back() == ' ') return std::string{"displayName must not start or end with a space"};
            return std::nullopt;
        }

        std::optional<std::string> scope_problem(const Value* v)
        {
            if (is_str(v) && in_list(k_scopes, v->s)) return std::nullopt;
            return "scope: '" + text::shorten(ps_string(v), 40) + "' is not one of " + list_text(k_scopes);
        }

        namespace
        {
            // Test-ModDescription / Test-ModCaption: plain text of 1..max UTF-16 units.
            std::optional<std::string> plain_text(const Value* v, const char* field, size_t max)
            {
                const std::string f{field};
                if (!is_str(v)) return f + ": missing or not a string";
                const size_t n = text::utf16_len(v->s);
                if (n < 1 || n > max) return f + ": must be 1 to " + std::to_string(max) + " characters (has " + std::to_string(n) + ")";
                if (text::has_control(v->s)) return f + ": must not contain control characters";
                if (text::has_outer_space(v->s)) return f + ": must not start or end with a space";
                return std::nullopt;
            }
        } // namespace

        std::optional<std::string> description_problem(const Value* v) { return plain_text(v, "description", 280); }

        std::optional<std::string> categories_problem(const Value* v)
        {
            if (!v || !v->is_arr()) return std::string{"categories: missing or not an array"};
            const size_t n = v->items.size();
            if (n < 1 || n > 3) return "categories: must list 1 to 3 categories (has " + std::to_string(n) + ")";
            std::vector<std::string> seen;
            for (size_t i = 0; i < n; ++i)
            {
                const Value& c = v->items[i];
                const std::string at = "categories[" + std::to_string(i) + "]";
                if (!c.is_str()) return at + ": not a string";
                if (!in_list(k_categories, c.s)) return at + ": '" + text::shorten(c.s, 40) + "' is not one of " + list_text(k_categories) + " (categories.md)";
                for (const auto& s : seen)
                {
                    if (s == c.s) return at + ": '" + c.s + "' is listed more than once";
                }
                seen.push_back(c.s);
            }
            return std::nullopt;
        }

        std::optional<std::string> screenshots_problem(const Value* v)
        {
            if (!v || !v->is_arr()) return std::string{"screenshots: not an array"};
            const size_t n = v->items.size();
            if (static_cast<int64_t>(n) > k_screenshot_max) return "screenshots: must list at most " + std::to_string(k_screenshot_max) + " (has " + std::to_string(n) + ")";
            std::vector<std::string> urls;
            for (size_t i = 0; i < n; ++i)
            {
                const Value& s = v->items[i];
                const std::string at = "screenshots[" + std::to_string(i) + "]";
                if (!s.is_obj()) return at + ": not an object";
                for (const char* f : {"url", "caption", "sha256", "size", "width", "height"})
                {
                    if (!s.has(f)) return at + "." + f + ": missing";
                }
                const Value* url = s.get("url");
                if (!is_str(url) || url->s.empty()) return at + ".url: not a non-empty string";
                if (auto ce = plain_text(s.get("caption"), "caption", static_cast<size_t>(k_caption_max))) return at + "." + *ce;
                const Value* sha = s.get("sha256");
                if (!is_str(sha) || !is_sha256(sha->s)) return at + ".sha256: not 64 hex digits";
                struct Bound
                {
                    const char* f;
                    int64_t lo, hi;
                };
                for (const Bound& b : {Bound{"size", 1, 2097152}, Bound{"width", 320, 3840}, Bound{"height", 180, 2160}})
                {
                    const Value* x = s.get(b.f);
                    if (!is_int(x) || x->i < b.lo || x->i > b.hi)
                    {
                        return at + "." + b.f + ": not an integer from " + std::to_string(b.lo) + " to " + std::to_string(b.hi);
                    }
                }
                const std::string low = text::lower(url->s);
                for (const auto& u : urls)
                {
                    if (u == low) return at + ".url: listed more than once";
                }
                urls.push_back(low);
            }
            return std::nullopt;
        }
    } // namespace modid

    // ---------------------------------------------------------------- trust
    std::optional<std::string> Verifier::next_problem(const Value* nr, bool check_revoke) const
    {
        if (!nr || !nr->is_obj()) return std::string{"next_release: not null or an object {fingerprint, key}"};
        std::optional<std::string> kid;
        if (nr->has("key") && is_str(nr->get("key"))) kid = sig::key_id(nr->get("key")->s);
        if (!kid) return std::string{"next_release.key: missing or not a minisign public key"};
        const Value* fp = nr->get("fingerprint");
        if (!is_str(fp) || !text::all_hex(fp->s, 16)) return std::string{"next_release.fingerprint: missing or not 16 hex digits"};
        if (!text::iequal(fp->s, *kid)) return "next_release.fingerprint: " + fp->s + " is not the key id of next_release.key (" + *kid + ")";
        if (check_revoke)
        {
            for (const auto& t : trusted)
            {
                if (text::iequal(t.id, *kid) && t.role == "revoke")
                {
                    return "next_release.key: is the trusted revoke key '" + t.name + "'; a revoke key cannot be the next release key";
                }
            }
        }
        return std::nullopt;
    }

    void Verifier::set_next_key(const Value* nr)
    {
        std::erase_if(trusted, [](const TrustedKey& t) { return t.next; });
        if (!nr || nr->is_null() || !nr->is_obj()) return;
        const Value* key = nr->get_ci("key");
        if (!is_str(key)) return;
        const auto kid = sig::key_id(key->s);
        if (!kid) return;
        for (const auto& t : trusted)
        {
            if (text::iequal(t.id, *kid)) return;
        }
        trusted.push_back({"release", "next-release", text::trim(key->s), *kid, true});
    }

    void Verifier::trust_builtin()
    {
        trusted.clear();
        for (const auto& k : k_builtin_keys)
        {
            const auto kid = sig::key_id(k.key);
            if (!kid) fail("error", std::string{"trusted key '"} + k.name + "' is not a minisign public key");
            for (const auto& t : trusted)
            {
                if (t.id == *kid) fail("error", "trusted key id " + *kid + " is listed more than once");
            }
            trusted.push_back({k.role, k.name, k.key, *kid, false});
        }
    }

    void Verifier::trust_list(const Value& list)
    {
        trusted.clear();
        std::vector<const Value*> items;
        if (list.is_arr())
        {
            for (const auto& x : list.items) items.push_back(&x);
        }
        else
        {
            items.push_back(&list);
        }
        for (const Value* k : items)
        {
            const Value* role = has(k, "role") ? k->get("role") : nullptr;
            if (!is_str(role) || !(role->s == "release" || role->s == "backup" || role->s == "revoke"))
            {
                fail("error", "trusted key has a bad role: " + ps_string(role));
            }
            std::optional<std::string> kid;
            if (has(k, "key") && is_str(k->get("key"))) kid = sig::key_id(k->get("key")->s);
            const std::string name = ps_string(k->is_obj() ? k->get_ci("name") : nullptr);
            if (!kid) fail("error", "trusted key '" + name + "' is not a minisign public key");
            for (const auto& t : trusted)
            {
                if (t.id == *kid) fail("error", "trusted key id " + *kid + " is listed more than once");
            }
            trusted.push_back({role->s, name, text::trim(k->get("key")->s), *kid, false});
        }
    }

    void Verifier::trust_saved_next()
    {
        if (!has_state_file()) return;
        Value* st = nullptr;
        try
        {
            st = read_state();
        }
        catch (const Reject&)
        {
            st = nullptr;
            m_state_read = false;
            m_state.reset();
            backoff.clear();
        }
        if (st && st->has("next_release") && !st->get("next_release")->is_null()) set_next_key(st->get("next_release"));
    }

    // ---------------------------------------------------------------- state
    Value* Verifier::read_state()
    {
        if (m_state_read || !has_state_file()) return m_state ? &*m_state : nullptr;
        m_state_read = true;
        if (!is_file(state_file)) return nullptr;
        const std::string sf = shown(state_file);
        std::vector<uint8_t> bytes;
        if (!read_file(state_file, 1u << 20, bytes)) fail("error", "state file is not JSON: " + sf);
        const auto parsed = parse_json(bytes);
        if (!parsed) fail("error", "state file is not JSON: " + sf);
        const Value& s = *parsed;
        auto bad_serial = [&](const char* k) { return s.has(k) && (!is_int(s.get(k)) || s.get(k)->i < 0); };
        if (!s.is_obj() || bad_serial("index_serial")) fail("error", "state file has no valid index_serial: " + sf);
        if (bad_serial("revoked_serial")) fail("error", "state file has no valid revoked_serial: " + sf);
        if (bad_serial("keys_serial")) fail("error", "state file has no valid keys_serial: " + sf);
        if (s.has("endpoints"))
        {
            const Value* e = s.get("endpoints");
            bool bad = !e->is_arr() || e->items.empty() || e->items.size() > k_max_endpoints;
            if (!bad)
            {
                for (const auto& x : e->items)
                {
                    if (endpoint_problem(&x)) bad = true;
                }
            }
            if (bad) fail("error", "state file has no valid endpoints: " + sf);
        }
        if (s.has("next_release") && !s.get("next_release")->is_null() && next_problem(s.get("next_release"), false))
        {
            fail("error", "state file has no valid next_release: " + sf);
        }
        if (s.has("backoff"))
        {
            const Value* b = s.get("backoff");
            if (!b->is_obj()) fail("error", "state file has no valid backoff: " + sf);
            for (size_t i = 0; i < b->keys.size(); ++i)
            {
                if (!parse_iso(&b->vals[i])) fail("error", "state file has no valid backoff: " + sf);
                const std::string hn = text::lower(b->keys[i]);
                bool found = false;
                for (auto& [h, until] : backoff)
                {
                    if (h == hn)
                    {
                        until = b->vals[i].s;
                        found = true;
                    }
                }
                if (!found) backoff.emplace_back(hn, b->vals[i].s);
            }
        }
        m_state = s;
        return &*m_state;
    }

    void Verifier::set_state(std::string_view key, Value value)
    {
        Value* s = read_state();
        if (!s)
        {
            m_state = Value::object();
            s = &*m_state;
        }
        s->set(key, std::move(value));
    }

    void Verifier::flush_state()
    {
        if (!has_state_file()) return;
        Value* s = read_state();
        if (!s)
        {
            m_state = Value::object();
            s = &*m_state;
        }
        const int64_t now = now_ticks();
        Value live = Value::object();
        for (const auto& [h, until] : backoff)
        {
            int64_t t = 0;
            if (parse_iso(until, &t) && t > now) live.set(h, Value::string(until));
        }
        if (!live.keys.empty()) s->set("backoff", std::move(live));
        else s->remove("backoff");
        std::error_code ec;
        if (state_file.has_parent_path()) fs::create_directories(state_file.parent_path(), ec);
        const std::string text = json::write(*s, true) + "\r\n";
        // Written beside it and moved over it, so a crash never leaves half a state file.
        fs::path tmp = state_file;
        tmp += L".tmp";
        if (!write_file(tmp, text.data(), text.size()) ||
            !MoveFileExW(tmp.c_str(), state_file.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        {
            DeleteFileW(tmp.c_str());
            fail("error", "state file could not be written: " + shown(state_file));
        }
    }

    void Verifier::write_state(std::string_view key, int64_t value)
    {
        set_state(key, Value::integer(value));
        save_state();
        note("state: " + std::string{key} + " = " + std::to_string(value) + " in " + shown(state_file));
    }

    std::optional<Value> Verifier::clone_state()
    {
        Value* s = read_state();
        if (!s) return std::nullopt;
        return *s;
    }

    bool Verifier::state_has(std::string_view key)
    {
        const Value* s = read_state();
        return s && s->has(key);
    }

    std::string Verifier::set_backoff(const std::string& host, std::optional<double> seconds)
    {
        double secs = seconds.value_or(3600.0);
        if (!(secs >= 60.0)) secs = 60.0; // also NaN
        if (secs > 86400.0) secs = 86400.0;
        const std::string until = iso(now_ticks() + static_cast<int64_t>(secs * 10000000.0));
        int64_t u = 0, have = 0;
        parse_iso(until, &u);
        bool found = false;
        for (auto& [h, t] : backoff)
        {
            if (h == host)
            {
                found = true;
                if (!(parse_iso(t, &have) && have > u)) t = until;
            }
        }
        if (!found) backoff.emplace_back(host, until);
        backoff_changed = true;
        for (const auto& [h, t] : backoff)
        {
            if (h == host) return t;
        }
        return until;
    }

    std::optional<std::string> Verifier::backed_off_until(const std::string& host)
    {
        for (const auto& [h, t] : backoff)
        {
            int64_t u = 0;
            if (h == host && parse_iso(t, &u) && u > now_ticks()) return t;
        }
        return std::nullopt;
    }

    // ---------------------------------------------------------------- signatures
    TrustedKey Verifier::check_signature(const fs::path& file, const fs::path& sig_file, std::initializer_list<const char*> roles, const std::string& what,
                                         std::vector<uint8_t>& message)
    {
        const std::string pre = what == "index" ? "" : what + " ";
        if (!is_file(sig_file)) fail("bad-signature", pre + "signature file not found: " + shown(sig_file));
        // A real .minisig is a few hundred bytes; don't read an oversized one.
        std::vector<uint8_t> sig_bytes;
        bool too_big = false;
        if (!read_file(sig_file, k_max_sig_bytes, sig_bytes, &too_big) || too_big) fail("bad-signature", pre + "signature file is malformed");
        const auto parsed = sig::parse_sig(sig_bytes);
        if (parsed.malformed) fail("bad-signature", pre + "signature file is malformed");
        const std::string& sig_id = parsed.key_id;
        std::vector<const TrustedKey*> matched, signers;
        for (const auto& t : trusted)
        {
            if (text::iequal(t.id, sig_id)) matched.push_back(&t);
        }
        for (const auto* t : matched)
        {
            for (const char* r : roles)
            {
                if (t->role == r)
                {
                    signers.push_back(t);
                    break;
                }
            }
        }
        if (signers.empty())
        {
            if (what == "index")
            {
                if (!matched.empty()) fail("unknown-key", "signed by revoke key '" + matched[0]->name + "'; the revoke key cannot sign an index");
                fail("unknown-key", "signed by key id " + sig_id + ", which is not a trusted release or backup key");
            }
            if (what == "keys.json")
            {
                if (!matched.empty()) fail("unknown-key", "keys.json signed by revoke key '" + matched[0]->name + "'; a revoke key cannot sign keys.json");
                fail("unknown-key", "keys.json signed by key id " + sig_id + ", which is not a trusted release or backup key or the accepted next release key");
            }
            if (!matched.empty())
            {
                fail("unknown-key", what + " signed by " + matched[0]->role + " key '" + matched[0]->name + "'; a " + matched[0]->role +
                                        " key cannot sign a revoked list");
            }
            fail("unknown-key", what + " signed by key id " + sig_id + ", which is not a trusted revoke key");
        }

        // The file itself, read once: these bytes are verified and then parsed.
        bool read_ok = read_file(file, k_max_file_bytes, message);
        const TrustedKey* signer = nullptr;
        for (const auto* s : signers)
        {
            const auto pk = sig::public_key(s->key);
            if (read_ok && pk && sig::verify(sig_bytes, message.data(), message.size(), *pk))
            {
                signer = s;
                break;
            }
        }
        if (!signer)
        {
            if (what == "keys.json") fail("bad-signature", "signature does not verify against keys.json");
            fail("bad-signature", "signature does not verify against the " + what);
        }
        const std::string for_ = what == "index" ? "" : what == "keys.json" ? " for keys.json" : " for the " + what;
        note("signer: " + signer->role + " key '" + signer->name + "' (" + sig_id + ")" + for_);
        return *signer;
    }

    // ---------------------------------------------------------------- keys.json
    KeysResult Verifier::check_keys_file(const fs::path& file, const fs::path& sig_path)
    {
        std::vector<uint8_t> bytes;
        (void)check_signature(file, sig_path, {"release", "backup"}, "keys.json", bytes);

        const std::string bad = "keys.json field";
        const auto parsed = parse_json(bytes);
        if (!parsed)
        {
            note("age: keys.json unknown (not JSON)");
            fail("invalid-index", "keys.json is not valid JSON");
        }
        const Value& kj = *parsed;
        if (!kj.is_obj())
        {
            note("age: keys.json unknown (not a JSON object)");
            fail("invalid-index", "keys.json is not a JSON object");
        }
        if (kj.has("issued") && parse_iso(kj.get("issued"))) note("age: keys.json issued " + kj.get("issued")->s + " (" + age_of(kj.get("issued")->s) + ")");
        else note("age: keys.json unknown (issued is missing or invalid)");

        const Value* schema = kj.get("schema");
        if (!is_int(schema) || schema->i < 1) fail("invalid-index", bad + " schema: missing or not a positive integer");
        if (schema->i > k_supported_schema)
        {
            fail("schema-too-new", "keys.json schema " + std::to_string(schema->i) + " is newer than " + std::to_string(k_supported_schema) + "; update the manager");
        }
        const Value* serial = kj.get("serial");
        if (!is_int(serial) || serial->i < 0) fail("invalid-index", bad + " serial: missing or not a non-negative integer");
        if (!parse_iso(kj.get("issued"))) fail("invalid-index", bad + " issued: missing or not an ISO-8601 UTC time (yyyy-MM-ddTHH:mm:ss[.fffffff]Z)");
        if (!kj.has("next_release")) fail("invalid-index", bad + " next_release: missing (null or {fingerprint, key})");
        const Value* nr = kj.get("next_release");
        if (!nr->is_null())
        {
            if (auto problem = next_problem(nr, true)) fail("invalid-index", bad + " " + *problem);
        }
        const Value* eps = kj.get("endpoints");
        if (!eps || !eps->is_arr()) fail("invalid-index", bad + " endpoints: missing or not an array");
        if (eps->items.empty() || eps->items.size() > k_max_endpoints)
        {
            fail("invalid-index", bad + " endpoints: " + std::to_string(eps->items.size()) + " entries; 1 to " + std::to_string(k_max_endpoints) + " allowed");
        }
        for (size_t i = 0; i < eps->items.size(); ++i)
        {
            if (auto problem = endpoint_problem(&eps->items[i])) fail("invalid-index", bad + " endpoints[" + std::to_string(i) + "]: " + *problem);
        }

        const Value* state = read_state();
        bool replaced = true;
        if (state && state->has("keys_serial"))
        {
            const int64_t have = state->get("keys_serial")->i;
            if (serial->i < have)
            {
                fail("serial-rollback", "keys.json serial " + std::to_string(serial->i) + " is lower than the last accepted serial " + std::to_string(have));
            }
            if (serial->i == have) replaced = false;
        }
        Value next = Value::null();
        if (!nr->is_null())
        {
            next = Value::object();
            next.set("fingerprint", Value::string(*sig::key_id(nr->get("key")->s)));
            next.set("key", Value::string(text::trim(nr->get("key")->s)));
        }
        std::vector<std::string> ep_list;
        for (const auto& e : eps->items) ep_list.push_back(e.s);
        note("endpoints: " + text::join(ep_list, ", "));
        note("next-release: " + (next.is_null() ? std::string{"none"} : next.get("fingerprint")->s));
        if (replaced)
        {
            set_state("keys_serial", Value::integer(serial->i));
            Value arr = Value::array();
            for (const auto& e : ep_list) arr.items.push_back(Value::string(e));
            set_state("endpoints", std::move(arr));
            set_state("next_release", next);
            save_state();
            set_next_key(&next);
            if (has_state_file()) note("state: keys_serial = " + std::to_string(serial->i) + " in " + shown(state_file) + " (endpoints and next release saved)");
        }
        else if (has_state_file())
        {
            note("state: keys_serial = " + std::to_string(serial->i) + " unchanged in " + shown(state_file) + " (saved endpoints and next release kept)");
        }
        last_keys_text.assign(bytes.begin(), bytes.end());
        return {kj, replaced};
    }

    // ---------------------------------------------------------------- index.json, steps 1-5
    Value Verifier::check_index_file(const fs::path& file, const fs::path& sig_path)
    {
        // --- 1-2. signature file, key id, minisign verify
        std::vector<uint8_t> bytes;
        (void)check_signature(file, sig_path, {"release", "backup"}, "index", bytes);

        // --- 3. JSON, schema, fields
        const auto parsed = parse_json(bytes);
        if (!parsed)
        {
            note("age: unknown (index is not JSON)");
            fail("invalid-index", "index is not valid JSON");
        }
        const Value& ix = *parsed;
        if (!ix.is_obj())
        {
            note("age: unknown (index is not a JSON object)");
            fail("invalid-index", "index is not a JSON object");
        }
        if (ix.has("issued") && parse_iso(ix.get("issued"))) note("age: index issued " + ix.get("issued")->s + " (" + age_of(ix.get("issued")->s) + ")");
        else note("age: unknown (issued is missing or invalid)");

        const Value* schema = ix.get("schema");
        if (!is_int(schema) || schema->i < 1) fail("invalid-index", "field schema: missing or not a positive integer");
        if (schema->i > k_supported_index_schema)
        {
            fail("schema-too-new", "index schema " + std::to_string(schema->i) + " is newer than " + std::to_string(k_supported_index_schema) + "; update the manager");
        }
        const Value* serial = ix.get("serial");
        if (!is_int(serial) || serial->i < 0) fail("invalid-index", "field serial: missing or not a non-negative integer");
        if (!parse_iso(ix.get("issued"))) fail("invalid-index", "field issued: missing or not an ISO-8601 UTC time (yyyy-MM-ddTHH:mm:ss[.fffffff]Z)");
        const Value* packages = ix.get("packages");
        if (!packages || !packages->is_arr()) fail("invalid-index", "field packages: missing or not an array");
        std::vector<std::string> ids;
        for (size_t i = 0; i < packages->items.size(); ++i)
        {
            const Value& p = packages->items[i];
            std::string at = "packages[" + std::to_string(i) + "]";
            if (!p.is_obj()) fail("invalid-index", "field " + at + ": not an object");
            for (const char* f : {"id", "name", "kind", "publisher", "repo"})
            {
                const Value* x = p.get(f);
                if (!is_str(x) || x->s.empty()) fail("invalid-index", "field " + at + "." + f + ": missing or not a non-empty string");
            }
            const auto nid = modid::normalize(p.get("id"));
            if (!nid.error.empty()) fail("invalid-index", "field " + at + ".id: " + nid.error);
            at = "packages[" + p.get("id")->s + "]";
            for (const auto& have : ids)
            {
                if (have == nid.id) fail("invalid-index", "field " + at + ": duplicate package id (ids compare after normalizing: " + nid.id + ")");
            }
            ids.push_back(nid.id);
            if (p.has("displayName"))
            {
                if (auto dn = modid::display_name_problem(p.get("displayName"))) fail("invalid-index", "field " + at + ".displayName: " + *dn);
            }
            const std::string& kind = p.get("kind")->s;
            if (!in_list(k_kinds, kind)) fail("invalid-index", "field " + at + ".kind: '" + kind + "' is not one of " + list_text(k_kinds));
            // Schema 2: a kind mod package needs both; any package that has one must have it valid.
            const bool needs = kind == "mod" && schema->i >= 2;
            if (needs || p.has("description"))
            {
                if (auto de = modid::description_problem(p.get_ci("description"))) fail("invalid-index", "field " + at + "." + *de);
            }
            if (needs || p.has("categories"))
            {
                if (auto ca = modid::categories_problem(p.get_ci("categories"))) fail("invalid-index", "field " + at + "." + *ca);
            }
            if (!is_repo(p.get("repo")->s)) fail("invalid-index", "field " + at + ".repo: not <owner>/<name> (name not . or ..)");
            const Value* versions = p.get("versions");
            if (!versions || !versions->is_arr()) fail("invalid-index", "field " + at + ".versions: missing or not an array");
            std::vector<std::string> seen;
            for (size_t j = 0; j < versions->items.size(); ++j)
            {
                const Value& v = versions->items[j];
                std::string vat = at + ".versions[" + std::to_string(j) + "]";
                if (!v.is_obj()) fail("invalid-index", "field " + vat + ": not an object");
                const Value* ver = v.get("version");
                if (!is_str(ver) || !is_semver(ver->s)) fail("invalid-index", "field " + vat + ".version: missing or not semver");
                vat = at + ".versions[" + ver->s + "]";
                for (const auto& s : seen)
                {
                    if (s == ver->s) fail("invalid-index", "field " + vat + ": duplicate version");
                }
                seen.push_back(ver->s);
                if (!is_str(v.get("url"))) fail("invalid-index", "field " + vat + ".url: missing or not a string");
                const Value* sha = v.get("sha256");
                if (!is_str(sha) || !is_sha256(sha->s)) fail("invalid-index", "field " + vat + ".sha256: missing or not 64 hex digits");
                const Value* size = v.get("size");
                if (!is_int(size) || size->i < 0) fail("invalid-index", "field " + vat + ".size: missing or not a non-negative integer");
                if (kind == "mod")
                {
                    if (auto sc = modid::scope_problem(v.get_ci("scope"))) fail("invalid-index", "field " + vat + "." + *sc);
                }
                for (const char* f : {"published", "installable_after"})
                {
                    if (v.has(f) && !parse_iso(v.get(f))) fail("invalid-index", "field " + vat + "." + f + ": not an ISO-8601 UTC time");
                }
                // Screenshots (any kind, any schema): checked whenever present; their urls in step 5.
                if (v.has("screenshots"))
                {
                    if (auto ss = modid::screenshots_problem(v.get("screenshots"))) fail("invalid-index", "field " + vat + "." + *ss);
                }
            }
        }

        // --- 4. serial (rollback guard)
        if (has_state_file())
        {
            const Value* state = read_state();
            if (state && state->has("index_serial") && serial->i < state->get("index_serial")->i)
            {
                fail("serial-rollback", "index serial " + std::to_string(serial->i) + " is lower than the last accepted serial " +
                                            std::to_string(state->get("index_serial")->i));
            }
        }

        // --- 5. URLs
        for (const auto& p : packages->items)
        {
            const std::string& repo = p.get("repo")->s;
            for (const auto& v : p.get("versions")->items)
            {
                const std::string& version = v.get("version")->s;
                const std::string where = "package " + p.get("id")->s + " version " + version;
                const std::string& url = v.get("url")->s;
                auto m = match_url(url);
                if (!m) fail("url-not-allowed", where + ": url is not https://github.com/<repo>/releases/download/v<version>/<file>: " + url);
                if (m->repo != repo) fail("url-not-allowed", where + ": url repo " + m->repo + " is not the package repo " + repo);
                if (m->tag != "v" + version) fail("url-not-allowed", where + ": url tag " + m->tag + " is not v" + version);
                if (m->file == "." || m->file == "..") fail("url-not-allowed", where + ": url has no file name");
                if (const Value* shots = v.get("screenshots"))
                {
                    for (size_t k = 0; k < shots->items.size(); ++k)
                    {
                        const std::string sat = where + " screenshots[" + std::to_string(k) + "]";
                        const std::string& su = shots->items[k].get("url")->s;
                        m = match_url(su);
                        if (!m) fail("url-not-allowed", sat + ": url is not https://github.com/<repo>/releases/download/v<version>/<file>: " + su);
                        if (m->repo != repo) fail("url-not-allowed", sat + ": url repo " + m->repo + " is not the package repo " + repo);
                        if (m->tag != "v" + version) fail("url-not-allowed", sat + ": url tag " + m->tag + " is not v" + version);
                        if (!(text::iends(m->file, ".png") || text::iends(m->file, ".jpg") || text::iends(m->file, ".jpeg")))
                        {
                            fail("url-not-allowed", sat + ": url file " + m->file + " is not a .png, .jpg or .jpeg");
                        }
                    }
                }
            }
        }

        // The index passed: remember its serial (rollback guard for the next run).
        if (has_state_file()) write_state("index_serial", serial->i);
        last_index_text.assign(bytes.begin(), bytes.end());
        return ix;
    }

    const Value* find_version(const Value& ix, const std::string& id, const std::string& version)
    {
        const Value* packages = ix.get("packages");
        if (!packages || !packages->is_arr()) return nullptr;
        for (const auto& p : packages->items)
        {
            if (modid::normalize(p.get("id")).id != id || id.empty()) continue;
            const Value* versions = p.get_ci("versions");
            if (!versions || !versions->is_arr()) continue;
            for (const auto& v : versions->items)
            {
                const Value* ver = v.get_ci("version");
                if (is_str(ver) && ver->s == version) return &v;
            }
        }
        return nullptr;
    }

    const Value* find_revoked(const Value& rv, const std::string& id, const std::string& version, const std::string& sha)
    {
        const Value* list = rv.get("revoked");
        if (!list || !list->is_arr()) return nullptr;
        for (const auto& r : list->items)
        {
            if (modid::normalize(r.get("id")).id == id && !id.empty() && is_str(r.get("version")) && r.get("version")->s == version &&
                is_str(r.get("sha256")) && text::iequal(r.get("sha256")->s, sha))
            {
                return &r;
            }
        }
        return nullptr;
    }

    const Value* find_revoked_installed(const Value& ix, const Value& rv, const std::string& id, const std::string& version)
    {
        const Value* list = rv.get("revoked");
        if (!list || !list->is_arr() || id.empty()) return nullptr;
        const Value* entry = find_version(ix, id, version);
        const Value* esha = entry ? entry->get_ci("sha256") : nullptr;
        for (const auto& r : list->items)
        {
            if (modid::normalize(r.get("id")).id != id || !is_str(r.get("version")) || r.get("version")->s != version) continue;
            if (!entry) return &r;
            if (is_str(r.get("sha256")) && is_str(esha) && text::iequal(r.get("sha256")->s, esha->s)) return &r;
        }
        return nullptr;
    }

    // ---------------------------------------------------------------- 6. package against the index entry
    std::string Verifier::check_package_file(const Value& ix, const fs::path& package, const std::string& id, const std::string& version)
    {
        const Value* entry = find_version(ix, id, version);
        if (!entry) fail("error", "package " + id + " version " + version + " is not listed in the index");
        HANDLE h = CreateFileW(package.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE) fail("error", "unexpected failure: package could not be read: " + shown(package));
        LARGE_INTEGER size{};
        GetFileSizeEx(h, &size);
        const int64_t want = entry->get("size")->i;
        if (size.QuadPart != want)
        {
            CloseHandle(h);
            fail("size-mismatch", "package " + id + " " + version + " is " + std::to_string(size.QuadPart) + " bytes; the index says " + std::to_string(want));
        }
        sig::Sha256 sha;
        std::vector<uint8_t> buf(1u << 16);
        while (true)
        {
            DWORD got = 0;
            if (!ReadFile(h, buf.data(), static_cast<DWORD>(buf.size()), &got, nullptr))
            {
                CloseHandle(h);
                fail("error", "unexpected failure: package could not be read: " + shown(package));
            }
            if (got == 0) break;
            sha.update(buf.data(), got);
        }
        CloseHandle(h);
        const auto digest = sha.finish();
        if (!sha.ok()) fail("error", "unexpected failure: SHA-256 is unavailable");
        const std::string hash = sig::hex_upper(digest.data(), digest.size());
        const std::string& want_sha = entry->get("sha256")->s;
        if (!text::iequal(hash, want_sha))
        {
            fail("hash-mismatch", "package " + id + " " + version + " has SHA-256 " + text::lower(hash) + "; the index says " + text::lower(want_sha));
        }
        note("package: " + id + " " + version + " matches size " + std::to_string(size.QuadPart) + " and SHA-256");
        return hash;
    }

    // ---------------------------------------------------------------- revoked.json, steps 7-9
    Value Verifier::check_revoked_file(const fs::path& file, const fs::path& sig_path)
    {
        // --- 7. revoked list: signature (revoke key only)
        std::vector<uint8_t> bytes;
        (void)check_signature(file, sig_path, {"revoke"}, "revoked list", bytes);

        // --- 8. JSON, schema, fields
        const std::string bad = "revoked.json field";
        const auto parsed = parse_json(bytes);
        if (!parsed)
        {
            note("age: revoked list unknown (not JSON)");
            fail("invalid-index", "revoked.json is not valid JSON");
        }
        const Value& rv = *parsed;
        if (!rv.is_obj())
        {
            note("age: revoked list unknown (not a JSON object)");
            fail("invalid-index", "revoked.json is not a JSON object");
        }
        if (rv.has("issued") && parse_iso(rv.get("issued"))) note("age: revoked list issued " + rv.get("issued")->s + " (" + age_of(rv.get("issued")->s) + ")");
        else note("age: revoked list unknown (issued is missing or invalid)");

        const Value* schema = rv.get("schema");
        if (!is_int(schema) || schema->i < 1) fail("invalid-index", bad + " schema: missing or not a positive integer");
        if (schema->i > k_supported_schema)
        {
            fail("schema-too-new", "revoked.json schema " + std::to_string(schema->i) + " is newer than " + std::to_string(k_supported_schema) + "; update the manager");
        }
        const Value* serial = rv.get("serial");
        if (!is_int(serial) || serial->i < 0) fail("invalid-index", bad + " serial: missing or not a non-negative integer");
        if (!parse_iso(rv.get("issued"))) fail("invalid-index", bad + " issued: missing or not an ISO-8601 UTC time (yyyy-MM-ddTHH:mm:ss[.fffffff]Z)");
        const Value* list = rv.get("revoked");
        if (!list || !list->is_arr()) fail("invalid-index", bad + " revoked: missing or not an array");
        for (size_t i = 0; i < list->items.size(); ++i)
        {
            const Value& r = list->items[i];
            const std::string at = "revoked[" + std::to_string(i) + "]";
            if (!r.is_obj()) fail("invalid-index", bad + " " + at + ": not an object");
            for (const char* f : {"id", "version", "sha256", "reason", "action"})
            {
                if (!is_str(r.get(f))) fail("invalid-index", bad + " " + at + "." + f + ": missing or not a string");
            }
            const auto nid = modid::normalize(r.get("id"));
            if (!nid.error.empty()) fail("invalid-index", bad + " " + at + ".id: " + nid.error);
            if (!is_semver(r.get("version")->s)) fail("invalid-index", bad + " " + at + ".version: not semver");
            if (!is_sha256(r.get("sha256")->s)) fail("invalid-index", bad + " " + at + ".sha256: not 64 hex digits");
            const std::string& reason = r.get("reason")->s;
            if (reason.empty() || text::has_control(reason)) fail("invalid-index", bad + " " + at + ".reason: empty or has control characters");
            const std::string& action = r.get("action")->s;
            if (!in_list(k_actions, action)) fail("invalid-index", bad + " " + at + ".action: '" + action + "' is not one of " + list_text(k_actions));
        }

        // --- 9. serial (rollback guard)
        if (has_state_file())
        {
            const Value* state = read_state();
            if (state && state->has("revoked_serial") && serial->i < state->get("revoked_serial")->i)
            {
                fail("serial-rollback", "revoked list serial " + std::to_string(serial->i) + " is lower than the last accepted serial " +
                                            std::to_string(state->get("revoked_serial")->i));
            }
            write_state("revoked_serial", serial->i);
        }
        for (const auto& r : list->items)
        {
            note("revoked: " + r.get("id")->s + " " + r.get("version")->s + " " + r.get("action")->s + ": " + r.get("reason")->s);
        }
        last_revoked_text.assign(bytes.begin(), bytes.end());
        return rv;
    }

    // ---------------------------------------------------------------- 10. is the package revoked?
    void Verifier::check_revoked_match(const Value& rv, const std::string& id, const std::string& version, const std::string& sha)
    {
        if (const Value* hit = find_revoked(rv, id, version, sha))
        {
            fail("revoked", "package " + id + " " + version + " is revoked (" + hit->get("action")->s + "): " + hit->get("reason")->s);
        }
    }
} // namespace catalog
