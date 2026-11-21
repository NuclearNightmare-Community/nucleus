// Staging installs from the verified catalog (install.hpp has the rules).
#include "install.hpp"

#include <bcrypt.h>

#include <algorithm>
#include <map>
#include <optional>

#include "../catalog/verify.hpp"
#include "core_config.hpp"
#include "apply.hpp"
#include "zip.hpp"

namespace core_stage::install
{
    namespace
    {
        namespace cat = ::catalog;
        namespace fs = std::filesystem;
        using cat::json::Value;

        struct Fail
        {
            std::string outcome, message;
        };

        bool ieq(std::string_view a, std::string_view b)
        {
            if (a.size() != b.size()) return false;
            for (size_t i = 0; i < a.size(); ++i)
            {
                auto lo = [](char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; };
                if (lo(a[i]) != lo(b[i])) return false;
            }
            return true;
        }
        bool ends_i(std::string_view s, std::string_view suffix) { return s.size() >= suffix.size() && ieq(s.substr(s.size() - suffix.size()), suffix); }

        std::vector<std::string> split(const std::string& s, char sep)
        {
            std::vector<std::string> out;
            size_t start = 0;
            while (true)
            {
                const size_t i = s.find(sep, start);
                if (i == std::string::npos)
                {
                    out.push_back(s.substr(start));
                    return out;
                }
                out.push_back(s.substr(start, i - start));
                start = i + 1;
            }
        }

        // At most 96 printable bytes, for a message.
        std::string shown(const std::string& s)
        {
            std::string out;
            for (const unsigned char c : s.substr(0, 96)) out += (c >= 0x20 && c <= 0x7E) ? static_cast<char>(c) : '?';
            if (s.size() > 96) out += "...";
            return out;
        }

        std::string sha_of(const std::vector<uint8_t>& data)
        {
            Sha256 h;
            if (!h.ok()) return {};
            if (!data.empty()) h.update(data.data(), data.size());
            return h.hex();
        }

