// The signed catalog's file checks, ported from tools/release/verify.ps1 (Mod Manager v2 story 2): trust roots, the
// mod id normalizer and the index field rules (its "# BEGIN modid" block), keys.json / index.json / revoked.json checks
// with their outcome codes, messages and detail lines, and the state file (same JSON keys as verify.ps1's: index_serial,
// revoked_serial, keys_serial, endpoints, next_release, backoff).
//
// Same rules, order, outcome codes and messages as verify.ps1; where PowerShell is lenient and this port is strict
// (JSON, UTF-8, \d as ASCII digits) the port refuses. Errors are thrown as Reject (a trust decision or a usage/
// environment problem, code "error") or Unreachable (fetching only). Windows file APIs, no UE4SS: core's DLL
// (catalog.cpp) and the test exe (catalog_cli.cpp) both build it. Not thread-safe: one Verifier per job.
#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "json.hpp"

namespace catalog
{
    namespace fs = std::filesystem;

    struct Reject
    {
        std::string code;
        std::string message;
    };
    struct Unreachable
    {
        std::string message;
    };
    [[noreturn]] void fail(std::string code, std::string message);
    [[noreturn]] void unreach(std::string message);

    // ---------------------------------------------------------------- constants (verify.ps1's, compiled in)
    struct BuiltInKey
    {
        const char* role;
        const char* name;
        const char* key;
    };
    extern const BuiltInKey k_builtin_keys[3];
    extern const char* const k_builtin_primary;
    extern const char* const k_builtin_fallback;
    extern const char* const k_redirect_hosts[3];
    constexpr int64_t k_supported_schema = 1;
    constexpr int64_t k_supported_index_schema = 2;
    constexpr size_t k_max_endpoints = 8;
    constexpr uint64_t k_max_file_bytes = 4ull * 1024 * 1024;
    constexpr uint64_t k_max_sig_bytes = 4096;
    constexpr int k_max_redirects = 5;
    constexpr int k_max_restarts = 2;
    extern const char* const k_catalog_files[6];

    // ---------------------------------------------------------------- files and paths
    std::wstring widen(std::string_view utf8);
    std::string narrow(std::wstring_view w);
    std::string shown(const fs::path& p); // a path as messages print it (UTF-8)
    fs::path full_path(std::string_view utf8); // FullPath: absolute, normalized, not resolved
    bool is_file(const fs::path& p);
    bool path_exists(const fs::path& p);
    // Reads at most cap bytes; false (and too_big set) when the file is larger, false on any I/O error.
    bool read_file(const fs::path& p, uint64_t cap, std::vector<uint8_t>& out, bool* too_big = nullptr);
    bool write_file(const fs::path& p, const void* data, size_t n);

    // ---------------------------------------------------------------- time (100 ns ticks since 0001-01-01 UTC, as .NET)
    int64_t now_ticks();
    // verify.ps1's IsIso: yyyy-MM-ddTHH:mm:ss[.f{1,7}]Z and a real date and time.
    bool parse_iso(const json::Value* v, int64_t* ticks = nullptr);
    bool parse_iso(std::string_view s, int64_t* ticks = nullptr);
    std::string iso(int64_t ticks); // yyyy-MM-ddTHH:mm:ssZ
    std::string age_of(std::string_view iso_text);

    // ---------------------------------------------------------------- the modid block
    namespace modid
    {
        struct Norm
        {
            std::string id;    // when accepted
            std::string error; // when refused
        };
        Norm normalize(const json::Value* v); // ConvertTo-ModId
        Norm normalize(std::string_view s);
        std::optional<std::string> display_name_problem(const json::Value* v);
        std::optional<std::string> scope_problem(const json::Value* v);
        std::optional<std::string> description_problem(const json::Value* v);
        std::optional<std::string> categories_problem(const json::Value* v);
        std::optional<std::string> screenshots_problem(const json::Value* v);
    } // namespace modid

    bool is_semver(std::string_view s);
    bool is_sha256(std::string_view s);
    // [string]$x as PowerShell prints a JSON value in a message.
    std::string ps_string(const json::Value* v);

