// The signed catalog's natives (Mod Manager v2 story 2; api-contract.md "C++ natives", README "Catalog").
//
// Fetching and verification run in C++ on one background worker thread; Lua only starts jobs and polls results. The
// rules are verify.ps1's (catalog/verify.cpp, catalog/fetch.cpp): built-in trust roots and endpoints, keys.json first,
// serial rollback guards, at most 2 endpoint restarts and 5 redirects (by hand, to allowed hosts only), 4 MiB per catalog
// file and 4096 bytes per .minisig, 403/429 back-off, an unreachable base falls through, a rejected one is the outcome
// and the last verified copy is then not used.
//
// Data (from main.dll's own path Mods/<Core>/dlls/main.dll, never from Lua): ue4ss/<Core>Data/catalog/state.json (the
// state, verify.ps1's keys), ue4ss/<Core>Data/catalog/copy/ (the last verified copy) and ue4ss/<Core>Data/downloads/
// (verified release files, <sha256>.zip). Outside Mods/, so updating or removing a mod never touches them.
//
//   <Core>_CatalogRefresh() -> job
//     Fetches and verifies the catalog (RunFetch with the state file and the copy). Outcomes: verify.ps1's codes (ok,
//     bad-signature, unknown-key, serial-rollback, schema-too-new, invalid-index, url-not-allowed, error). Payload of ok:
//     {"source":"network"|"copy","base":<url>|null,"index_issued","revoked_issued"|null,"details":[...],
//      "index":<the verified index>,"revoked":<the verified list>|null}; otherwise {"details":[...]}. An ok refresh
//     makes its index and revoked list the ones downloads use; any other outcome forgets them.
//   <Core>_CatalogDownload(id, version) -> job, or nil, reason before anything is fetched:
//     "busy", "no verified catalog" (no ok refresh in this session), "not in the catalog", "too large" (index size over
//     256 MiB), "downloads folder full" (512 MiB with this file), "data folder unknown". A version the revoked list
//     names (either action) gives a finished job with outcome "revoked". Otherwise the job downloads the index's url
//     (redirects only to github.com and GitHub's release-asset hosts), reads at most size + 1 bytes and keeps the file as
//     downloads/<sha256>.zip only when size and SHA-256 equal the index's. Outcomes: ok, size-mismatch, hash-mismatch,
//     url-not-allowed, unreachable, error. Payload of ok: {"id","version","sha256","size","file"}.
//   <Core>_CatalogPoll(job) -> "running" | "done", outcome, message, payloadJson; nil, "unknown job" for a job that
//     never existed or is no longer kept (the last 8 finished jobs are).
// One job at a time: a start while one is queued or running answers nil, "busy". Arguments: Refresh takes none; Download
// two strings (id through the mod id normalizer, at most 200 bytes; version semver, at most 128 bytes); Poll one
// integer 1..2^53-1. Anything else raises "<fn>: <problem>". The worker never touches Lua or a UObject; it catches
// everything.
#include "catalog.hpp"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <format>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>

#include "catalog/fetch.hpp"
#include "catalog/json.hpp"
#include "catalog/verify.hpp"
#include "core_config.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

namespace core_native::catalog_natives
{
    const std::string g_fn_refresh = std::string{CORE_NAME} + "_CatalogRefresh";
    const std::string g_fn_download = std::string{CORE_NAME} + "_CatalogDownload";
    const std::string g_fn_poll = std::string{CORE_NAME} + "_CatalogPoll";

    namespace
    {
        namespace cat = ::catalog;
        namespace fs = std::filesystem;
        using cat::json::Value;

        constexpr int64_t k_max_job = (int64_t{1} << 53) - 1;
        constexpr size_t k_kept = 8;
        constexpr size_t k_max_version = 128;

        struct Job
        {
            enum class Kind
            {
                Refresh,
                Download
            } kind = Kind::Refresh;
            int64_t id = 0;
            cat::fetch::Plan plan;
            std::string outcome, message, payload;
        };

        // The verified catalog downloads use (an ok refresh's).
        struct Verified
        {
            Value ix;
            std::optional<Value> rv;
        };

        std::mutex g_mu;
        std::condition_variable g_cv;
        std::thread* g_thread = nullptr; // never a static std::thread: one left joinable at process exit would terminate
        bool g_stop = false;
        std::optional<Job> g_pending;
        int64_t g_running = 0;
        std::deque<Job> g_finished;
        int64_t g_next = 1;
        std::shared_ptr<const Verified> g_verified;
        std::atomic<bool> g_cancel{false};
        cat::fetch::Transport* g_transport = nullptr; // the running job's, under g_mu