        std::string new_txn()
        {
            uint8_t b[16]{};
            if (BCryptGenRandom(nullptr, b, sizeof b, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return {};
            static const char* hex = "0123456789abcdef";
            std::string s;
            for (uint8_t c : b)
            {
                s += hex[c >> 4];
                s += hex[c & 15];
            }
            return s;
        }

        // The package (kind, name) of a normalized id in the verified index, or nullptr.
        const Value* find_package(const Value& ix, const std::string& id)
        {
            const Value* packages = ix.get("packages");
            if (!packages || !packages->is_arr()) return nullptr;
            for (const auto& p : packages->items)
                if (!id.empty() && cat::modid::normalize(p.get("id")).id == id) return &p;
            return nullptr;
        }

        // One file a pair puts.
        struct File
        {
            Target target;
            std::string sha;
            size_t data = 0; // index into Pair::blobs
        };
        struct Pair
        {
            Item item;
            std::string owner;    // the index name
            std::string mod_name; // Mods/<Name> in the zip ("" for a pak-only zip)
            std::vector<File> files;
            std::vector<std::vector<uint8_t>> blobs;
            std::vector<Op> deletes;
            uint64_t bytes = 0;
            fs::path zip_file; // downloads/<sha256>.zip
        };

        // ------------------------------------------------------------ the mapping (step 4)
        std::optional<Fail> map_entries(std::vector<zip::Entry>& entries, Pair& pr)
        {
            if (entries.empty()) return Fail{"bad-layout", "the zip holds no files"};
            std::vector<std::string> seen_targets;
            bool has_json = false;
            size_t json_at = 0;
            for (size_t k = 0; k < entries.size(); ++k)
            {
                auto& e = entries[k];
                const auto parts = split(e.name, '/');
                const std::string& leaf = parts.back();
                if (ieq(leaf, "UE4SS.dll") || ieq(leaf, "dwmapi.dll")) return Fail{"bad-layout", "the zip holds " + shown(e.name) + "; a mod zip never holds UE4SS"};
                auto fixed = [&](std::initializer_list<const char*> names) {
                    size_t i = 0;
                    for (const char* n : names)
                    {
                        if (i >= parts.size() || !ieq(parts[i], n)) return false;
                        ++i;
                    }
                    return true;
                };
                std::string rel;
                for (size_t i = 0; i < parts.size(); ++i) rel += (i ? "\\" : "") + parts[i];
                Target t;
                std::string why;
                if (fixed({"NuclearNightmare", "Binaries", "Win64", "ue4ss", "Mods"}) && parts.size() >= 7)
                {
                    const std::string& name = parts[5];
                    if (!pr.mod_name.empty() && pr.mod_name != name) return Fail{"bad-layout", "the zip has more than one mod folder: " + shown(pr.mod_name) + ", " + shown(name)};
                    pr.mod_name = name;
                    if (parts.size() == 7 && (ieq(leaf, "settings.json") || ieq(leaf, "settings.json.bak"))) return Fail{"bad-layout", "the zip holds " + shown(e.name) + "; a mod zip never holds the player's settings"};
                    if (parts.size() == 7 && ieq(name, "ModManager") && (ieq(leaf, "state.json") || ieq(leaf, "state.json.mm-bak"))) return Fail{"bad-layout", "the zip holds " + shown(e.name) + "; a mod zip never holds the player's state"};
                    if (parts.size() == 7 && ieq(leaf, "mod.json"))
                    {
                        has_json = true;
                        json_at = k;
                    }
                }
                else if (fixed({"NuclearNightmare", "Content", "Paks", "LogicMods"}) && parts.size() == 5 && ends_i(leaf, ".pak"))
                {
                    if (!ieq(leaf.substr(0, leaf.size() - 4), pr.owner)) return Fail{"name-mismatch", "the zip's " + shown(e.name) + " is not named after the index name " + pr.owner};
                }
                else if (fixed({"NuclearNightmare", "Content", "Paks"}) && parts.size() == 4 && ends_i(leaf, "_P.pak"))
                {
                    if (!ieq(leaf.substr(0, leaf.size() - 6), pr.owner)) return Fail{"name-mismatch", "the zip's " + shown(e.name) + " is not named after the index name " + pr.owner};
                }
                else
                {
                    return Fail{"bad-layout", "the zip holds " + shown(e.name) + ", which is not under ue4ss/Mods/<Name>/, Content/Paks/LogicMods/<Name>.pak or Content/Paks/<Name>_P.pak"};
                }
                if (!parse_target(rel, t, why)) return Fail{"bad-layout", "the zip's " + shown(e.name) + " is not an allowed target: " + why};
                for (const auto& s : seen_targets)
                    if (ieq(s, rel)) return Fail{"bad-zip", "the zip holds " + shown(e.name) + " twice"};
                seen_targets.push_back(rel);
                File f;
                f.target = t;
                f.sha = sha_of(e.data);
                if (f.sha.empty()) return Fail{"error", "SHA-256 is not available"};
                f.data = pr.blobs.size();
                pr.bytes += e.data.size();
                pr.blobs.push_back(std::move(e.data));
                pr.files.push_back(std::move(f));
            }
            if (!pr.mod_name.empty())
            {
                if (!ieq(pr.mod_name, pr.owner)) return Fail{"name-mismatch", "the zip's mod folder " + shown(pr.mod_name) + " is not the index name " + pr.owner};
                if (!has_json) return Fail{"bad-layout", "the zip has no ue4ss/Mods/" + shown(pr.mod_name) + "/mod.json"};
                // The zip's mod.json: the pair's id.
                const auto& bytes = pr.blobs[pr.files[json_at].data];
                if (bytes.size() > k_max_mod_json) return Fail{"id-mismatch", "the zip's mod.json is over 64 KiB"};
                Value j;
                std::string err;
                if (!cat::json::parse(std::string_view{reinterpret_cast<const char*>(bytes.data()), bytes.size()}, j, err, 16) || !j.is_obj())
                    return Fail{"id-mismatch", "the zip's mod.json is not a JSON object"};
                const auto n = cat::modid::normalize(j.get("id"));
                if (!n.error.empty()) return Fail{"id-mismatch", "the zip's mod.json has no valid id (" + n.error + ")"};
                if (n.id != pr.item.id) return Fail{"id-mismatch", "the zip's mod.json is " + n.id + ", not " + pr.item.id};
            }
            return std::nullopt;
        }

        // ------------------------------------------------------------ the mod.json on disk
        // Mods/<Name>/mod.json on disk: found false when there is none. Fail when it can't be read or isn't an object;
        // id is "" when it holds no valid id, version "" when it holds no string version.
        struct OnDisk
        {
            bool found = false;
            std::string id, version;
        };
        std::optional<Fail> read_on_disk(const Layout& l, const std::string& name, OnDisk& out)
        {
            const std::wstring path = l.mods + L"\\" + widen(name) + L"\\mod.json";
            if (!file_exists(path)) return std::nullopt;
            std::string text;
            DWORD e = 0;
            if (!read_file(path, k_max_mod_json, text, &e))
            {
                if (e == ERROR_SHARING_VIOLATION || e == ERROR_LOCK_VIOLATION) return Fail{"error", "Mods/" + name + "/mod.json could not be read"};
                return Fail{"folder-in-use", "Mods/" + name + "/mod.json on disk is not a mod.json this can read (over 64 KiB?)"};
            }
            Value j;
            std::string err;
            if (!cat::json::parse(text, j, err, 16) || !j.is_obj()) return Fail{"folder-in-use", "Mods/" + name + "/mod.json on disk is not a JSON object"};
            out.found = true;
            const auto n = cat::modid::normalize(j.get("id"));
            if (n.error.empty()) out.id = n.id;
            const Value* v = j.get("version");
            if (v && v->is_str()) out.version = v->s;
            return std::nullopt;
        }

        // ------------------------------------------------------------ the folder on disk (step 7)
        // installed: the version on disk when the folder holds this id with a semver version (an update), else "".
        // A newer version on disk is a downgrade, allowed only away from a revoked installed version (story 6: the
        // native's own verified revoked list decides, never Lua).
        std::optional<Fail> check_folder(const Layout& l, const Value& ix, const Value* rv, const Pair& pr, std::string& installed, std::vector<std::string>& details)
        {
            installed.clear();
            if (pr.mod_name.empty()) return std::nullopt;
            OnDisk d;
            if (auto f = read_on_disk(l, pr.mod_name, d)) return f;
            if (!d.found) return std::nullopt;
            if (d.id != pr.item.id) return Fail{"folder-in-use", "Mods/" + pr.mod_name + "/ holds " + (!d.id.empty() ? d.id : std::string{"a mod without a valid id"}) + ", not " + pr.item.id};
            if (cat::is_semver(d.version)) installed = d.version;
            if (!d.version.empty() && semver_compare(d.version, pr.item.version) == 1)
            {
                const Value* hit = (rv && cat::is_semver(d.version)) ? cat::find_revoked_installed(ix, *rv, pr.item.id, d.version) : nullptr;
                if (!hit) return Fail{"downgrade", "Mods/" + pr.mod_name + "/ holds " + shown(d.version) + ", newer than " + pr.item.version};
                details.push_back("downgrade allowed: the installed " + pr.item.id + " " + d.version + " is revoked");
            }
            return std::nullopt;
        }

        bool is_player_data(const Target& t)
        {
            if (t.kind != TargetKind::ModFile) return false;
            const auto parts = split(t.rel, '\\');
            if (parts.size() != 7) return false;
            const std::string& leaf = parts.back();
            if (ieq(leaf, "settings.json") || ieq(leaf, "settings.json.bak")) return true;
            return ieq(parts[5], "ModManager") && (ieq(leaf, "state.json") || ieq(leaf, "state.json.mm-bak"));
        }

        // ------------------------------------------------------------ the verified release zip (steps 2-3)
        // Downloads (id, version) through story 2 (reusing a still-valid downloads/<sha256>.zip), checks the bytes
        // against the index again and reads the zip. rv nullptr: the revoked list isn't consulted (story 6's list-only
        // download of an installed version, whose bytes are only read, never staged). fresh: zips this call downloaded
        // (removed on a refusal); used: the file, for the cleanup after a stage.
        std::optional<Fail> fetch_zip(const Value& ix, const Value* rv, const std::string& id, const std::string& version, const fs::path& downloads, cat::fetch::Transport& t,
                                      const fs::path& state_file, const std::atomic<bool>& cancel, std::vector<fs::path>& fresh, std::vector<std::string>& details,
                                      std::vector<zip::Entry>& entries, fs::path& used)
        {
            const std::string what = id + " " + version;
            std::string reason;
            const auto plan = cat::fetch::plan_download(ix, rv, id, version, downloads, reason);
            if (!plan)
            {
                const std::string code = reason == "too large" ? "too-large" : reason == "downloads folder full" ? "downloads-full" : reason == "not in the catalog" ? "not-in-catalog" : "error";
                return Fail{code, what + ": " + reason};
            }
            if (!plan->revoked.empty()) return Fail{"revoked", plan->revoked};
            cat::Verifier v;
            fs::path file;
            {
                std::error_code ec;
                const fs::path expect = downloads / cat::widen(plan->sha256 + ".zip");
                if (!fs::exists(expect, ec)) fresh.push_back(expect);
            }
            try
            {
                file = cat::fetch::download_with_state(v, t, *plan, downloads, state_file, cancel);
            }
            catch (const cat::Reject& r)
            {
                for (auto& d : v.details) details.push_back(d);
                return Fail{r.code, r.message};
            }
            catch (const cat::Unreachable& u)
            {
                for (auto& d : v.details) details.push_back(d);
                return Fail{"unreachable", u.message};
            }
            for (auto& d : v.details) details.push_back(d);
            used = file;
            std::vector<uint8_t> zbytes;
            bool too_big = false;
            if (!cat::read_file(file, plan->size, zbytes, &too_big)) return Fail{too_big ? "size-mismatch" : "error", what + ": the downloaded file could not be read back"};
            if (zbytes.size() != plan->size) return Fail{"size-mismatch", what + ": the downloaded file is " + std::to_string(zbytes.size()) + " bytes; the index says " + std::to_string(plan->size)};
            if (sha_of(zbytes) != plan->sha256) return Fail{"hash-mismatch", what + ": the downloaded file's SHA-256 is not the index's"};
            zip::Error zerr;
            if (!zip::read(zbytes.data(), zbytes.size(), entries, zerr)) return Fail{zerr.code, what + ": " + zerr.message};
            return std::nullopt;
        }

        // ------------------------------------------------------------ the files of the installed version (story 6)
        struct Owned
        {
            std::vector<Op> deletes; // one per owned file: delete <Name> <sha256> <target>
            size_t listed = 0, kept = 0, missing = 0;
            std::string from; // "installed.txt" | "release zip"
        };
        struct OwnedArgs
        {
            const Layout& l;
            const Value& ix;
            const fs::path& downloads;
            cat::fetch::Transport& t;
            const fs::path& state_file;
            const std::atomic<bool>& cancel;
            std::vector<fs::path>& fresh;
            std::vector<fs::path>& used;
            std::vector<std::string>& details;
        };
        // For owner <Name> (the index name of id): installed.txt's records when it has any (target and recorded
        // SHA-256); otherwise the installed (id, version)'s release named by the verified index, for any game build,
        // downloaded and verified through story 2 even when revoked (only read), mapped with the install mapping (each
        // target with its zip entry's hash); otherwise not-in-catalog. A listed file is owned only when it is on disk
        // with that hash; another hash is kept (counted), a missing file skipped. Player data is never listed.
        std::optional<Fail> owned_files(const OwnedArgs& a, const std::string& id, const std::string& version, const std::string& owner, Owned& out)
        {
            std::vector<std::pair<Target, std::string>> listed;
            const std::wstring ipath = a.l.data + L"\\installed.txt";
            if (file_exists(ipath))
            {
                std::string text;
                std::vector<Installed> list;
                if (!read_file(ipath, k_max_installed_bytes, text) || !parse_installed(text, list)) return Fail{"error", "installed.txt could not be read"};
                for (const auto& rec : list)
                {
                    if (!ieq(rec.owner, owner)) continue;
                    Target tg;
                    std::string why;
                    if (!parse_target(rec.target, tg, why)) continue; // story 3 writes only valid targets
                    listed.emplace_back(tg, rec.sha256);
                }
                if (!listed.empty()) out.from = "installed.txt";
            }
            if (listed.empty())
            {
                if (version.empty() || !cat::find_version(a.ix, id, version)) return Fail{"not-in-catalog", id + " " + (version.empty() ? std::string{"(no version)"} : version) + ": the installed version is not in installed.txt nor in the catalog"};
                std::vector<zip::Entry> entries;
                fs::path file;
                if (auto f = fetch_zip(a.ix, nullptr, id, version, a.downloads, a.t, a.state_file, a.cancel, a.fresh, a.details, entries, file)) return f;
                a.used.push_back(file);
                Pair old;
                old.item = {id, version};
                old.owner = owner;
                if (auto f = map_entries(entries, old)) return Fail{f->outcome, id + " " + version + " (the installed release): " + f->message};
                for (const auto& f : old.files) listed.emplace_back(f.target, f.sha);
                out.from = "release zip";
            }
            for (const auto& [tg, sha] : listed)
            {
                if (is_player_data(tg)) continue;
                ++out.listed;
                const std::wstring abs = a.l.root + L"\\" + widen(tg.rel);
                if (!file_exists(abs))
                {
                    ++out.missing;
                    continue;
                }
                uint64_t size = 0;
                std::string got;
                if (!hash_file(abs, size, got))
                {
                    ++out.kept;
                    a.details.push_back("kept: " + tg.rel + " (could not be read to check its hash)");
                    continue;
                }
                if (got != sha)
                {
                    ++out.kept;
                    a.details.push_back("kept: " + tg.rel + " (not the installed version's file)");
                    continue;
                }
                Op op;
                op.kind = OpKind::Delete;
                op.owner = owner;
                op.sha256 = sha;
                op.target = tg;
                out.deletes.push_back(std::move(op));
            }
            return std::nullopt;
        }

        // ------------------------------------------------------------ writing (under the lock)
        struct Lock
        {
            HANDLE h = INVALID_HANDLE_VALUE;
            ~Lock()
            {
                if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
            }
        };

        DWORD write_bytes(const std::wstring& path, const std::vector<uint8_t>& data)
        {
            const HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (f == INVALID_HANDLE_VALUE) return GetLastError();
            DWORD e = 0;
            size_t off = 0;
            while (!e && off < data.size())
            {
                const DWORD chunk = static_cast<DWORD>(std::min<size_t>(data.size() - off, 1u << 20));
                DWORD w = 0;
                if (!WriteFile(f, data.data() + off, chunk, &w, nullptr) || w != chunk) e = GetLastError() ? GetLastError() : ERROR_WRITE_FAULT;
                off += chunk;
            }
            if (!e && !FlushFileBuffers(f)) e = GetLastError();
            CloseHandle(f);
            if (e) DeleteFileW(path.c_str());
            return e;
        }

        std::string ops_word(size_t n) { return std::to_string(n) + (n == 1 ? " operation" : " operations"); }

        // ------------------------------------------------------------ the write (under the lock), shared by stage and unstage
        // Takes apply.lock, re-checks the journal, merges: every operation of an owner (or modstxt name) in drop is
        // removed from the existing plan, add is appended, the result checked by story 3's parser; writes the staged
        // files blobs names (sha -> bytes) as <sha>.tmp then renamed (reusing a right file), then plan.txt atomically;
        // then removes staged files no operation references and the used downloads. On failure nothing changes.
        struct Commit
        {
            std::string txn;
            size_t ops = 0;
        };
        std::optional<Fail> commit(const Layout& l, const std::vector<std::string>& drop, const std::vector<Op>& add,
                                   const std::map<std::string, const std::vector<uint8_t>*>& blobs, const std::vector<fs::path>& used, const std::atomic<bool>& cancel,
                                   std::vector<std::string>& details, Commit& done)
        {
            if (!make_dirs(l.data)) return Fail{"error", "the data folder could not be created"};
            Lock lock;
            lock.h = CreateFileW((l.data + L"\\apply.lock").c_str(), GENERIC_READ | GENERIC_WRITE | DELETE, 0, nullptr, OPEN_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
            if (lock.h == INVALID_HANDLE_VALUE) return Fail{"applying", "a staged change is being applied (apply.lock is held)"};
            // Again under the lock: an apply cut short while the downloads ran is rolled back first; nothing is written.
            if (journal_interrupted(l)) return Fail{"interrupted", "an apply was cut short (found under apply.lock); it is rolled back first"};
            const std::wstring staged = l.data + L"\\staged";
            const std::wstring files_dir = staged + L"\\files";
            const std::wstring plan_path = staged + L"\\plan.txt";

            // The existing plan, merged by owner.
            Plan merged;
            if (file_exists(plan_path))
            {
                std::string text, why, bad;
                if (!read_file(plan_path, k_max_plan_bytes, text) || !parse_plan(text, merged, why, bad)) return Fail{"error", "the staged plan could not be read (" + (why.empty() ? std::string{"unreadable"} : why) + ")"};
            }
            auto dropped = [&](const std::string& n) {
                for (const auto& d : drop)
                    if (ieq(d, n)) return true;
                return false;
            };
            std::vector<Op> kept;
            for (auto& op : merged.ops)
                if (!dropped(op.kind == OpKind::ModsTxt ? op.name : op.owner)) kept.push_back(std::move(op));
            merged.ops = std::move(kept);
            for (const auto& op : add) merged.ops.push_back(op);
            merged.txn = new_txn();
            if (merged.txn.empty()) return Fail{"error", "no random txn"};
            const std::string plan_text = serialize_plan(merged);
            {
                Plan check;
                std::string why, bad;
                if (!parse_plan(plan_text, check, why, bad))
                {
                    // twice first: its message names a line number, which may contain "1024"
                    const bool twice = why.find("two operations on one target") != std::string::npos || why.find("two modstxt") != std::string::npos;
                    const bool caps = why.find("1 MiB") != std::string::npos || why.find("512 MiB") != std::string::npos || why.find("1024") != std::string::npos;
                    return Fail{twice ? "folder-in-use" : caps ? "too-large" : "error", "the merged plan is refused: " + why + (bad.empty() ? "" : " (" + bad + ")")};
                }
            }

            // Staged files: <sha256>.tmp, renamed; a file already there with the right size and hash is reused.
            std::vector<std::wstring> created;
            auto undo = [&] {
                for (const auto& c : created) DeleteFileW(c.c_str());
                DeleteFileW((plan_path + L".tmp").c_str());
            };
            if (!make_dirs(files_dir)) return Fail{"error", "the staged folder could not be created"};
            for (const auto& [sha, data] : blobs)
            {
                const std::wstring final_path = files_dir + L"\\" + widen(sha);
                const bool existed = file_exists(final_path);
                if (existed)
                {
                    uint64_t size = 0;
                    std::string got;
                    if (hash_file(final_path, size, got) && size == data->size() && got == sha) continue;
                }
                const std::wstring tmp = final_path + L".tmp";
                if (DWORD e = write_bytes(tmp, *data))
                {
                    undo();
                    return Fail{"error", "a staged file could not be written (error " + std::to_string(e) + ")"};
                }
                if (!MoveFileExW(tmp.c_str(), final_path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                {
                    const DWORD e = GetLastError();
                    DeleteFileW(tmp.c_str());
                    undo();
                    return Fail{"error", "a staged file could not be renamed into place (error " + std::to_string(e) + ")"};
                }
                if (!existed) created.push_back(final_path);
            }
            if (cancel.load())
            {
                undo();
                return Fail{"error", "cancelled"};
            }
            if (DWORD e = write_atomic(plan_path, plan_text))
            {
                undo();
                return Fail{"error", "plan.txt could not be written (error " + std::to_string(e) + ")"};
            }

            // Cleanup: staged files no operation references, then the used downloads.
            {
                std::vector<std::wstring> referenced;
                for (const auto& op : merged.ops)
                    if (op.kind == OpKind::Put) referenced.push_back(widen(op.sha256));
                WIN32_FIND_DATAW fd{};
                const HANDLE h = FindFirstFileW((files_dir + L"\\*").c_str(), &fd);
                if (h != INVALID_HANDLE_VALUE)
                {
                    std::vector<std::wstring> gone;
                    do
                    {
                        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
                        const std::wstring n = fd.cFileName;
                        if (std::find(referenced.begin(), referenced.end(), n) == referenced.end()) gone.push_back(n);
                    } while (FindNextFileW(h, &fd));
                    FindClose(h);
                    for (const auto& n : gone)
                    {
                        DeleteFileW((files_dir + L"\\" + n).c_str());
                        details.push_back("removed: staged file " + narrow(n));
                    }
                }
                for (const auto& z : used)
                {
                    std::error_code ec;
                    fs::remove(z, ec);
                }
            }
            done.txn = merged.txn;
            done.ops = merged.ops.size();
            return std::nullopt;
        }
    } // namespace

    int semver_compare(const std::string& a, const std::string& b)
    {
        if (!cat::is_semver(a) || !cat::is_semver(b)) return 2;
        auto parts = [](const std::string& s, std::string& pre) {
            std::string core = s.substr(0, s.find_first_of("-+"));
            const size_t dash = s.find('-');
            const size_t plus = s.find('+');
            pre = (dash != std::string::npos && (plus == std::string::npos || dash < plus)) ? s.substr(dash + 1, (plus == std::string::npos ? s.size() : plus) - dash - 1) : "";
            return split(core, '.');
        };
        auto num_cmp = [](const std::string& x, const std::string& y) {
            if (x.size() != y.size()) return x.size() < y.size() ? -1 : 1;
            return x < y ? -1 : (x > y ? 1 : 0);
        };
        std::string pa, pb;
        const auto ca = parts(a, pa), cb = parts(b, pb);
        for (size_t i = 0; i < 3; ++i)
            if (const int c = num_cmp(ca[i], cb[i])) return c;
        if (pa.empty() || pb.empty()) return pa.empty() == pb.empty() ? 0 : (pa.empty() ? 1 : -1);
        const auto ia = split(pa, '.'), ib = split(pb, '.');
        for (size_t i = 0; i < std::min(ia.size(), ib.size()); ++i)
        {
            const bool na = !ia[i].empty() && ia[i].find_first_not_of("0123456789") == std::string::npos;
            const bool nb = !ib[i].empty() && ib[i].find_first_not_of("0123456789") == std::string::npos;
            int c = 0;
            if (na && nb) c = num_cmp(ia[i], ib[i]);
            else if (na != nb) c = na ? -1 : 1;
            else c = ia[i] < ib[i] ? -1 : (ia[i] > ib[i] ? 1 : 0);
            if (c) return c;
        }
        return ia.size() == ib.size() ? 0 : (ia.size() < ib.size() ? -1 : 1);
    }

    std::string blocked(const Layout& l)
    {
        switch (staged_state(l))
        {
        case StagedState::Applying: return "applying";
        case StagedState::Interrupted: return "interrupted";
        default: return {};
        }
    }

    Outcome run_stage(const Layout& l, const Value& ix, const Value* rv, const std::vector<Item>& items, cat::fetch::Transport& t, const fs::path& state_file,
                      const std::atomic<bool>& cancel, bool precheck)
    {
        Outcome out;
        std::string failed_id;
        std::vector<fs::path> fresh; // zips this run downloaded: removed again on a refusal
        auto refuse = [&](const std::string& code, const std::string& message) {
            for (const auto& z : fresh)
            {
                std::error_code ec;
                fs::remove(z, ec);
            }
            out.outcome = code;
            out.message = message;
            out.payload = failed_id.empty() ? std::string{"{\"failed\":null}"} : "{\"failed\":" + cat::json::quote(failed_id) + "}";
            return out;
        };
        try
        {
            if (items.empty() || items.size() > k_max_pairs) return refuse("error", "1 to 16 pairs");
            if (const std::string b = precheck ? blocked(l) : std::string{}; !b.empty()) return refuse(b, b == "applying" ? "a staged change is being applied" : "an apply was cut short; it is rolled back first");
            const fs::path downloads = fs::path{l.data} / L"downloads";
            std::vector<Pair> pairs;
            std::vector<fs::path> used; // every download read: removed after a stage
            uint64_t total = 0;
            for (const auto& item : items)
            {
                failed_id = item.id;
                const std::string what = item.id + " " + item.version;
                // 1. the index
                const Value* pkg = find_package(ix, item.id);
                const Value* entry = cat::find_version(ix, item.id, item.version);
                if (!pkg || !entry) return refuse("not-in-catalog", what + " is not in the catalog");
                const Value* kind = pkg->get("kind");
                if (!kind || !kind->is_str() || kind->s != "mod") return refuse("not-a-mod", what + " is not a mod");
                const Value* name = pkg->get("name");
                Pair pr;
                pr.item = item;
                if (!name || !name->is_str() || !is_name(name->s) || is_stock_mod(name->s)) return refuse("bad-layout", what + ": the index name is not a mod folder name");
                pr.owner = name->s;
                for (const auto& other : pairs)
                    if (ieq(other.owner, pr.owner)) return refuse("bad-layout", what + ": two pairs have the name " + pr.owner);
                // 2.-3. the download (story 2), the verified bytes, the zip
                std::vector<zip::Entry> entries;
                fs::path file;
                if (auto f = fetch_zip(ix, rv, item.id, item.version, downloads, t, state_file, cancel, fresh, out.details, entries, file)) return refuse(f->outcome, f->message);
                pr.zip_file = file;
                used.push_back(file);
                // 4.-6. the mapping, the zip's mod.json
                if (auto f = map_entries(entries, pr)) return refuse(f->outcome, what + ": " + f->message);
                entries.clear();
                total += pr.bytes;
                if (total > k_max_put_total) return refuse("too-large", what + ": the files are over 512 MiB in all");
                // 7. the folder on disk (story 6: a downgrade only away from a revoked installed version)
                std::string installed;
                if (auto f = check_folder(l, ix, rv, pr, installed, out.details)) return refuse(f->outcome, what + ": " + f->message);
                for (const auto& other : pairs)
                {
                    if (!pr.mod_name.empty() && ieq(other.mod_name, pr.mod_name)) return refuse("bad-layout", what + ": two pairs install the mod folder " + pr.mod_name);
                    for (const auto& f : pr.files)
                        for (const auto& g : other.files)
                            if (ieq(f.target.rel, g.target.rel)) return refuse("bad-layout", what + ": two pairs install " + f.target.rel);
                }
                // 8. (story 6) the files of the installed version that the new zip doesn't put get delete lines: from
                // installed.txt, else the installed version's verified release. An installed version the catalog no
                // longer lists (and installed.txt doesn't know) gets no deletes: the update still goes ahead.
                Owned owned;
                const OwnedArgs oa{l, ix, downloads, t, state_file, cancel, fresh, used, out.details};
                if (auto f = owned_files(oa, item.id, installed, pr.owner, owned))
                {
                    if (f->outcome != "not-in-catalog") return refuse(f->outcome, what + ": " + f->message);
                    if (!installed.empty()) out.details.push_back("update: the installed " + item.id + " " + installed + " is not in installed.txt nor in the catalog; no files of it are deleted");
                }
                for (auto& d : owned.deletes)
                {
                    bool put = false;
                    for (const auto& f : pr.files)
                        if (ieq(f.target.rel, d.target.rel)) put = true;
                    if (!put) pr.deletes.push_back(std::move(d));
                }
                if (!installed.empty() || !owned.from.empty())
                    out.details.push_back("update: " + item.id + " " + (installed.empty() ? std::string{"?"} : installed) + " -> " + item.version + ": " + std::to_string(owned.listed) +
                                          " files listed (" + (owned.from.empty() ? std::string{"none"} : owned.from) + "), " + std::to_string(owned.kept) + " kept, " +
                                          std::to_string(owned.missing) + " missing");
                out.details.push_back("pair: " + what + " (" + pr.owner + "): " + std::to_string(pr.files.size()) + " files, " + std::to_string(pr.bytes) + " bytes, " +
                                      std::to_string(pr.deletes.size()) + " deletes");
                pairs.push_back(std::move(pr));
            }
            failed_id.clear();

            // ---- the write, under the lock
            std::vector<std::string> drop;
            std::vector<Op> add;
            std::map<std::string, const std::vector<uint8_t>*> blobs;
            for (const auto& pr : pairs)
            {
                drop.push_back(pr.owner);
                if (!pr.mod_name.empty()) drop.push_back(pr.mod_name);
                for (const auto& f : pr.files)
                {
                    Op op;
                    op.kind = OpKind::Put;
                    op.owner = pr.owner;
                    op.sha256 = f.sha;
                    op.size = pr.blobs[f.data].size();
                    op.target = f.target;
                    add.push_back(std::move(op));
                    blobs.emplace(f.sha, &pr.blobs[f.data]);
                }
                for (const auto& d : pr.deletes) add.push_back(d);
                if (!pr.mod_name.empty())
                {
                    Op op;
                    op.kind = OpKind::ModsTxt;
                    op.name = pr.mod_name;
                    op.on = true;
                    add.push_back(std::move(op));
                }
            }
            Commit done;
            if (auto f = commit(l, drop, add, blobs, used, cancel, out.details, done)) return refuse(f->outcome, f->message);

            out.outcome = "ok";
            Value owners = Value::array();
            for (const auto& pr : pairs)
            {
                Value o = Value::object();
                o.set("id", Value::string(pr.item.id));
                o.set("version", Value::string(pr.item.version));
                o.set("name", Value::string(pr.owner));
                o.set("files", Value::integer(static_cast<int64_t>(pr.files.size())));
                o.set("bytes", Value::integer(static_cast<int64_t>(pr.bytes)));
                owners.items.push_back(std::move(o));
            }
            Value p = Value::object();
            p.set("txn", Value::string(done.txn));
            p.set("owners", std::move(owners));
            p.set("ops", Value::integer(static_cast<int64_t>(done.ops)));
            out.payload = cat::json::write(p);
            out.message = std::to_string(pairs.size()) + (pairs.size() == 1 ? " mod" : " mods") + " staged; the plan has " + ops_word(done.ops) + ", txn " + done.txn;
            out.details.push_back("txn: " + done.txn);
            return out;
        }
        catch (const std::bad_alloc&)
        {
            return refuse("too-large", "not enough memory");
        }
        catch (const std::exception& e)
        {
            return refuse("error", std::string{"unexpected failure: "} + e.what());
        }
        catch (...)
        {
            return refuse("error", "unexpected failure");
        }
    }

    bool is_base_pack(const std::string& id)
    {
        std::string core = CORE_NAME;
        for (auto& c : core) c = (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
        return id == std::string{k_base_namespace} + "." + core || id == std::string{k_base_namespace} + ".mod-manager";
    }

    Outcome run_unstage(const Layout& l, const Value& ix, const Item& item, cat::fetch::Transport& t, const fs::path& state_file, const std::atomic<bool>& cancel,
                        bool precheck)
    {
        Outcome out;
        std::vector<fs::path> fresh;
        auto refuse = [&](const std::string& code, const std::string& message) {
            for (const auto& z : fresh)
            {
                std::error_code ec;
                fs::remove(z, ec);
            }
            out.outcome = code;
            out.message = message;
            out.payload = "{\"failed\":" + cat::json::quote(item.id) + "}";
            return out;
        };
        try
        {
            const std::string what = item.id + " " + item.version;
            if (is_base_pack(item.id)) return refuse("base-pack", what + ": the installer removes the base pack's mods");
            if (const std::string b = precheck ? blocked(l) : std::string{}; !b.empty()) return refuse(b, b == "applying" ? "a staged change is being applied" : "an apply was cut short; it is rolled back first");
            const Value* pkg = find_package(ix, item.id);
            if (!pkg) return refuse("not-in-catalog", what + ": the id is not in the catalog");
            const Value* name = pkg->get("name");
            if (!name || !name->is_str() || !is_name(name->s) || is_stock_mod(name->s)) return refuse("not-in-catalog", what + ": the index name is not a mod folder name");
            const std::string owner = name->s;
            OnDisk d;
            if (auto f = read_on_disk(l, owner, d)) return refuse(f->outcome == "folder-in-use" ? "not-installed" : f->outcome, what + ": " + f->message);
            if (!d.found || d.id != item.id) return refuse("not-installed", what + ": Mods/" + owner + "/mod.json " + (d.found ? "holds another id" : "is not there"));
            if (d.version != item.version) return refuse("changed", what + ": Mods/" + owner + "/ holds " + shown(d.version.empty() ? std::string{"no version"} : d.version));
            const fs::path downloads = fs::path{l.data} / L"downloads";
            std::vector<fs::path> used;
            Owned owned;
            const OwnedArgs oa{l, ix, downloads, t, state_file, cancel, fresh, used, out.details};
            if (auto f = owned_files(oa, item.id, item.version, owner, owned)) return refuse(f->outcome, f->message);
            out.details.push_back("unstage: " + what + " (" + owner + "): " + std::to_string(owned.listed) + " files listed (" + owned.from + "), " +
                                  std::to_string(owned.deletes.size()) + " deletes, " + std::to_string(owned.kept) + " kept, " + std::to_string(owned.missing) + " missing");
            std::vector<Op> add = owned.deletes;
            Op mt;
            mt.kind = OpKind::ModsTxt;
            mt.name = owner;
            mt.on = false;
            add.push_back(std::move(mt));
            Commit done;
            if (auto f = commit(l, {owner}, add, {}, used, cancel, out.details, done)) return refuse(f->outcome, f->message);
            out.outcome = "ok";
            Value o = Value::object();
            o.set("id", Value::string(item.id));
            o.set("version", Value::string(item.version));
            o.set("name", Value::string(owner));
            o.set("files", Value::integer(static_cast<int64_t>(owned.deletes.size())));
            o.set("kept", Value::integer(static_cast<int64_t>(owned.kept)));
            Value owners = Value::array();
            owners.items.push_back(std::move(o));
            Value p = Value::object();
            p.set("txn", Value::string(done.txn));
            p.set("owners", std::move(owners));
            p.set("ops", Value::integer(static_cast<int64_t>(done.ops)));
            out.payload = cat::json::write(p);
            out.message = owner + " removal staged (" + std::to_string(owned.deletes.size()) + " files, " + std::to_string(owned.kept) + " kept); the plan has " + ops_word(done.ops) +
                          ", txn " + done.txn;
            out.details.push_back("txn: " + done.txn);
            return out;
        }
        catch (const std::bad_alloc&)
        {
            return refuse("too-large", "not enough memory");
        }
        catch (const std::exception& e)
        {
            return refuse("error", std::string{"unexpected failure: "} + e.what());
        }
        catch (...)
        {
            return refuse("error", "unexpected failure");
        }
    }
} // namespace core_stage::install