    // EndpointProblem: nullopt when v is an allowed catalog base URL, else why not.
    std::optional<std::string> endpoint_problem(const json::Value* v);
    std::optional<std::string> endpoint_problem(std::string_view u);
    // ([Uri]$u).Host.ToLowerInvariant() for an https URL ("" when it has none).
    std::string host_of(std::string_view url);

    // ---------------------------------------------------------------- the verifier
    struct TrustedKey
    {
        std::string role; // release | backup | revoke
        std::string name;
        std::string key; // base64, trimmed
        std::string id;  // 16 upper-case hex digits
        bool next = false;
    };

    struct KeysResult
    {
        json::Value doc;
        bool replaced = false;
    };

    class Verifier
    {
      public:
        // Detail lines, printed after "outcome:" and "message:".
        std::vector<std::string> details;
        void note(std::string line) { details.push_back(std::move(line)); }

        // -StateFile (empty: state lives in memory for this run only).
        fs::path state_file;
        bool has_state_file() const { return !state_file.empty(); }

        std::vector<TrustedKey> trusted;
        // The built-in keys, or a -TrustedKeys list (test exe only). Throws Reject "error" for a bad list.
        void trust_builtin();
        void trust_list(const json::Value& list);
        // At start (verify.ps1's main): the next release key saved in the state file, if it can be read now.
        void trust_saved_next();

        // State (ReadState and friends). read_state() returns nullptr while there is none; throws Reject "error" for
        // a state file that isn't valid.
        json::Value* read_state();
        void set_state(std::string_view key, json::Value value);
        void flush_state();
        void save_state() { if (!defer) flush_state(); }
        void write_state(std::string_view key, int64_t value);
        std::optional<json::Value> clone_state();
        void restore_state(std::optional<json::Value> s) { m_state = std::move(s); }
        bool state_has(std::string_view key);

        // Backoff (fetching): host -> ISO time, kept apart from the state so a discarded attempt keeps it.
        std::vector<std::pair<std::string, std::string>> backoff;
        bool backoff_changed = false;
        std::string set_backoff(const std::string& host, std::optional<double> seconds);
        std::optional<std::string> backed_off_until(const std::string& host);

        // Fetch mode holds state writes back until an endpoint's files pass.
        bool defer = false;

        // The file checks. Each reads its file (at most 4 MiB) once, checks the signature over those bytes and then
        // parses the same bytes. The verified text is kept in last_*_text.
        KeysResult check_keys_file(const fs::path& file, const fs::path& sig);
        json::Value check_index_file(const fs::path& file, const fs::path& sig);
        json::Value check_revoked_file(const fs::path& file, const fs::path& sig);
        // Step 6: the package file against the index entry; returns its SHA-256 in upper case.
        std::string check_package_file(const json::Value& ix, const fs::path& package, const std::string& id, const std::string& version);
        // Step 10.
        void check_revoked_match(const json::Value& rv, const std::string& id, const std::string& version, const std::string& sha);

        std::string last_keys_text, last_index_text, last_revoked_text;

        // NextProblem / SetNextKey
        std::optional<std::string> next_problem(const json::Value* nr, bool check_revoke) const;
        void set_next_key(const json::Value* nr);

      private:
        bool m_state_read = false;
        std::optional<json::Value> m_state; // an object, once read or set
        TrustedKey check_signature(const fs::path& file, const fs::path& sig, std::initializer_list<const char*> roles, const std::string& what,
                                   std::vector<uint8_t>& message);
    };

    // The verified index entry of (normalized id, version), or nullptr.
    const json::Value* find_version(const json::Value& ix, const std::string& id, const std::string& version);
    // The first revoked entry matching (normalized id, version, sha256 in any case), or nullptr.
    const json::Value* find_revoked(const json::Value& rv, const std::string& id, const std::string& version, const std::string& sha);
    // Mod Manager v2 story 6: is an INSTALLED (normalized id, version) revoked? The first revoked entry with the same
    // normalized id and version for which either its sha256 equals the index's sha256 of that version (any case), or the
    // index no longer lists that version; nullptr otherwise. An installed copy has no zip hash on disk, so the match is
    // on the catalog's release: a different build with the same version number is only flagged, never touched. Both
    // actions (disable, block) only flag. Mod Manager's catalog.lua applies the same rule.
    const json::Value* find_revoked_installed(const json::Value& ix, const json::Value& rv, const std::string& id, const std::string& version);
} // namespace catalog
