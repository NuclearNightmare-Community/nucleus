// <Core>CatalogTest.exe (Mod Manager v2 story 2): a console build of core's catalog code (CORE_CATALOG_TEST), never
// packaged. It takes verify.ps1's parameters and prints verify.ps1's output ("outcome: <code>", "message: ...", then the
// detail lines; exit 0 ok, 1 rejected, 2 error), so tools/release/tests/run-tests.ps1 and run-fetch-tests.ps1 can run
// it in place of verify.ps1 (-Verifier). Test-only parameters:
//   -Proxy <host:port>    send every request through this proxy (the HTTPS fixture server)
//   -PinCert <sha256>     accept only this server certificate (by the SHA-256 of its DER bytes) instead of Windows' checks
//   -Transport <map>      checked and reported as verify.ps1 does ("transport: <map> (fixture)"); the requests still go
//                         over HTTPS through -Proxy, to the fixture server serving that map
//   -ModId <s>            print "id: <normalized>" or "error: <message>" (the normalizer, for modid-cases.json)
//   -PrintBuiltIns        print the compiled-in trust roots, endpoints and redirect hosts
//   -Download             with -Index [-Revoked] -Id -Version -OutDir <downloads folder>: the release-file download core's
//                         <Core>_CatalogDownload runs; outcome refused (message: the reason) when it is refused up front
//   -Stage <id> <version> [<id> <version> ...]
//                         with -Root <dir> -Index [-Revoked] [-StateFile]: the stage <Core>_CatalogStage runs (Mod Manager v2
//                         story 5; stage/install.hpp), against the install layout under <dir> (story 3's --root: a temp
//                         folder holding NuclearNightmare\...); prints the outcome, the message, the detail lines and
//                         "payload: <json>"; downloads go to <dir>'s <Core>Data\downloads
// -Minisign is accepted and ignored (signatures are checked in process).
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include "catalog/fetch.hpp"
#include "catalog/minisig.hpp"
#include "catalog/text.hpp"
#include "catalog/verify.hpp"
#include "core_config.hpp"
#include "stage/install.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

using namespace catalog;

