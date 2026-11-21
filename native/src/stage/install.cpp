// Staging installs from the verified catalog (install.hpp has the rules).
#include "install.hpp"

#include <bcrypt.h>

#include <algorithm>
#include <map>
#include <optional>

#include "../catalog/verify.hpp"
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

        // ------------------------------------------------------------ the folder on disk (step 7)
        std::optional<Fail> check_folder(const Layout& l, const Pair& pr)
        {
            if (pr.mod_name.empty()) return std::nullopt;
            const std::wstring path = l.mods + L"\\" + widen(pr.mod_name) + L"\\mod.json";
            if (!file_exists(path)) return std::nullopt;
            std::string text;
            DWORD e = 0;
            if (!read_file(path, k_max_mod_json, text, &e))
            {
                if (e == ERROR_SHARING_VIOLATION || e == ERROR_LOCK_VIOLATION) return Fail{"error", "Mods/" + pr.mod_name + "/mod.json could not be read"};
                return Fail{"folder-in-use", "Mods/" + pr.mod_name + "/mod.json on disk is not a mod.json this can read (over 64 KiB?)"};
            }
            Value j;
            std::string err;
            if (!cat::json::parse(text, j, err, 16) || !j.is_obj()) return Fail{"folder-in-use", "Mods/" + pr.mod_name + "/mod.json on disk is not a JSON object"};
            const auto n = cat::modid::normalize(j.get("id"));
            if (!n.error.empty() || n.id != pr.item.id) return Fail{"folder-in-use", "Mods/" + pr.mod_name + "/ holds " + (n.error.empty() ? n.id : std::string{"a mod without a valid id"}) + ", not " + pr.item.id};
            const Value* v = j.get("version");
            if (v && v->is_str() && semver_compare(v->s, pr.item.version) == 1)
                return Fail{"downgrade", "Mods/" + pr.mod_name + "/ holds " + shown(v->s) + ", newer than " + pr.item.version};
            return std::nullopt;
        }

        // ------------------------------------------------------------ installed.txt (step 8)
        std::optional<Fail> add_deletes(const Layout& l, Pair& pr)
        {
            const std::wstring path = l.data + L"\\installed.txt";
            if (!file_exists(path)) return std::nullopt;
            std::string text;
            std::vector<Installed> list;
            if (!read_file(path, k_max_installed_bytes, text) || !parse_installed(text, list)) return Fail{"error", "installed.txt could not be read"};
            for (const auto& rec : list)
            {
                if (!ieq(rec.owner, pr.owner)) continue;
                bool kept = false;
                for (const auto& f : pr.files)
                    if (ieq(f.target.rel, rec.target)) kept = true;
                if (kept) continue;
                Op op;
                op.kind = OpKind::Delete;
                op.owner = pr.owner;
                op.sha256 = rec.sha256;
                std::string why;
                if (!parse_target(rec.target, op.target, why)) continue; // story 3 writes only valid targets
                pr.deletes.push_back(std::move(op));
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
                // 2. the download (story 2), then the verified bytes in memory
                std::string reason;
                const auto plan = cat::fetch::plan_download(ix, rv, item.id, item.version, downloads, reason);
                if (!plan)
                {
                    const std::string code = reason == "too large" ? "too-large" : reason == "downloads folder full" ? "downloads-full" : reason == "not in the catalog" ? "not-in-catalog" : "error";
                    return refuse(code, what + ": " + reason);
                }
                if (!plan->revoked.empty()) return refuse("revoked", plan->revoked);
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
                    for (auto& d : v.details) out.details.push_back(d);
                    return refuse(r.code, r.message);
                }
                catch (const cat::Unreachable& u)
                {
                    for (auto& d : v.details) out.details.push_back(d);
                    return refuse("unreachable", u.message);
                }
                for (auto& d : v.details) out.details.push_back(d);
                pr.zip_file = file;
                std::vector<uint8_t> zbytes;
                bool too_big = false;
                if (!cat::read_file(file, plan->size, zbytes, &too_big)) return refuse(too_big ? "size-mismatch" : "error", what + ": the downloaded file could not be read back");
                if (zbytes.size() != plan->size) return refuse("size-mismatch", what + ": the downloaded file is " + std::to_string(zbytes.size()) + " bytes; the index says " + std::to_string(plan->size));
                if (sha_of(zbytes) != plan->sha256) return refuse("hash-mismatch", what + ": the downloaded file's SHA-256 is not the index's");
                // 3. the zip
                std::vector<zip::Entry> entries;
                zip::Error zerr;
                if (!zip::read(zbytes.data(), zbytes.size(), entries, zerr)) return refuse(zerr.code, what + ": " + zerr.message);
                zbytes = {};
                // 4.-6. the mapping, the zip's mod.json
                if (auto f = map_entries(entries, pr)) return refuse(f->outcome, what + ": " + f->message);
                total += pr.bytes;
                if (total > k_max_put_total) return refuse("too-large", what + ": the files are over 512 MiB in all");
                // 7. the folder on disk
                if (auto f = check_folder(l, pr)) return refuse(f->outcome, what + ": " + f->message);
                for (const auto& other : pairs)
                {
                    if (!pr.mod_name.empty() && ieq(other.mod_name, pr.mod_name)) return refuse("bad-layout", what + ": two pairs install the mod folder " + pr.mod_name);
                    for (const auto& f : pr.files)
                        for (const auto& g : other.files)
                            if (ieq(f.target.rel, g.target.rel)) return refuse("bad-layout", what + ": two pairs install " + f.target.rel);
                }
                // 8. installed.txt
                if (auto f = add_deletes(l, pr)) return refuse(f->outcome, what + ": " + f->message);
                out.details.push_back("pair: " + what + " (" + pr.owner + "): " + std::to_string(pr.files.size()) + " files, " + std::to_string(pr.bytes) + " bytes, " +
                                      std::to_string(pr.deletes.size()) + " deletes");
                pairs.push_back(std::move(pr));
            }
            failed_id.clear();

            // ---- the write, under the lock
            if (!make_dirs(l.data)) return refuse("error", "the data folder could not be created");
            Lock lock;
            lock.h = CreateFileW((l.data + L"\\apply.lock").c_str(), GENERIC_READ | GENERIC_WRITE | DELETE, 0, nullptr, OPEN_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
            if (lock.h == INVALID_HANDLE_VALUE) return refuse("applying", "a staged change is being applied (apply.lock is held)");
            // Again under the lock: an apply cut short while the downloads ran is rolled back first; nothing is written.
            if (journal_interrupted(l)) return refuse("interrupted", "an apply was cut short (found under apply.lock); it is rolled back first");
            const std::wstring staged = l.data + L"\\staged";
            const std::wstring files_dir = staged + L"\\files";
            const std::wstring plan_path = staged + L"\\plan.txt";

            // The existing plan, merged by owner.
            Plan merged;
            if (file_exists(plan_path))
            {
                std::string text, why, bad;
                if (!read_file(plan_path, k_max_plan_bytes, text) || !parse_plan(text, merged, why, bad)) return refuse("error", "the staged plan could not be read (" + (why.empty() ? std::string{"unreadable"} : why) + ")");
            }
            auto in_new = [&](const std::string& n) {
                for (const auto& pr : pairs)
                    if (ieq(pr.owner, n) || (!pr.mod_name.empty() && ieq(pr.mod_name, n))) return true;
                return false;
            };
            std::vector<Op> kept;
            for (auto& op : merged.ops)
                if (!in_new(op.kind == OpKind::ModsTxt ? op.name : op.owner)) kept.push_back(std::move(op));
            merged.ops = std::move(kept);
            for (const auto& pr : pairs)
            {
                for (const auto& f : pr.files)
                {
                    Op op;
                    op.kind = OpKind::Put;
                    op.owner = pr.owner;
                    op.sha256 = f.sha;
                    op.size = pr.blobs[f.data].size();
                    op.target = f.target;
                    merged.ops.push_back(std::move(op));
                }
                for (const auto& d : pr.deletes) merged.ops.push_back(d);
                if (!pr.mod_name.empty())
                {
                    Op op;
                    op.kind = OpKind::ModsTxt;
                    op.name = pr.mod_name;
                    op.on = true;
                    merged.ops.push_back(std::move(op));
                }
            }
            merged.txn = new_txn();
            if (merged.txn.empty()) return refuse("error", "no random txn");
            const std::string plan_text = serialize_plan(merged);
            {
                Plan check;
                std::string why, bad;
                if (!parse_plan(plan_text, check, why, bad))
                {
                    // twice first: its message names a line number, which may contain "1024"
                    const bool twice = why.find("two operations on one target") != std::string::npos || why.find("two modstxt") != std::string::npos;
                    const bool caps = why.find("1 MiB") != std::string::npos || why.find("512 MiB") != std::string::npos || why.find("1024") != std::string::npos;
                    return refuse(twice ? "folder-in-use" : caps ? "too-large" : "error", "the merged plan is refused: " + why + (bad.empty() ? "" : " (" + bad + ")"));
                }
            }

            // Staged files: <sha256>.tmp, renamed; a file already there with the right size and hash is reused.
            std::vector<std::wstring> created;
            auto undo = [&] {
                for (const auto& c : created) DeleteFileW(c.c_str());
                DeleteFileW((plan_path + L".tmp").c_str());
            };
            if (!make_dirs(files_dir)) return refuse("error", "the staged folder could not be created");
            std::map<std::string, std::pair<const Pair*, size_t>> unique;
            for (const auto& pr : pairs)
                for (const auto& f : pr.files) unique.emplace(f.sha, std::make_pair(&pr, f.data));
            for (const auto& [sha, src] : unique)
            {
                const auto& data = src.first->blobs[src.second];
                const std::wstring final_path = files_dir + L"\\" + widen(sha);
                const bool existed = file_exists(final_path);
                if (existed)
                {
                    uint64_t size = 0;
                    std::string got;
                    if (hash_file(final_path, size, got) && size == data.size() && got == sha) continue;
                }
                const std::wstring tmp = final_path + L".tmp";
                if (DWORD e = write_bytes(tmp, data))
                {
                    undo();
                    return refuse("error", "a staged file could not be written (error " + std::to_string(e) + ")");
                }
                if (!MoveFileExW(tmp.c_str(), final_path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                {
                    const DWORD e = GetLastError();
                    DeleteFileW(tmp.c_str());
                    undo();
                    return refuse("error", "a staged file could not be renamed into place (error " + std::to_string(e) + ")");
                }
                if (!existed) created.push_back(final_path);
            }
            if (cancel.load())
            {
                undo();
                return refuse("error", "cancelled");
            }
            if (DWORD e = write_atomic(plan_path, plan_text))
            {
                undo();
                return refuse("error", "plan.txt could not be written (error " + std::to_string(e) + ")");
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
                        out.details.push_back("removed: staged file " + narrow(n));
                    }
                }
                for (const auto& pr : pairs)
                {
                    std::error_code ec;
                    fs::remove(pr.zip_file, ec);
                }
            }

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
            p.set("txn", Value::string(merged.txn));
            p.set("owners", std::move(owners));
            p.set("ops", Value::integer(static_cast<int64_t>(merged.ops.size())));
            out.payload = cat::json::write(p);
            out.message = std::to_string(pairs.size()) + (pairs.size() == 1 ? " mod" : " mods") + " staged; the plan has " + ops_word(merged.ops.size()) + ", txn " + merged.txn;
            out.details.push_back("txn: " + merged.txn);
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
