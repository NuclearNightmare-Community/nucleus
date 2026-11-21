// Fetching the catalog and release files (fetch.hpp): verify.ps1's Download, TryBase, CommitCopy and RunFetch, and the
// release-file download, over WinHTTP.
#include "fetch.hpp"

#include <algorithm>
#include <chrono>
#include <mutex>
#include <random>

#include "minisig.hpp"
#include "text.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <winhttp.h>
#ifdef CORE_CATALOG_TEST
#include <wincrypt.h>
#endif

#ifndef WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3
#define WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3 0x00002000
#endif
#ifndef WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
#define WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY 4
#endif

namespace catalog::fetch
{
    using json::Value;

    namespace
    {
        std::string win_error(const char* what, DWORD code)
        {
            std::string msg = std::string{"network error: "} + what + " failed (" + std::to_string(code) + ")";
            wchar_t* buf = nullptr;
            const HMODULE mod = GetModuleHandleW(L"winhttp.dll");
            const DWORD n = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_IGNORE_INSERTS |
                                               (mod ? FORMAT_MESSAGE_FROM_HMODULE : 0) | FORMAT_MESSAGE_FROM_SYSTEM,
                                           mod, code, 0, reinterpret_cast<LPWSTR>(&buf), 0, nullptr);
            if (n > 0 && buf)
            {
                std::string t = text::trim(narrow(std::wstring_view{buf, n}));
                if (!t.empty()) msg += ": " + t;
            }
            if (buf) LocalFree(buf);
            return msg;
        }

        struct Target
        {
            std::wstring host;
            INTERNET_PORT port = 443;
            std::wstring path; // path and query
        };
        bool target_of(const std::string& url, Target& t)
        {
            constexpr std::string_view pre = "https://";
            if (url.compare(0, pre.size(), pre) != 0) return false;
            const std::string rest = url.substr(pre.size());
            const size_t end = rest.find_first_of("/?#");
            std::string auth = rest.substr(0, end);
            std::string path = end == std::string::npos ? "/" : rest.substr(end);
            const size_t hash = path.find('#');
            if (hash != std::string::npos) path.resize(hash);
            if (path.empty() || path[0] == '?') path = "/" + path;
            if (auth.empty() || auth.find('@') != std::string::npos) return false;
            const size_t colon = auth.find(':');
            if (colon != std::string::npos)
            {
                const std::string ps = auth.substr(colon + 1);
                if (ps.empty() || ps.size() > 5 || !std::all_of(ps.begin(), ps.end(), text::is_digit)) return false;
                const int port = std::stoi(ps);
                if (port < 1 || port > 65535) return false;
                t.port = static_cast<INTERNET_PORT>(port);
                auth.resize(colon);
            }
            for (const char c : auth)
            {
                if (!(text::is_alnum(c) || c == '.' || c == '-')) return false;
            }
            for (const char c : path)
            {
                if (static_cast<unsigned char>(c) <= 0x20 || static_cast<unsigned char>(c) >= 0x7F) return false;
            }
            t.host = widen(auth);
            t.path = widen(path);
            return true;
        }