namespace
{
    // Writes UTF-8 text as the console's output code page (what the parent PowerShell decodes with), or UTF-8.
    void out(const std::string& line)
    {
        const std::string s = line + "\n";
        HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
        const UINT cp = GetConsoleOutputCP();
        std::string bytes = s;
        if (cp != 0 && cp != CP_UTF8)
        {
            const std::wstring w = widen(s);
            const int n = WideCharToMultiByte(cp, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
            if (n > 0)
            {
                bytes.assign(static_cast<size_t>(n), '\0');
                WideCharToMultiByte(cp, 0, w.data(), static_cast<int>(w.size()), bytes.data(), n, nullptr, nullptr);
            }
        }
        DWORD put = 0;
        WriteFile(h, bytes.data(), static_cast<DWORD>(bytes.size()), &put, nullptr);
    }

    int finish(const std::string& code, const std::string& message, const std::vector<std::string>& details)
    {
        out("outcome: " + code);
        if (!message.empty()) out("message: " + message);
        for (const auto& d : details) out(d);
        return code == "ok" ? 0 : code == "error" ? 2 : 1;
    }

    struct Args
    {
        std::map<std::string, std::string> values; // lower-case name -> value
        std::vector<std::string> switches;
        std::vector<std::string> stage; // -Stage's id, version pairs
        std::string bad;
        std::string get(const char* n) const
        {
            const auto it = values.find(n);
            return it == values.end() ? std::string{} : it->second;
        }
        bool sw(const char* n) const
        {
            for (const auto& s : switches)
            {
                if (s == n) return true;
            }
            return false;
        }
    };

    Args parse_args(int argc, wchar_t** argv)
    {
        static const char* valued[] = {"index", "signature", "revoked", "revokedsignature", "keys", "keyssignature", "url", "outdir", "transport",
                                       "statefile", "package", "id", "version", "trustedkeys", "minisign", "proxy", "pincert", "modid", "root"};
        static const char* flags[] = {"fetch", "printbuiltins", "download"};
        Args a;
        for (int i = 1; i < argc; ++i)
        {
            const std::string arg = narrow(argv[i]);
            if (arg.size() < 2 || arg[0] != '-')
            {
                a.bad = "unexpected argument: " + arg;
                return a;
            }
            const std::string name = text::lower(arg.substr(1));
            bool known = false;
            if (name == "stage")
            {
                a.switches.push_back(name);
                while (i + 1 < argc && !(argv[i + 1][0] == L'-' && argv[i + 1][1] != L'\0' && !(argv[i + 1][1] >= L'0' && argv[i + 1][1] <= L'9'))) a.stage.push_back(narrow(argv[++i]));
                continue;
            }
            for (const char* f : flags)
            {
                if (name == f)
                {
                    a.switches.push_back(name);
                    known = true;
                }
            }
            for (const char* v : valued)
            {
                if (name == v)
                {
                    if (i + 1 >= argc)
                    {
                        a.bad = "missing a value for " + arg;
                        return a;
                    }
                    a.values[name] = narrow(argv[++i]);
                    known = true;
                }
            }
            if (!known)
            {
                a.bad = "unknown parameter: " + arg;
                return a;
            }
        }
        return a;
    }

    fetch::Options transport_options(const Args& a)
    {
        fetch::Options o;
        o.user_agent = std::string{CORE_NAME} + "CatalogTest/" + CORE_VERSION;
        o.proxy = a.get("proxy");
        o.pin_sha256 = a.get("pincert");
        return o;
    }

    void trust(Verifier& v, const Args& a, std::string trusted_keys)
    {
        if (!trusted_keys.empty())
        {
            if (!is_file(full_path(trusted_keys))) fail("error", "trusted keys file not found: " + trusted_keys);
            const fs::path tk = full_path(trusted_keys);
            std::vector<uint8_t> bytes;
            json::Value list;
            std::string err;
            if (!read_file(tk, 1u << 20, bytes) || !json::parse(std::string_view{reinterpret_cast<const char*>(bytes.data()), bytes.size()}, list, err))
            {
                fail("error", "trusted keys file is not JSON: " + shown(tk));
            }
            v.note("trust: " + shown(tk) + " (override)");
            v.trust_list(list);
        }
        else
        {
            v.note("trust: built-in (3 keys)");
            v.trust_builtin();
        }
        (void)a;
    }

    int print_builtins()
    {
        for (const auto& k : k_builtin_keys) out(std::string{"key: "} + k.role + " " + k.name + " " + k.key);
        out(std::string{"primary: "} + k_builtin_primary);
        out(std::string{"fallback: "} + k_builtin_fallback);
        for (const char* h : k_redirect_hosts) out(std::string{"redirect: "} + h);
        return 0;
    }

    // -Download: verify the index (and revoked list) files, then the same download as <Core>_CatalogDownload.
    int run_download_mode(const Args& a)
    {
        Verifier v;
        std::optional<fetch::Plan> planned;
        try
        {
            const std::string index = a.get("index"), revoked = a.get("revoked"), id_in = a.get("id"), version = a.get("version"), dir = a.get("outdir");
            if (index.empty() || id_in.empty() || version.empty() || dir.empty()) fail("error", "-Download needs -Index, -Id, -Version and -OutDir");
            const auto nid = modid::normalize(id_in);
            if (!nid.error.empty()) fail("error", "-Id: " + nid.error);
            if (!is_semver(version)) fail("error", "-Version: not semver");
            const fs::path state_file = a.get("statefile").empty() ? fs::path{} : full_path(a.get("statefile"));
            trust(v, a, a.get("trustedkeys"));
            const fs::path ixf = full_path(index);
            const json::Value ix = v.check_index_file(ixf, fs::path{ixf} += L".minisig");
            std::optional<json::Value> rv;
            if (!revoked.empty())
            {
                const fs::path rvf = full_path(revoked);
                rv = v.check_revoked_file(rvf, fs::path{rvf} += L".minisig");
            }
            const fs::path downloads = full_path(dir);
            std::string reason;
            const auto plan = fetch::plan_download(ix, rv ? &*rv : nullptr, nid.id, version, downloads, reason);
            if (!plan) return finish("refused", reason, v.details);
            planned = *plan;
            if (!plan->revoked.empty())
            {
                v.note("payload: " + fetch::download_payload(*plan, nullptr));
                return finish("revoked", plan->revoked, v.details);
            }
            auto t = fetch::make_transport(transport_options(a));
            std::atomic<bool> cancel{false};
            // The index and revoked list are verified without a state file (as core's job has them in memory); the state
            // file serves back-off only, as in core's download job.
            const fs::path file = fetch::download_with_state(v, *t, *plan, downloads, state_file, cancel);
            v.note("file: " + shown(file));
            v.note("payload: " + fetch::download_payload(*plan, &file));
            return finish("ok", "package " + plan->id + " " + plan->version + " downloaded", v.details);
        }
        catch (const Reject& r)
        {
            if (planned) v.note("payload: " + fetch::download_payload(*planned, nullptr));
            return finish(r.code, r.message, v.details);
        }
        catch (const Unreachable& u)
        {
            if (planned) v.note("payload: " + fetch::download_payload(*planned, nullptr));
            return finish("unreachable", u.message, v.details);
        }
        catch (const std::exception& e)
        {
            if (planned) v.note("payload: " + fetch::download_payload(*planned, nullptr));
            return finish("error", std::string{"unexpected failure: "} + e.what(), v.details);
        }
    }
    // -Stage: verify the index (and revoked list) files, then the same stage as <Core>_CatalogStage, under -Root.
    int run_stage_mode(const Args& a)
    {
        Verifier v;
        try
        {
            const std::string index = a.get("index"), revoked = a.get("revoked"), root = a.get("root");
            if (index.empty() || root.empty()) fail("error", "-Stage needs -Root and -Index");
            if (a.stage.empty() || a.stage.size() % 2 != 0) fail("error", "-Stage takes <id> <version> pairs");
            std::vector<core_stage::install::Item> items;
            for (size_t k = 0; k < a.stage.size(); k += 2)
            {
                const auto nid = modid::normalize(a.stage[k]);
                if (!nid.error.empty()) fail("error", "-Stage id " + a.stage[k] + ": " + nid.error);
                if (!is_semver(a.stage[k + 1])) fail("error", "-Stage version " + a.stage[k + 1] + ": not semver");
                for (const auto& it : items)
                    if (it.id == nid.id) fail("error", "-Stage: " + nid.id + " is listed twice");
                items.push_back({nid.id, a.stage[k + 1]});
            }
            if (items.size() > core_stage::install::k_max_pairs) fail("error", "-Stage: at most 16 pairs");
            core_stage::Layout l;
            if (!core_stage::layout_from_root(full_path(root).wstring(), widen(CORE_NAME), l)) fail("error", "-Root is not an absolute folder");
            const fs::path state_file = a.get("statefile").empty() ? fs::path{} : full_path(a.get("statefile"));
            trust(v, a, a.get("trustedkeys"));
            const fs::path ixf = full_path(index);
            const json::Value ix = v.check_index_file(ixf, fs::path{ixf} += L".minisig");
            std::optional<json::Value> rv;
            if (!revoked.empty())
            {
                const fs::path rvf = full_path(revoked);
                rv = v.check_revoked_file(rvf, fs::path{rvf} += L".minisig");
            }
            if (const std::string b = core_stage::install::blocked(l); !b.empty()) return finish(b, "refused before the job: " + b, v.details);
            auto t = fetch::make_transport(transport_options(a));
            std::atomic<bool> cancel{false};
            const auto o = core_stage::install::run_stage(l, ix, rv ? &*rv : nullptr, items, *t, state_file, cancel);
            for (const auto& d : o.details) v.note(d);
            v.note("payload: " + o.payload);
            return finish(o.outcome, o.message, v.details);
        }
        catch (const Reject& r)
        {
            return finish(r.code, r.message, v.details);
        }
        catch (const std::exception& e)
        {
            return finish("error", std::string{"unexpected failure: "} + e.what(), v.details);
        }
    }
} // namespace

int wmain(int argc, wchar_t** argv)
{
    const Args a = parse_args(argc, argv);
    if (!a.bad.empty()) return finish("error", a.bad, {});
    if (a.values.count("modid"))
    {
        const auto n = modid::normalize(a.get("modid"));
        out(n.error.empty() ? "id: " + n.id : "error: " + n.error);
        return 0;
    }
    if (a.sw("printbuiltins")) return print_builtins();
    if (a.sw("download")) return run_download_mode(a);
    if (a.sw("stage")) return run_stage_mode(a);

    Verifier v;
    std::string code, message;
    try
    {
        std::string index = a.get("index"), signature = a.get("signature"), revoked = a.get("revoked"), revoked_sig = a.get("revokedsignature"),
                    keys = a.get("keys"), keys_sig = a.get("keyssignature"), url = a.get("url"), out_dir = a.get("outdir"), transport = a.get("transport"),
                    state_file = a.get("statefile"), package = a.get("package"), id = a.get("id"), version = a.get("version");
        const bool fetch_flag = a.sw("fetch");
        // --- usage and trust roots
        const bool fetch_mode = fetch_flag || !url.empty();
        fs::path out_path, transport_path;
        if (fetch_mode)
        {
            if (fetch_flag && !url.empty()) fail("error", "-Fetch and -Url do not go together");
            if (!index.empty() || !revoked.empty() || !keys.empty() || !signature.empty() || !revoked_sig.empty() || !keys_sig.empty())
            {
                fail("error", "-Fetch and -Url do not combine with -Index, -Revoked or -Keys (or their signatures)");
            }
            if (out_dir.empty()) fail("error", "-Fetch and -Url need -OutDir");
            if (!url.empty())
            {
                if (auto problem = endpoint_problem(url)) fail("error", "-Url: " + *problem);
            }
            out_path = full_path(out_dir);
            if (is_file(out_path)) fail("error", "-OutDir is a file: " + shown(out_path));
            if (!transport.empty())
            {
                if (!is_file(full_path(transport))) fail("error", "transport file not found: " + transport);
                transport_path = full_path(transport);
                std::vector<uint8_t> bytes;
                json::Value tj;
                std::string err;
                if (!read_file(transport_path, 16u << 20, bytes) ||
                    !json::parse(std::string_view{reinterpret_cast<const char*>(bytes.data()), bytes.size()}, tj, err, 16))
                {
                    fail("error", "transport file is not JSON: " + shown(transport_path));
                }
                if (!tj.is_obj()) fail("error", "transport file is not a JSON object: " + shown(transport_path));
            }
        }
        else
        {
            if (!out_dir.empty()) fail("error", "-OutDir needs -Fetch or -Url");
            if (!transport.empty()) fail("error", "-Transport needs -Fetch or -Url");
            if (index.empty() && revoked.empty() && keys.empty()) fail("error", "pass -Index, -Revoked or both (or -Keys, -Fetch, -Url)");
        }
        fs::path keys_path, keys_sig_path, index_path, sig_path, revoked_path, revoked_sig_path, package_path;
        if (!keys.empty())
        {
            if (!is_file(full_path(keys))) fail("error", "keys.json not found: " + keys);
            keys_path = full_path(keys);
            keys_sig_path = keys_sig.empty() ? fs::path{keys_path} += L".minisig" : full_path(keys_sig);
        }
        else if (!keys_sig.empty()) fail("error", "-KeysSignature needs -Keys");
        if (!index.empty())
        {
            if (!is_file(full_path(index))) fail("error", "index not found: " + index);
            index_path = full_path(index);
            sig_path = signature.empty() ? fs::path{index_path} += L".minisig" : full_path(signature);
        }
        else if (!signature.empty()) fail("error", "-Signature needs -Index");
        if (!revoked.empty())
        {
            if (!is_file(full_path(revoked))) fail("error", "revoked list not found: " + revoked);
            revoked_path = full_path(revoked);
            revoked_sig_path = revoked_sig.empty() ? fs::path{revoked_path} += L".minisig" : full_path(revoked_sig);
        }
        else if (!revoked_sig.empty()) fail("error", "-RevokedSignature needs -Revoked");
        const bool with_package = !package.empty() || !id.empty() || !version.empty();
        if (with_package)
        {
            if (package.empty() || id.empty() || version.empty()) fail("error", "-Package, -Id and -Version go together");
            const auto nid = modid::normalize(id);
            if (!nid.error.empty()) fail("error", "-Id: " + nid.error);
            id = nid.id;
            if (index.empty() && !fetch_mode) fail("error", "-Package, -Id and -Version need -Index (or -Fetch, -Url)");
            if (!is_file(full_path(package))) fail("error", "package not found: " + package);
            package_path = full_path(package);
        }
        if (!state_file.empty()) v.state_file = full_path(state_file);
        trust(v, a, a.get("trustedkeys"));
        // The next release key accepted from an earlier keys.json.
        v.trust_saved_next();
        if (!transport_path.empty()) v.note("transport: " + shown(transport_path) + " (fixture)");

        std::optional<KeysResult> kr;
        std::optional<json::Value> ix, rv;
        std::string hash, from;
        if (fetch_mode)
        {
            std::error_code ec;
            if (!path_exists(out_path)) fs::create_directories(out_path, ec);
            auto t = fetch::make_transport(transport_options(a));
            auto f = fetch::run_fetch(v, *t, {out_path, url});
            kr = std::move(f.keys);
            ix = std::move(f.ix);
            rv = std::move(f.rv);
            from = f.from.empty() ? " (verified copy in " + shown(out_path) + ")" : " from " + f.from;
            if (with_package)
            {
                hash = v.check_package_file(*ix, package_path, id, version);
                if (rv) v.check_revoked_match(*rv, id, version, hash);
            }
        }
        else
        {
            if (!keys.empty()) kr = v.check_keys_file(keys_path, keys_sig_path);
            if (!index.empty())
            {
                ix = v.check_index_file(index_path, sig_path);
                if (with_package) hash = v.check_package_file(*ix, package_path, id, version);
            }
            if (!revoked.empty())
            {
                rv = v.check_revoked_file(revoked_path, revoked_sig_path);
                if (with_package) v.check_revoked_match(*rv, id, version, hash);
            }
        }
        std::vector<std::string> what;
        if (kr) what.push_back("keys.json serial " + std::to_string(kr->doc.get("serial")->i));
        if (ix) what.push_back("index serial " + std::to_string(ix->get("serial")->i));
        if (rv) what.push_back("revoked list serial " + std::to_string(rv->get("serial")->i));
        code = "ok";
        message = text::join(what, " and ") + " verified" + from;
    }
    catch (const Reject& r)
    {
        code = r.code;
        message = r.message;
    }
    catch (const Unreachable& u)
    {
        code = "error";
        message = "unexpected failure: " + u.message;
    }
    catch (const std::exception& e)
    {
        code = "error";
        message = std::string{"unexpected failure: "} + e.what();
    }
    return finish(code, message, v.details);
}
