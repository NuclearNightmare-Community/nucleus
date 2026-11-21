// Fetching the signed catalog and release files (Mod Manager v2 story 2): verify.ps1's fetch mode (Download, TryBase,
// CommitCopy, RunFetch) over a WinHTTP transport, and the download of one release file named by the verified index.
//
// Transport: HTTPS only (TLS 1.2+), 30 s timeouts, redirects never followed by WinHTTP (Download follows them by hand,
// only to allowed hosts), no cookies, no authentication, user agent "<Core>/<version>". The shipped DLL uses the
// system proxy and Windows' own certificate checks. The test build (CORE_CATALOG_TEST) can name a proxy and pin the
// server certificate's SHA-256 instead (the local HTTPS fixture server); the DLL never compiles that code.
// cancel() closes the request in flight (WinHTTP aborts it) and refuses every later request: core's destructor uses it
// before joining the worker.
#pragma once

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>

#include "json.hpp"
#include "verify.hpp"

namespace catalog::fetch
{
    struct Head
    {
        int status = 0;
        std::string location;
        std::optional<double> retry_after; // seconds
        std::optional<uint64_t> content_length;
    };

    class Transport
    {
      public:
        virtual ~Transport() = default;
        // One GET of url without following redirects. For a 2xx, on_body(head) runs first (it may throw), then on_data
        // per chunk (it may throw to stop). Throws Unreachable on any network error, a timeout (total_ms for the whole
        // request) or after cancel().
        virtual Head get(const std::string& url, const std::function<void(const Head&)>& on_body, const std::function<void(const uint8_t*, size_t)>& on_data,
                         uint32_t total_ms) = 0;
        virtual void cancel() = 0;
    };

    struct Options
    {
        std::string user_agent;
#ifdef CORE_CATALOG_TEST
        std::string proxy;      // "127.0.0.1:<port>": a named proxy instead of the system's
        std::string pin_sha256; // the server certificate's SHA-256 (hex) instead of Windows' chain checks
#endif
    };
    std::unique_ptr<Transport> make_transport(const Options& o);

    // new Uri(base, ref).AbsoluteUri for an http(s) URL; false when the result isn't a usable URL.
    bool resolve(const std::string& base, const std::string& ref, std::string& absolute, std::string& scheme, std::string& host);

    // ---------------------------------------------------------------- the catalog (RunFetch)
    struct RunConfig
    {
        fs::path out_dir;  // the last verified copy (and the attempts' temporary folders)
        std::string url;   // -Url mode: only this base, no fallback, no restart
    };
    struct RunResult
    {
        std::optional<KeysResult> keys;
        json::Value ix;
        std::optional<json::Value> rv;
        std::string from; // the base the files came from; empty: the verified copy
    };
    RunResult run_fetch(Verifier& v, Transport& t, const RunConfig& cfg);

    // ---------------------------------------------------------------- one release file
    constexpr uint64_t k_max_release_bytes = 256ull * 1024 * 1024;  // per file
    constexpr uint64_t k_max_download_folder = 512ull * 1024 * 1024; // the downloads folder in all

    struct Plan
    {
        std::string id, version, url, sha256; // sha256 in lower case
        uint64_t size = 0;
        std::string revoked; // set: "package <id> <version> is revoked (<action>): <reason>"; nothing may be fetched
    };
    // What to download for (id, version) from the verified index (and revoked list). nullopt with a reason when it is
    // refused before anything is fetched: "not in the catalog", "too large", "downloads folder full".
    std::optional<Plan> plan_download(const json::Value& ix, const json::Value* rv, const std::string& id, const std::string& version,
                                      const fs::path& downloads, std::string& reason);
    // Fetches the plan's file into downloads/<sha256>.zip: read to at most size + 1 bytes into a temporary file, kept
    // only when its size and SHA-256 equal the index's. Throws Reject (size-mismatch, hash-mismatch, url-not-allowed,
    // error) or Unreachable; the temporary file is always removed. Returns the file.
    fs::path run_download(Verifier& v, Transport& t, const Plan& plan, const fs::path& downloads, const std::atomic<bool>& cancel);
} // namespace catalog::fetch