        std::optional<double> retry_seconds(const std::wstring& v)
        {
            const std::string s = text::trim(narrow(v));
            if (s.empty()) return std::nullopt;
            if (std::all_of(s.begin(), s.end(), text::is_digit) && s.size() <= 15) return static_cast<double>(std::stoll(s));
            SYSTEMTIME st{};
            if (WinHttpTimeToSystemTime(v.c_str(), &st))
            {
                FILETIME ft{};
                if (SystemTimeToFileTime(&st, &ft))
                {
                    const int64_t t = ((static_cast<int64_t>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime) + 504911232000000000LL;
                    return static_cast<double>(t - now_ticks()) / 10000000.0;
                }
            }
            return std::nullopt;
        }

        class WinHttp final : public Transport
        {
          public:
            explicit WinHttp(const Options& o)
            {
                const std::wstring ua = widen(o.user_agent);
#ifdef CORE_CATALOG_TEST
                m_pin = text::lower(o.pin_sha256);
                if (!o.proxy.empty())
                {
                    const std::wstring proxy = widen(o.proxy);
                    m_session = WinHttpOpen(ua.c_str(), WINHTTP_ACCESS_TYPE_NAMED_PROXY, proxy.c_str(), WINHTTP_NO_PROXY_BYPASS, 0);
                }
#endif
                if (!m_session) m_session = WinHttpOpen(ua.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
                if (!m_session) m_session = WinHttpOpen(ua.c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
                if (!m_session) return;
                WinHttpSetTimeouts(m_session, 30000, 30000, 30000, 30000);
                DWORD protos = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
                if (!WinHttpSetOption(m_session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protos, sizeof protos))
                {
                    protos = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
                    WinHttpSetOption(m_session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protos, sizeof protos);
                }
                DWORD redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
                WinHttpSetOption(m_session, WINHTTP_OPTION_REDIRECT_POLICY, &redirect, sizeof redirect);
            }
            ~WinHttp() override
            {
                cancel();
                std::lock_guard g{m_mu};
                if (m_session) WinHttpCloseHandle(m_session);
                m_session = nullptr;
            }

            void cancel() override
            {
                std::lock_guard g{m_mu};
                m_cancelled = true;
                // Closing the request handle aborts a call in flight on another thread (WinHTTP documents this).
                if (m_req) WinHttpCloseHandle(m_req);
                if (m_conn) WinHttpCloseHandle(m_conn);
                m_req = nullptr;
                m_conn = nullptr;
            }

            Head get(const std::string& url, const std::function<void(const Head&)>& on_body, const std::function<void(const uint8_t*, size_t)>& on_data,
                     uint32_t total_ms) override
            {
                if (!m_session) unreach(win_error("WinHttpOpen", GetLastError()));
                Target tg;
                if (!target_of(url, tg)) unreach("network error: not a usable https URL: " + url);
                const ULONGLONG start = GetTickCount64();
                HINTERNET conn = WinHttpConnect(m_session, tg.host.c_str(), tg.port, 0);
                if (!conn) unreach(win_error("WinHttpConnect", GetLastError()));
                HINTERNET req = WinHttpOpenRequest(conn, L"GET", tg.path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                                   WINHTTP_FLAG_SECURE | WINHTTP_FLAG_ESCAPE_DISABLE | WINHTTP_FLAG_ESCAPE_DISABLE_QUERY);
                if (!req)
                {
                    const DWORD e = GetLastError();
                    WinHttpCloseHandle(conn);
                    unreach(win_error("WinHttpOpenRequest", e));
                }
                {
                    std::lock_guard g{m_mu};
                    if (m_cancelled)
                    {
                        WinHttpCloseHandle(req);
                        WinHttpCloseHandle(conn);
                        unreach("network error: cancelled");
                    }
                    m_req = req;
                    m_conn = conn;
                }
                struct Close
                {
                    WinHttp* self;
                    HINTERNET req, conn;
                    ~Close()
                    {
                        std::lock_guard g{self->m_mu};
                        if (self->m_req == req)
                        {
                            WinHttpCloseHandle(req);
                            self->m_req = nullptr;
                        }
                        if (self->m_conn == conn)
                        {
                            WinHttpCloseHandle(conn);
                            self->m_conn = nullptr;
                        }
                    }
                } close{this, req, conn};
                auto check = [&](BOOL ok, const char* what) {
                    if (ok) return;
                    const DWORD e = GetLastError();
                    {
                        std::lock_guard g{m_mu};
                        if (m_cancelled) unreach("network error: cancelled");
                    }
                    unreach(win_error(what, e));
                };

                DWORD features = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
                WinHttpSetOption(req, WINHTTP_OPTION_DISABLE_FEATURE, &features, sizeof features);
#ifdef CORE_CATALOG_TEST
                if (!m_pin.empty())
                {
                    DWORD flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID | SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                                  SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
                    WinHttpSetOption(req, WINHTTP_OPTION_SECURITY_FLAGS, &flags, sizeof flags);
                }
#endif
                check(WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0), "WinHttpSendRequest");
                check(WinHttpReceiveResponse(req, nullptr), "WinHttpReceiveResponse");
#ifdef CORE_CATALOG_TEST
                if (!m_pin.empty())
                {
                    PCCERT_CONTEXT cert = nullptr;
                    DWORD len = sizeof cert;
                    std::string got;
                    if (WinHttpQueryOption(req, WINHTTP_OPTION_SERVER_CERT_CONTEXT, &cert, &len) && cert)
                    {
                        sig::Sha256 h;
                        h.update(cert->pbCertEncoded, cert->cbCertEncoded);
                        const auto d = h.finish();
                        got = sig::hex_lower(d.data(), d.size());
                        CertFreeCertificateContext(cert);
                    }
                    if (got != m_pin) unreach("network error: the server certificate is not the pinned one (" + got + ")");
                }
#endif
                Head head;
                DWORD status = 0, len = sizeof status;
                check(WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &len,
                                          WINHTTP_NO_HEADER_INDEX),
                      "WinHttpQueryHeaders");
                head.status = static_cast<int>(status);
                auto header = [&](DWORD which, std::wstring& out) {
                    DWORD size = 0;
                    WinHttpQueryHeaders(req, which, WINHTTP_HEADER_NAME_BY_INDEX, WINHTTP_NO_OUTPUT_BUFFER, &size, WINHTTP_NO_HEADER_INDEX);
                    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || size == 0 || size > 65536) return false;
                    std::wstring buf(size / sizeof(wchar_t) + 1, L'\0');
                    if (!WinHttpQueryHeaders(req, which, WINHTTP_HEADER_NAME_BY_INDEX, buf.data(), &size, WINHTTP_NO_HEADER_INDEX)) return false;
                    buf.resize(size / sizeof(wchar_t));
                    out = buf;
                    return true;
                };
                std::wstring v;
                if (header(WINHTTP_QUERY_LOCATION, v)) head.location = narrow(v);
                if (header(WINHTTP_QUERY_RETRY_AFTER, v)) head.retry_after = retry_seconds(v);
                if (header(WINHTTP_QUERY_CONTENT_LENGTH, v))
                {
                    const std::string s = text::trim(narrow(v));
                    if (!s.empty() && s.size() <= 19 && std::all_of(s.begin(), s.end(), text::is_digit)) head.content_length = std::stoull(s);
                }
                if (head.status < 200 || head.status > 299) return head;
                on_body(head);
                std::vector<uint8_t> buf(64 * 1024);
                while (true)
                {
                    if (GetTickCount64() - start > total_ms) unreach("network error: no complete answer within " + std::to_string(total_ms / 1000) + " s");
                    DWORD got = 0;
                    check(WinHttpReadData(req, buf.data(), static_cast<DWORD>(buf.size()), &got), "WinHttpReadData");
                    if (got == 0) break;
                    on_data(buf.data(), got);
                }
                return head;
            }

          private:
            std::mutex m_mu;
            HINTERNET m_session = nullptr;
            HINTERNET m_req = nullptr;
            HINTERNET m_conn = nullptr;
            bool m_cancelled = false;
#ifdef CORE_CATALOG_TEST
            std::string m_pin;
#endif
        };