        // ue4ss/<Core>Data from this DLL's path ue4ss/Mods/<Core>/dlls/main.dll; empty when the layout differs.
        fs::path data_dir()
        {
            HMODULE self = nullptr;
            if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, reinterpret_cast<LPCWSTR>(&data_dir),
                                    &self))
            {
                return {};
            }
            std::vector<wchar_t> buf(MAX_PATH);
            std::wstring dll;
            while (buf.size() <= 32768)
            {
                const DWORD n = GetModuleFileNameW(self, buf.data(), static_cast<DWORD>(buf.size()));
                if (n == 0) return {};
                if (n < buf.size())
                {
                    dll.assign(buf.data(), n);
                    break;
                }
                buf.resize(buf.size() * 2);
            }
            const fs::path dlls = fs::path{dll}.parent_path();
            const fs::path mod = dlls.parent_path();
            const fs::path mods = mod.parent_path();
            const fs::path ue4ss = mods.parent_path();
            auto same = [](const fs::path& p, const std::wstring& name) {
                const std::wstring leaf = p.filename().wstring();
                return CompareStringOrdinal(leaf.c_str(), static_cast<int>(leaf.size()), name.c_str(), static_cast<int>(name.size()), TRUE) == CSTR_EQUAL;
            };
            if (ue4ss.empty() || !same(dlls, L"dlls") || !same(mod, cat::widen(CORE_NAME)) || !same(mods, L"Mods")) return {};
            return ue4ss / cat::widen(std::string{CORE_NAME} + "Data");
        }

        Result nil_reason(std::string why)
        {
            Result r;
            r.kind = Result::Kind::NilText;
            r.text = std::move(why);
            return r;
        }
        Result integer(int64_t v)
        {
            Result r;
            r.kind = Result::Kind::Integer;
            r.integer = v;
            return r;
        }

        // At most 64 printable bytes of what a caller passed, for an error message.
        std::string echo(std::string_view s)
        {
            std::string out;
            for (const unsigned char c : s.substr(0, 64)) out += (c >= 0x20 && c <= 0x7E) ? static_cast<char>(c) : '?';
            if (s.size() > 64) out += "...";
            return out;
        }

        std::string strip_bom(const std::string& s)
        {
            return s.rfind("\xEF\xBB\xBF", 0) == 0 ? s.substr(3) : s;
        }

        std::string details_json(const std::vector<std::string>& details)
        {
            Value arr = Value::array();
            for (const auto& d : details) arr.items.push_back(Value::string(d));
            return cat::json::write(arr);
        }

        cat::fetch::Options transport_options()
        {
            cat::fetch::Options o;
            o.user_agent = std::string{CORE_NAME} + "/" + CORE_VERSION;
            return o;
        }

        // Runs t's job with a transport the destructor can cancel.
        template <typename Body>
        void with_transport(Body&& body)
        {
            auto t = cat::fetch::make_transport(transport_options());
            {
                std::lock_guard g{g_mu};
                g_transport = t.get();
                if (g_cancel.load()) t->cancel();
            }
            struct Clear
            {
                ~Clear()
                {
                    std::lock_guard g{g_mu};
                    g_transport = nullptr;
                }
            } clear;
            body(*t);
        }

        void run_refresh(Job& job, const fs::path& data)
        {
            cat::Verifier v;
            try
            {
                v.state_file = data / L"catalog" / L"state.json";
                v.note("trust: built-in (3 keys)");
                v.trust_builtin();
                v.trust_saved_next();
                const fs::path copy = data / L"catalog" / L"copy";
                std::error_code ec;
                fs::create_directories(copy, ec);
                if (ec) cat::fail("error", "the catalog folder could not be created: " + cat::shown(copy));
                std::optional<cat::fetch::RunResult> res;
                with_transport([&](cat::fetch::Transport& t) { res = cat::fetch::run_fetch(v, t, {copy, ""}); });
                auto verified = std::make_shared<Verified>();
                verified->ix = res->ix;
                verified->rv = res->rv;
                std::vector<std::string> what;
                if (res->keys) what.push_back("keys.json serial " + std::to_string(res->keys->doc.get("serial")->i));
                what.push_back("index serial " + std::to_string(res->ix.get("serial")->i));
                if (res->rv) what.push_back("revoked list serial " + std::to_string(res->rv->get("serial")->i));
                std::string msg;
                for (size_t i = 0; i < what.size(); ++i) msg += (i ? " and " : "") + what[i];
                job.outcome = "ok";
                job.message = msg + " verified" + (res->from.empty() ? " (verified copy in " + cat::shown(copy) + ")" : " from " + res->from);
                std::string p = "{\"source\":";
                p += res->from.empty() ? "\"copy\",\"base\":null" : "\"network\",\"base\":" + cat::json::quote(res->from);
                p += ",\"index_issued\":" + cat::json::quote(res->ix.get("issued")->s);
                p += ",\"revoked_issued\":" + (res->rv ? cat::json::quote(res->rv->get("issued")->s) : std::string{"null"});
                p += ",\"details\":" + details_json(v.details);
                p += ",\"index\":" + strip_bom(v.last_index_text);
                p += ",\"revoked\":" + (res->rv ? strip_bom(v.last_revoked_text) : std::string{"null"});
                p += "}";
                job.payload = std::move(p);
                std::lock_guard g{g_mu};
                g_verified = std::move(verified);
                return;
            }
            catch (const cat::Reject& r)
            {
                job.outcome = r.code;
                job.message = r.message;
            }
            catch (const cat::Unreachable& u)
            {
                job.outcome = "error";
                job.message = "unexpected failure: " + u.message;
            }
            catch (const std::exception& e)
            {
                job.outcome = "error";
                job.message = std::string{"unexpected failure: "} + e.what();
            }
            job.payload = "{\"details\":" + details_json(v.details) + "}";
            // A rejected (or failed) refresh: what an earlier one verified is no longer used.
            std::lock_guard g{g_mu};
            g_verified.reset();
        }

        void run_download(Job& job, const fs::path& data)
        {
            cat::Verifier v;
            const auto& plan = job.plan;
            try
            {
                fs::path file;
                with_transport([&](cat::fetch::Transport& t) {
                    file = cat::fetch::download_with_state(v, t, plan, data / L"downloads", data / L"catalog" / L"state.json", g_cancel);
                });
                job.outcome = "ok";
                job.message = "package " + plan.id + " " + plan.version + " downloaded";
                job.payload = cat::fetch::download_payload(plan, &file);
                return;
            }
            catch (const cat::Reject& r)
            {
                job.outcome = r.code;
                job.message = r.message;
            }
            catch (const cat::Unreachable& u)
            {
                job.outcome = "unreachable";
                job.message = u.message;
            }
            catch (const std::exception& e)
            {
                job.outcome = "error";
                job.message = std::string{"unexpected failure: "} + e.what();
            }
            job.payload = cat::fetch::download_payload(plan, nullptr);
        }

        void worker()
        {
            while (true)
            {
                Job job;
                {
                    std::unique_lock lk{g_mu};
                    g_cv.wait(lk, [] { return g_stop || g_pending.has_value(); });
                    if (g_stop) return;
                    job = std::move(*g_pending);
                    g_pending.reset();
                    g_running = job.id;
                }
                const char* what = job.kind == Job::Kind::Refresh ? "refresh" : "download";
                try
                {
                    const fs::path data = data_dir();
                    if (data.empty())
                    {
                        job.outcome = "error";
                        job.message = "data folder unknown";
                        job.payload = "{}";
                    }
                    else if (job.kind == Job::Kind::Refresh)
                    {
                        run_refresh(job, data);
                    }
                    else
                    {
                        run_download(job, data);
                    }
                }
                catch (const std::exception& e)
                {
                    job.outcome = "error";
                    job.message = std::string{"unexpected failure: "} + e.what();
                    job.payload = "{}";
                }
                catch (...)
                {
                    job.outcome = "error";
                    job.message = "unexpected failure (unknown C++ exception)";
                    job.payload = "{}";
                }
                logf("catalog: {} job {} done: {}: {}", what, job.id, job.outcome, job.message);
                std::lock_guard g{g_mu};
                g_running = 0;
                g_finished.push_back(std::move(job));
                while (g_finished.size() > k_kept) g_finished.pop_front();
            }
        }

        // Under g_mu: queues job and starts the worker on first use.
        int64_t queue(Job job)
        {
            job.id = g_next++;
            const int64_t id = job.id;
            g_pending = std::move(job);
            if (!g_thread) g_thread = new std::thread(&worker);
            g_cv.notify_all();
            return id;
        }
        bool busy() { return g_pending.has_value() || g_running != 0; }
    } // namespace

    int l_refresh(const Lua& lua)
    {
        return guarded(lua, g_fn_refresh, [&] {
            if (lua.get_stack_size() != 0) throw ArgError(std::format("{}: takes no arguments", g_fn_refresh));
            if (data_dir().empty()) return nil_reason("data folder unknown");
            std::lock_guard g{g_mu};
            if (g_stop) return nil_reason("busy");
            if (busy()) return nil_reason("busy");
            Job job;
            job.kind = Job::Kind::Refresh;
            const int64_t id = queue(std::move(job));
            logf("catalog: refresh job {} started", id);
            return integer(id);
        });
    }

    int l_download(const Lua& lua)
    {
        return guarded(lua, g_fn_download, [&] {
            const std::string& fn = g_fn_download;
            require_args(lua, fn, 2, " (id, version)");
            // Arguments are taken from the bottom of the stack: each read removes argument 1.
            if (!lua.is_string(1)) throw ArgError(std::format("{}: argument 1 (id) must be a string, got {}", fn, describe_first_arg(lua)));
            const std::string id_in{lua.get_string(1)};
            if (!lua.is_string(1)) throw ArgError(std::format("{}: argument 2 (version) must be a string, got {}", fn, describe_first_arg(lua)));
            const std::string version{lua.get_string(1)};
            const auto nid = cat::modid::normalize(id_in);
            if (!nid.error.empty()) throw ArgError(std::format("{}: argument 1 (id): {}", fn, nid.error));
            if (version.size() > k_max_version) throw ArgError(std::format("{}: argument 2 (version) must be at most {} bytes, got {}", fn, k_max_version, version.size()));
            if (!cat::is_semver(version)) throw ArgError(std::format("{}: argument 2 (version) is not semver: '{}'", fn, echo(version)));
            const fs::path data = data_dir();
            if (data.empty()) return nil_reason("data folder unknown");
            std::shared_ptr<const Verified> verified;
            {
                std::lock_guard g{g_mu};
                if (g_stop || busy()) return nil_reason("busy");
                verified = g_verified;
            }
            if (!verified) return nil_reason("no verified catalog");
            std::string reason;
            const auto plan = cat::fetch::plan_download(verified->ix, verified->rv ? &*verified->rv : nullptr, nid.id, version, data / L"downloads", reason);
            if (!plan) return nil_reason(reason);
            std::lock_guard g{g_mu};
            if (g_stop || busy()) return nil_reason("busy");
            if (!plan->revoked.empty())
            {
                // Revoked (either action): a finished job, nothing fetched.
                Job job;
                job.kind = Job::Kind::Download;
                job.id = g_next++;
                job.plan = *plan;
                job.outcome = "revoked";
                job.message = plan->revoked;
                job.payload = cat::fetch::download_payload(*plan, nullptr);
                const int64_t id = job.id;
                logf("catalog: download job {} refused: {}", id, plan->revoked);
                g_finished.push_back(std::move(job));
                while (g_finished.size() > k_kept) g_finished.pop_front();
                return integer(id);
            }
            Job job;
            job.kind = Job::Kind::Download;
            job.plan = *plan;
            const int64_t id = queue(std::move(job));
            logf("catalog: download job {} started ({} {})", id, plan->id, plan->version);
            return integer(id);
        });
    }

    int l_poll(const Lua& lua)
    {
        return guarded(lua, g_fn_poll, [&] {
            const std::string& fn = g_fn_poll;
            require_args(lua, fn, 1, " (job)");
            if (!lua.is_integer(1)) throw ArgError(std::format("{}: argument 1 (job) must be an integer, got {}", fn, describe_first_arg(lua)));
            const int64_t job = lua.get_integer(1);
            if (job < 1 || job > k_max_job) throw ArgError(std::format("{}: job {} is out of range (1..{})", fn, job, k_max_job));
            std::lock_guard g{g_mu};
            if (job == g_running || (g_pending && g_pending->id == job))
            {
                Result r;
                r.kind = Result::Kind::String;
                r.text = "running";
                return r;
            }
            for (const auto& j : g_finished)
            {
                if (j.id != job) continue;
                Result r;
                r.kind = Result::Kind::Texts;
                r.texts = {"done", j.outcome, j.message, j.payload};
                return r;
            }
            return nil_reason("unknown job");
        });
    }

    void shutdown()
    {
        try
        {
            std::thread* t = nullptr;
            {
                std::lock_guard g{g_mu};
                g_stop = true;
                g_cancel = true;
                if (g_transport) g_transport->cancel();
                t = g_thread;
                g_thread = nullptr;
            }
            g_cv.notify_all();
            if (t)
            {
                if (t->joinable()) t->join();
                delete t;
                logf("unloading: catalog worker stopped");
            }
        }
        catch (...)
        {
            logf("ERROR stopping the catalog worker (unknown exception)");
        }
    }
} // namespace core_native::catalog_natives