        std::string random_hex8()
        {
            std::random_device rd;
            const uint32_t x = rd();
            char buf[9];
            std::snprintf(buf, sizeof buf, "%08x", x);
            return buf;
        }

        // RFC 3986 remove_dot_segments.
        std::string remove_dots(const std::string& in)
        {
            std::string input = in, out;
            while (!input.empty())
            {
                if (input.rfind("../", 0) == 0) input.erase(0, 3);
                else if (input.rfind("./", 0) == 0) input.erase(0, 2);
                else if (input.rfind("/./", 0) == 0) input.replace(0, 3, "/");
                else if (input == "/.") input = "/";
                else if (input.rfind("/../", 0) == 0 || input == "/..")
                {
                    input = input == "/.." ? "/" : input.substr(3);
                    const size_t s = out.rfind('/');
                    out.resize(s == std::string::npos ? 0 : s);
                }
                else if (input == "." || input == "..") input.clear();
                else
                {
                    const size_t start = input[0] == '/' ? 1 : 0;
                    const size_t next = input.find('/', start);
                    out += input.substr(0, next);
                    input = next == std::string::npos ? std::string{} : input.substr(next);
                }
            }
            return out;
        }

        // Escapes what Uri.AbsoluteUri escapes in a path or query: space, ", <, >, \, ^, `, {, |, } and non-ASCII bytes.
        std::string escape_path(const std::string& s)
        {
            std::string o;
            for (const char ch : s)
            {
                const auto c = static_cast<unsigned char>(ch);
                if (c <= 0x20 || c >= 0x7F || std::strchr("\"<>\\^`{|}", ch))
                {
                    char buf[4];
                    std::snprintf(buf, sizeof buf, "%%%02X", c);
                    o += buf;
                }
                else
                {
                    o += ch;
                }
            }
            return o;
        }
    } // namespace

    std::unique_ptr<Transport> make_transport(const Options& o) { return std::make_unique<WinHttp>(o); }

    bool resolve(const std::string& base, const std::string& ref_in, std::string& absolute, std::string& scheme, std::string& host)
    {
        // Split an absolute URL into scheme, authority, path and query (no fragment kept).
        struct Parts
        {
            std::string scheme, auth, path, query;
        };
        auto split = [](const std::string& u, Parts& p) {
            size_t i = 0;
            if (u.empty() || !std::isalpha(static_cast<unsigned char>(u[0]))) return false;
            while (i < u.size() && (std::isalnum(static_cast<unsigned char>(u[i])) || u[i] == '+' || u[i] == '-' || u[i] == '.')) ++i;
            if (i >= u.size() || u[i] != ':' || u.compare(i, 3, "://") != 0) return false;
            p.scheme = text::lower(u.substr(0, i));
            std::string rest = u.substr(i + 3);
            const size_t hash = rest.find('#');
            if (hash != std::string::npos) rest.resize(hash);
            const size_t end = rest.find_first_of("/?");
            p.auth = rest.substr(0, end);
            std::string tail = end == std::string::npos ? std::string{} : rest.substr(end);
            const size_t q = tail.find('?');
            p.path = tail.substr(0, q);
            p.query = q == std::string::npos ? std::string{} : tail.substr(q);
            return true;
        };
        std::string ref = text::trim(ref_in);
        Parts b, r;
        if (!split(base, b)) return false;
        bool has_scheme = false;
        {
            size_t i = 0;
            if (!ref.empty() && std::isalpha(static_cast<unsigned char>(ref[0])))
            {
                while (i < ref.size() && (std::isalnum(static_cast<unsigned char>(ref[i])) || ref[i] == '+' || ref[i] == '-' || ref[i] == '.')) ++i;
                has_scheme = i < ref.size() && ref[i] == ':';
            }
        }
        const size_t hash = ref.find('#');
        if (hash != std::string::npos) ref.resize(hash);
        if (has_scheme)
        {
            if (!split(ref, r)) return false;
        }
        else if (ref.rfind("//", 0) == 0)
        {
            if (!split(b.scheme + ":" + ref, r)) return false;
        }
        else
        {
            r.scheme = b.scheme;
            r.auth = b.auth;
            const size_t q = ref.find('?');
            const std::string rpath = ref.substr(0, q);
            r.query = q == std::string::npos ? std::string{} : ref.substr(q);
            if (rpath.empty())
            {
                r.path = b.path;
                if (q == std::string::npos) r.query = b.query;
            }
            else if (rpath[0] == '/') r.path = rpath;
            else
            {
                const size_t s = b.path.rfind('/');
                r.path = (s == std::string::npos ? std::string{"/"} : b.path.substr(0, s + 1)) + rpath;
            }
        }
        r.path = remove_dots(r.path.empty() ? "/" : r.path);
        if (r.path.empty() || r.path[0] != '/') r.path = "/" + r.path;
        // Authority: [userinfo@]host[:port]; the host a DNS name.
        std::string auth = r.auth;
        std::string userinfo;
        const size_t at = auth.rfind('@');
        if (at != std::string::npos)
        {
            userinfo = auth.substr(0, at + 1);
            auth = auth.substr(at + 1);
        }
        std::string h = auth, port;
        const size_t colon = auth.find(':');
        if (colon != std::string::npos)
        {
            h = auth.substr(0, colon);
            port = auth.substr(colon + 1);
            if (port.size() > 5 || !std::all_of(port.begin(), port.end(), text::is_digit)) return false;
            if (!port.empty() && std::stoi(port) > 65535) return false;
        }
        if (h.empty()) return false;
        for (const char c : h)
        {
            if (!(text::is_alnum(c) || c == '.' || c == '-' || c == '_')) return false;
        }
        h = text::lower(h);
        if ((r.scheme == "https" && port == "443") || (r.scheme == "http" && port == "80")) port.clear();
        scheme = r.scheme;
        host = h;
        absolute = r.scheme + "://" + userinfo + h + (port.empty() ? "" : ":" + std::to_string(std::stoi(port))) + escape_path(r.path) + escape_path(r.query);
        return true;
    }

    // ---------------------------------------------------------------- RunFetch
    namespace
    {
        class Fetch
        {
          public:
            Fetch(Verifier& v, Transport& t, const RunConfig& c) : v(v), t(t), cfg(c) {}

            RunResult run();

          private:
            Verifier& v;
            Transport& t;
            const RunConfig& cfg;
            std::vector<std::string> allowed;

            // Download: $u to $dest, redirects by hand. false for an allowed 404, true when saved.
            bool download(const std::string& u, const fs::path& dest, uint64_t cap, bool allow404)
            {
                std::string cur = u;
                int hops = 0;
                while (true)
                {
                    const std::string hn = host_of(cur);
                    if (auto until = v.backed_off_until(hn)) unreach(hn + " is backed off until " + *until);
                    std::vector<uint8_t> bytes;
                    const Head r = t.get(
                        cur,
                        [&](const Head& h) {
                            if (h.content_length && *h.content_length > cap) unreach("response from " + cur + " is over " + std::to_string(cap) + " bytes");
                        },
                        [&](const uint8_t* p, size_t n) {
                            bytes.insert(bytes.end(), p, p + n);
                            if (bytes.size() > cap) unreach("response from " + cur + " is over " + std::to_string(cap) + " bytes");
                        },
                        30000);
                    const int st = r.status;
                    if (st >= 200 && st <= 299)
                    {
                        if (!write_file(dest, bytes.data(), bytes.size())) throw std::runtime_error("could not write " + shown(dest));
                        return true;
                    }
                    if (st == 301 || st == 302 || st == 303 || st == 307 || st == 308)
                    {
                        if (hops >= k_max_redirects) unreach("more than " + std::to_string(k_max_redirects) + " redirects fetching " + u);
                        if (r.location.empty()) unreach("HTTP " + std::to_string(st) + " without a Location from " + cur);
                        std::string next, scheme, nh;
                        if (!resolve(cur, r.location, next, scheme, nh)) fail("url-not-allowed", "redirect from " + cur + " to an invalid URL: " + r.location);
                        const bool ok_host = std::any_of(allowed.begin(), allowed.end(), [&](const std::string& a) { return text::iequal(a, nh); });
                        if (scheme != "https" || !ok_host)
                        {
                            fail("url-not-allowed", "redirect from " + cur + " to " + next + " is not allowed (https to " + k_redirect_hosts[0] + ", " +
                                                        k_redirect_hosts[1] + ", " + k_redirect_hosts[2] + " or a catalog endpoint only)");
                        }
                        cur = next;
                        ++hops;
                        continue;
                    }
                    if (st == 404 && allow404) return false;
                    if (st == 403 || st == 429)
                    {
                        const std::string until = v.set_backoff(hn, r.retry_after);
                        unreach("HTTP " + std::to_string(st) + " from " + cur + "; " + hn + " backed off until " + until);
                    }
                    unreach("HTTP " + std::to_string(st) + " from " + cur);
                }
            }

            struct Base
            {
                bool restart = false;
                std::optional<KeysResult> keys;
                Value ix;
                std::optional<Value> rv;
            };

            // TryBase: fetches and checks one base into dir.
            Base try_base(const std::string& base, const fs::path& dir, const std::vector<std::string>& in_use, bool can_restart)
            {
                Base res;
                const fs::path kf = dir / L"keys.json";
                if (download(base + "keys.json", kf, k_max_file_bytes, true))
                {
                    (void)download(base + "keys.json.minisig", fs::path{kf} += L".minisig", k_max_sig_bytes, false);
                    res.keys = v.check_keys_file(kf, fs::path{kf} += L".minisig");
                    if (can_restart && res.keys->replaced)
                    {
                        const Value* eps = res.keys->doc.get("endpoints");
                        bool same = eps->items.size() == in_use.size();
                        for (size_t i = 0; same && i < in_use.size(); ++i) same = text::iequal(eps->items[i].s, in_use[i]);
                        if (!same)
                        {
                            res.restart = true;
                            return res;
                        }
                    }
                }
                const fs::path xf = dir / L"index.json";
                const fs::path rf = dir / L"revoked.json";
                (void)download(base + "index.json", xf, k_max_file_bytes, false);
                (void)download(base + "index.json.minisig", fs::path{xf} += L".minisig", k_max_sig_bytes, false);
                const bool rev_optional = !v.state_has("revoked_serial");
                const bool has_rev = download(base + "revoked.json", rf, k_max_file_bytes, rev_optional);
                if (has_rev) (void)download(base + "revoked.json.minisig", fs::path{rf} += L".minisig", k_max_sig_bytes, false);
                res.ix = v.check_index_file(xf, fs::path{xf} += L".minisig");
                if (has_rev) res.rv = v.check_revoked_file(rf, fs::path{rf} += L".minisig");
                return res;
            }

            static bool move_over(const fs::path& from, const fs::path& to)
            {
                return MoveFileExW(from.c_str(), to.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
            }

            // CommitCopy: files present in from replace the copy; files absent are removed.
            void commit_copy(const fs::path& from)
            {
                for (const char* n : k_catalog_files)
                {
                    const fs::path src = from / widen(n);
                    const fs::path dst = cfg.out_dir / widen(n);
                    if (is_file(src))
                    {
                        if (!move_over(src, dst)) throw std::runtime_error("could not move " + shown(src) + " to " + shown(dst));
                    }
                    else if (path_exists(dst))
                    {
                        DeleteFileW(dst.c_str());
                    }
                }
            }
        };

        RunResult Fetch::run()
        {
            v.defer = true;
            (void)v.read_state();
            const bool url_mode = !cfg.url.empty();
            int restarts = 0;
            std::optional<Reject> first_reject;
            while (true)
            {
                std::vector<std::string> in_use;
                if (url_mode) in_use = {cfg.url};
                else if (v.state_has("endpoints"))
                {
                    for (const auto& e : v.read_state()->get("endpoints")->items) in_use.push_back(e.s);
                }
                else in_use = {k_builtin_primary};
                // Each base once; the fallback always last, even when the list names it earlier.
                std::vector<std::string> cands;
                std::vector<std::string> seen;
                auto add_seen = [&](const std::string& b) {
                    for (const auto& s : seen)
                    {
                        if (text::iequal(s, b)) return false;
                    }
                    seen.push_back(b);
                    return true;
                };
                if (!url_mode) add_seen(k_builtin_fallback);
                for (const auto& b : in_use)
                {
                    if (add_seen(b)) cands.push_back(b);
                }
                if (!url_mode) cands.push_back(k_builtin_fallback);
                allowed.assign(std::begin(k_redirect_hosts), std::end(k_redirect_hosts));
                for (const auto& c : cands) allowed.push_back(host_of(c));
                bool restart = false;
                for (const auto& base : cands)
                {
                    if (auto until = v.backed_off_until(host_of(base)))
                    {
                        v.note("endpoint: " + base + " skipped (backoff until " + *until + ")");
                        continue;
                    }
                    const size_t mark = v.details.size();
                    auto snap_state = v.clone_state();
                    auto snap_trust = v.trusted;
                    const fs::path dir = cfg.out_dir / widen(".fetch-" + random_hex8());
                    std::error_code ec;
                    fs::create_directories(dir, ec);
                    struct Cleanup
                    {
                        fs::path d;
                        ~Cleanup()
                        {
                            std::error_code e;
                            fs::remove_all(d, e);
                        }
                    } cleanup{dir};
                    auto rollback = [&] {
                        v.restore_state(snap_state);
                        v.trusted = snap_trust;
                        v.details.resize(mark);
                    };
                    try
                    {
                        if (ec) throw std::runtime_error("could not create " + shown(dir));
                        Base r = try_base(base, dir, in_use, restarts < k_max_restarts && !url_mode);
                        if (r.restart)
                        {
                            v.details.insert(v.details.begin() + static_cast<std::ptrdiff_t>(mark),
                                             "endpoint: " + base + " ok (keys.json serial " + std::to_string(r.keys->doc.get("serial")->i) + " moves the endpoints)");
                            // The copy keeps the keys.json whose serial the state now holds.
                            for (const char* n : {"keys.json", "keys.json.minisig"})
                            {
                                if (!move_over(dir / widen(n), cfg.out_dir / widen(n))) throw std::runtime_error(std::string{"could not move "} + n);
                            }
                            v.flush_state();
                            std::vector<std::string> eps;
                            for (const auto& e : r.keys->doc.get("endpoints")->items) eps.push_back(e.s);
                            v.note("endpoints: saved " + text::join(eps, ", ") + "; restarting the fetch order");
                            ++restarts;
                            restart = true;
                            break;
                        }
                        v.details.insert(v.details.begin() + static_cast<std::ptrdiff_t>(mark), "endpoint: " + base + " ok");
                        commit_copy(dir);
                        v.flush_state();
                        return {std::move(r.keys), std::move(r.ix), std::move(r.rv), base};
                    }
                    catch (const Reject& e)
                    {
                        rollback();
                        // A usage or environment problem is not the endpoint's fault: stop here.
                        if (e.code == "error")
                        {
                            if (v.backoff_changed) v.flush_state();
                            throw;
                        }
                        v.note("endpoint: " + base + " rejected (" + e.code + "): " + e.message);
                        if (!first_reject) first_reject = Reject{e.code, "endpoint " + base + ": " + e.message};
                    }
                    catch (const Unreachable& e)
                    {
                        rollback();
                        v.note("endpoint: " + base + " unreachable: " + e.message);
                    }
                    catch (const std::exception& e)
                    {
                        rollback();
                        v.note("endpoint: " + base + " unreachable: " + std::string{e.what()});
                    }
                }
                if (!restart) break;
            }

            if (v.backoff_changed) v.flush_state();
            if (first_reject) throw *first_reject;
            if (url_mode) fail("error", "endpoint " + cfg.url + " is unreachable (-Url has no fallback)");
            const fs::path xf = cfg.out_dir / L"index.json";
            if (!is_file(xf)) fail("error", "no endpoint reachable and no verified copy in " + shown(cfg.out_dir));

            // Only unreachable or skipped bases: verify the last verified copy instead.
            v.note("fetch: no endpoint reachable; using the verified copy in " + shown(cfg.out_dir));
            v.defer = false;
            const fs::path kf = cfg.out_dir / L"keys.json";
            const fs::path rf = cfg.out_dir / L"revoked.json";
            const bool has_rev = is_file(rf);
            if (!has_rev && v.state_has("revoked_serial"))
            {
                fail("error", "the verified copy in " + shown(cfg.out_dir) + " has no revoked.json, but a revoked list was accepted before");
            }
            RunResult out;
            if (is_file(kf)) out.keys = v.check_keys_file(kf, fs::path{kf} += L".minisig");
            out.ix = v.check_index_file(xf, fs::path{xf} += L".minisig");
            if (has_rev) out.rv = v.check_revoked_file(rf, fs::path{rf} += L".minisig");
            return out;
        }
    } // namespace

    RunResult run_fetch(Verifier& v, Transport& t, const RunConfig& cfg)
    {
        Fetch f{v, t, cfg};
        return f.run();
    }

    // ---------------------------------------------------------------- one release file
    std::optional<Plan> plan_download(const Value& ix, const Value* rv, const std::string& id, const std::string& version, const fs::path& downloads,
                                      std::string& reason)
    {
        const Value* entry = find_version(ix, id, version);
        if (!entry)
        {
            reason = "not in the catalog";
            return std::nullopt;
        }
        Plan p;
        p.id = id;
        p.version = version;
        p.url = entry->get("url")->s;
        p.sha256 = text::lower(entry->get("sha256")->s);
        p.size = static_cast<uint64_t>(entry->get("size")->i);
        if (rv)
        {
            if (const Value* hit = find_revoked(*rv, id, version, p.sha256))
            {
                p.revoked = "package " + id + " " + version + " is revoked (" + hit->get("action")->s + "): " + hit->get("reason")->s;
                return p;
            }
        }
        if (p.size > k_max_release_bytes)
        {
            reason = "too large";
            return std::nullopt;
        }
        // The folder cap: what is there already (but the file itself, which a download replaces) plus this file.
        uint64_t used = 0;
        std::error_code ec;
        const fs::path final_file = downloads / widen(p.sha256 + ".zip");
        for (fs::directory_iterator it{downloads, ec}, end; !ec && it != end; it.increment(ec))
        {
            std::error_code e2;
            // A .part-* file is an interrupted download's leftover, which run_download removes: it doesn't count.
            if (!it->is_regular_file(e2) || it->path() == final_file || it->path().filename().wstring().rfind(L".part-", 0) == 0) continue;
            used += it->file_size(e2);
        }
        if (used + p.size > k_max_download_folder)
        {
            reason = "downloads folder full";
            return std::nullopt;
        }
        return p;
    }

    namespace
    {
        enum class Hashed
        {
            Ok,
            Unreadable,
            Cancelled,
            NoSha
        };
        // Size and SHA-256 of a file on disk, streamed. Only Ok means the whole file was read and hashed.
        Hashed hash_file(const fs::path& f, uint64_t& size, std::string& sha_lower, const std::atomic<bool>& cancel)
        {
            HANDLE h = CreateFileW(f.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h == INVALID_HANDLE_VALUE) return Hashed::Unreadable;
            bool cancelled = false;
            sig::Sha256 sha;
            std::vector<uint8_t> buf(1u << 16);
            size = 0;
            bool ok = true;
            while (ok)
            {
                if (cancel.load())
                {
                    cancelled = true;
                    ok = false;
                }
                DWORD got = 0;
                if (!ok || !ReadFile(h, buf.data(), static_cast<DWORD>(buf.size()), &got, nullptr))
                {
                    ok = false;
                    break;
                }
                if (got == 0) break;
                sha.update(buf.data(), got);
                size += got;
            }
            CloseHandle(h);
            const auto d = sha.finish();
            if (cancelled) return Hashed::Cancelled;
            if (!ok) return Hashed::Unreadable;
            if (!sha.ok()) return Hashed::NoSha;
            sha_lower = sig::hex_lower(d.data(), d.size());
            return Hashed::Ok;
        }
    } // namespace

    fs::path run_download(Verifier& v, Transport& t, const Plan& plan, const fs::path& downloads, const std::atomic<bool>& cancel)
    {
        std::error_code ec;
        fs::create_directories(downloads, ec);
        if (ec) fail("error", "the downloads folder could not be created: " + shown(downloads));
        // Leftovers of an interrupted download (ours, by name) go first.
        for (fs::directory_iterator it{downloads, ec}, end; !ec && it != end; it.increment(ec))
        {
            if (it->path().filename().wstring().rfind(L".part-", 0) == 0)
            {
                std::error_code e2;
                fs::remove(it->path(), e2);
            }
        }
        const fs::path final_file = downloads / widen(plan.sha256 + ".zip");
        if (is_file(final_file))
        {
            uint64_t size = 0;
            std::string sha;
            const Hashed h = hash_file(final_file, size, sha, cancel);
            // Deleted only when it was read whole and differs; a cancel or a missing hash keeps it.
            if (h == Hashed::Cancelled) unreach("network error: cancelled");
            if (h == Hashed::NoSha) fail("error", "unexpected failure: SHA-256 is unavailable");
            if (h == Hashed::Unreadable) fail("error", "the downloaded file could not be read: " + shown(final_file));
            if (size == plan.size && sha == plan.sha256)
            {
                v.note("download: " + plan.id + " " + plan.version + " already downloaded");
                return final_file;
            }
            DeleteFileW(final_file.c_str());
        }

        const fs::path part = downloads / widen(".part-" + random_hex8());
        struct Remove
        {
            fs::path p;
            bool keep = false;
            ~Remove()
            {
                if (!keep) DeleteFileW(p.c_str());
            }
        } remove{part};
        HANDLE out = CreateFileW(part.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (out == INVALID_HANDLE_VALUE) fail("error", "the download could not be written: " + shown(part));
        struct CloseFile
        {
            HANDLE h;
            ~CloseFile()
            {
                if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
            }
        } close_out{out};

        const std::string too_big = "package " + plan.id + " " + plan.version + " is more than " + std::to_string(plan.size) + " bytes; the index says " +
                                    std::to_string(plan.size);
        std::vector<std::string> allowed(std::begin(k_redirect_hosts), std::end(k_redirect_hosts));
        std::string cur = plan.url;
        int hops = 0;
        uint64_t total = 0;
        sig::Sha256 sha;
        while (true)
        {
            if (cancel.load()) unreach("network error: cancelled");
            const std::string hn = host_of(cur);
            if (auto until = v.backed_off_until(hn)) unreach(hn + " is backed off until " + *until);
            // Long enough for 256 MiB on a slow line; each read still times out after 30 s.
            const Head r = t.get(
                cur,
                [&](const Head& h) {
                    if (h.content_length && *h.content_length > plan.size) fail("size-mismatch", too_big);
                },
                [&](const uint8_t* p, size_t n) {
                    if (total + n > plan.size) fail("size-mismatch", too_big);
                    DWORD put = 0;
                    if (!WriteFile(out, p, static_cast<DWORD>(n), &put, nullptr) || put != n) fail("error", "the download could not be written: " + shown(part));
                    sha.update(p, n);
                    total += n;
                    if (cancel.load()) unreach("network error: cancelled");
                },
                30u * 60u * 1000u);
            const int st = r.status;
            if (st >= 200 && st <= 299) break;
            if (st == 301 || st == 302 || st == 303 || st == 307 || st == 308)
            {
                if (hops >= k_max_redirects) unreach("more than " + std::to_string(k_max_redirects) + " redirects fetching " + plan.url);
                if (r.location.empty()) unreach("HTTP " + std::to_string(st) + " without a Location from " + cur);
                std::string next, scheme, nh;
                if (!resolve(cur, r.location, next, scheme, nh)) fail("url-not-allowed", "redirect from " + cur + " to an invalid URL: " + r.location);
                const bool ok_host = std::any_of(allowed.begin(), allowed.end(), [&](const std::string& a) { return text::iequal(a, nh); });
                if (scheme != "https" || !ok_host)
                {
                    fail("url-not-allowed", "redirect from " + cur + " to " + next + " is not allowed (https to " + k_redirect_hosts[0] + ", " +
                                                k_redirect_hosts[1] + " or " + k_redirect_hosts[2] + " only)");
                }
                cur = next;
                ++hops;
                continue;
            }
            if (st == 403 || st == 429)
            {
                const std::string until = v.set_backoff(hn, r.retry_after);
                unreach("HTTP " + std::to_string(st) + " from " + cur + "; " + hn + " backed off until " + until);
            }
            unreach("HTTP " + std::to_string(st) + " from " + cur);
        }
        if (!FlushFileBuffers(out)) fail("error", "the download could not be written: " + shown(part));
        CloseHandle(out);
        close_out.h = INVALID_HANDLE_VALUE;
        if (total != plan.size)
        {
            fail("size-mismatch", "package " + plan.id + " " + plan.version + " is " + std::to_string(total) + " bytes; the index says " + std::to_string(plan.size));
        }
        const auto d = sha.finish();
        if (!sha.ok()) fail("error", "unexpected failure: SHA-256 is unavailable");
        const std::string got = sig::hex_lower(d.data(), d.size());
        if (got != plan.sha256)
        {
            fail("hash-mismatch", "package " + plan.id + " " + plan.version + " has SHA-256 " + got + "; the index says " + plan.sha256);
        }
        if (!MoveFileExW(part.c_str(), final_file.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        {
            fail("error", "the download could not be moved to " + shown(final_file));
        }
        remove.keep = true;
        v.note("package: " + plan.id + " " + plan.version + " matches size " + std::to_string(total) + " and SHA-256");
        return final_file;
    }

    fs::path download_with_state(Verifier& v, Transport& t, const Plan& plan, const fs::path& downloads, const fs::path& state_file, const std::atomic<bool>& cancel)
    {
        // The state file only for back-off; a state that can't be read is left alone (not used, never written).
        v.state_file = state_file;
        if (!v.state_file.empty())
        {
            try
            {
                (void)v.read_state();
            }
            catch (const Reject&)
            {
                v.state_file.clear();
            }
        }
        try
        {
            return run_download(v, t, plan, downloads, cancel);
        }
        catch (...)
        {
            if (v.backoff_changed && v.has_state_file()) v.flush_state();
            throw;
        }
    }

    std::string download_payload(const Plan& plan, const fs::path* file)
    {
        std::string p = "{\"id\":" + json::quote(plan.id) + ",\"version\":" + json::quote(plan.version);
        if (file) p += ",\"sha256\":" + json::quote(plan.sha256) + ",\"size\":" + std::to_string(plan.size) + ",\"file\":" + json::quote(shown(*file));
        return p + "}";
    }
} // namespace catalog::fetch
