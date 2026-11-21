// Applying a staged change (apply.hpp has the files, the order and the outcomes).
#include "apply.hpp"

#include <tlhelp32.h>

#include <algorithm>
#include <optional>
#include <vector>

namespace core_stage
{
    namespace
    {
        constexpr int k_max_attempts = 3;
        constexpr size_t k_max_mods_txt = 262144; // Mod Manager's modstxt.lua MAX
        // The journal of a plan at its limits: 1024 operations, each at most a "saved\t<n>\t<target>" line plus up to 8
        // mkdir or rmdir lines naming a prefix of its target (each at most the target's ~1 KiB), so about 9 x 1 KiB x
        // 1024 = 9 MiB, plus the mods.txt and installed.txt lines. 16 MiB covers it with room.
        constexpr size_t k_max_journal = 16 * 1024 * 1024;

        // ------------------------------------------------------------ paths
        struct Paths
        {
            std::wstring staged, plan, files, attempts, lock, rollback, journal, backups, result, installed, failed, relaunch, mods_txt;
            std::string mods_txt_rel, installed_rel;
        };
        Paths paths_of(const Layout& l)
        {
            Paths p;
            p.staged = l.data + L"\\staged";
            p.plan = p.staged + L"\\plan.txt";
            p.files = p.staged + L"\\files";
            p.attempts = p.staged + L"\\attempts.txt";
            p.lock = l.data + L"\\apply.lock";
            p.rollback = l.data + L"\\rollback";
            p.journal = p.rollback + L"\\journal.txt";
            p.backups = p.rollback + L"\\files";
            p.result = l.data + L"\\apply-result.txt";
            p.installed = l.data + L"\\installed.txt";
            p.failed = l.data + L"\\failed";
            p.relaunch = l.data + L"\\relaunch.txt";
            p.mods_txt = l.mods + L"\\mods.txt";
            p.mods_txt_rel = "NuclearNightmare\\Binaries\\Win64\\ue4ss\\Mods\\mods.txt";
            p.installed_rel = "NuclearNightmare\\Binaries\\Win64\\ue4ss\\" + narrow(l.core_name) + "Data\\installed.txt";
            return p;
        }
        std::wstring abs_of(const Layout& l, const std::string& rel) { return l.root + L"\\" + widen(rel); }
        std::wstring parent(const std::wstring& p)
        {
            const auto i = p.find_last_of(L'\\');
            return i == std::wstring::npos ? std::wstring{} : p.substr(0, i);
        }
        std::string parent_rel(const std::string& p)
        {
            const auto i = p.find_last_of('\\');
            return i == std::string::npos ? std::string{} : p.substr(0, i);
        }
        size_t components(const std::string& rel) { return static_cast<size_t>(std::count(rel.begin(), rel.end(), '\\')) + 1; }

        bool is_locked_error(DWORD e)
        {
            return e == ERROR_SHARING_VIOLATION || e == ERROR_LOCK_VIOLATION || e == ERROR_ACCESS_DENIED || e == ERROR_USER_MAPPED_FILE;
        }

        // ------------------------------------------------------------ small file operations
        bool delete_tree(const std::wstring& dir)
        {
            const DWORD a = GetFileAttributesW(dir.c_str());
            if (a == INVALID_FILE_ATTRIBUTES) return true;
            if ((a & FILE_ATTRIBUTE_DIRECTORY) == 0 || (a & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            {
                if (a & FILE_ATTRIBUTE_DIRECTORY) return RemoveDirectoryW(dir.c_str()) != 0; // a junction: only the link
                return DeleteFileW(dir.c_str()) != 0;
            }
            WIN32_FIND_DATAW fd{};
            const HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
            bool ok = true;
            if (h != INVALID_HANDLE_VALUE)
            {
                do
                {
                    const std::wstring n = fd.cFileName;
                    if (n == L"." || n == L"..") continue;
                    if (!delete_tree(dir + L"\\" + n)) ok = false;
                } while (FindNextFileW(h, &fd));
                FindClose(h);
            }
            if (!RemoveDirectoryW(dir.c_str())) ok = false;
            return ok;
        }

        // Copies src to dst (created anew, flushed). When expect is set, the bytes copied must have that SHA-256 and
        // size. 0 or a Win32 code; ERROR_INVALID_DATA for a hash or size mismatch.
        DWORD copy_file(const std::wstring& src, const std::wstring& dst, const std::string& expect_sha = {}, uint64_t expect_size = 0)
        {
            const HANDLE in = CreateFileW(src.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                                          FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (in == INVALID_HANDLE_VALUE) return GetLastError();
            const HANDLE out = CreateFileW(dst.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (out == INVALID_HANDLE_VALUE)
            {
                const DWORD e = GetLastError();
                CloseHandle(in);
                return e;
            }
            Sha256 h;
            std::vector<unsigned char> buf(1 << 20);
            uint64_t total = 0;
            DWORD err = 0;
            while (true)
            {
                DWORD n = 0;
                if (!ReadFile(in, buf.data(), static_cast<DWORD>(buf.size()), &n, nullptr))
                {
                    err = GetLastError();
                    break;
                }
                if (n == 0) break;
                h.update(buf.data(), n);
                total += n;
                DWORD w = 0;
                if (!WriteFile(out, buf.data(), n, &w, nullptr) || w != n)
                {
                    err = GetLastError() ? GetLastError() : ERROR_WRITE_FAULT;
                    break;
                }
            }
            if (!err && !FlushFileBuffers(out)) err = GetLastError();
            CloseHandle(in);
            CloseHandle(out);
            if (!err && !expect_sha.empty() && (total != expect_size || h.hex() != expect_sha)) err = ERROR_INVALID_DATA;
            if (err) DeleteFileW(dst.c_str());
            return err;
        }

        // ------------------------------------------------------------ mods.txt (Mod Manager's Scripts/modstxt.lua)
        struct MtLine
        {
            std::string body, eol;
        };
        struct MtModel
        {
            bool bom = false;
            std::vector<MtLine> lines;
        };
        bool mt_parse(const std::string& text_in, MtModel& m)
        {
            if (text_in.size() > k_max_mods_txt) return false;
            std::string_view text = text_in;
            m = MtModel{};
            if (text.size() >= 3 && text.substr(0, 3) == "\xEF\xBB\xBF")
            {
                m.bom = true;
                text.remove_prefix(3);
            }
            size_t pos = 0;
            while (pos < text.size())
            {
                const size_t nl = text.find('\n', pos);
                if (nl == std::string_view::npos)
                {
                    std::string body{text.substr(pos)}, eol;
                    if (!body.empty() && body.back() == '\r')
                    {
                        body.pop_back();
                        eol = "\r";
                    }
                    m.lines.push_back({body, eol});
                    break;
                }
                std::string line{text.substr(pos, nl - pos)};
                std::string eol = "\n";
                if (!line.empty() && line.back() == '\r')
                {
                    line.pop_back();
                    eol = "\r\n";
                }
                m.lines.push_back({line, eol});
                pos = nl + 1;
            }
            return true;
        }
        // The name UE4SS reads from a line (exact case), or nothing when it skips the line.
        std::optional<std::string> mt_name(const std::string& body)
        {
            if (body.find(';') != std::string::npos || body.size() <= 4 || body.find(':') == std::string::npos) return std::nullopt;
            std::string s;
            for (char c : body)
                if (c != ' ') s.push_back(c);
            return s.substr(0, s.find(':'));
        }
        std::string mt_newline(const MtModel& m)
        {
            bool lf = false;
            for (const auto& l : m.lines)
            {
                if (l.eol == "\r\n") return "\r\n";
                if (l.eol == "\n") lf = true;
            }
            return lf ? "\n" : "\r\n";
        }
        bool mt_set_on(MtModel& m, const std::string& folder)
        {
            bool changed = false, found = false;
            for (auto& l : m.lines)
            {
                const auto n = mt_name(l.body);
                if (n && *n == folder)
                {
                    found = true;
                    const size_t last = l.body.find_last_of(':');
                    const std::string nb = l.body.substr(0, last + 1) + " 1";
                    if (nb != l.body)
                    {
                        l.body = nb;
                        changed = true;
                    }
                }
            }
            if (!found)
            {
                const std::string nl = mt_newline(m);
                size_t at = m.lines.size();
                bool keybinds = false;
                for (size_t i = 0; i < m.lines.size(); ++i)
                {
                    const auto n = mt_name(m.lines[i].body);
                    if (n && *n == "Keybinds")
                    {
                        at = i;
                        keybinds = true;
                        break;
                    }
                }
                MtLine line{folder + " : 1", nl};
                if (keybinds)
                {
                    m.lines.insert(m.lines.begin() + static_cast<ptrdiff_t>(at), line);
                }
                else
                {
                    if (!m.lines.empty() && m.lines.back().eol != "\n" && m.lines.back().eol != "\r\n")
                    {
                        m.lines.back().eol = nl;
                        line.eol = "";
                    }
                    m.lines.push_back(line);
                }
                changed = true;
            }
            return changed;
        }
        bool mt_remove(MtModel& m, const std::string& folder)
        {
            bool changed = false;
            std::vector<MtLine> kept;
            std::string last_eol;
            bool removed_last = false;
            for (size_t i = 0; i < m.lines.size(); ++i)
            {
                const auto n = mt_name(m.lines[i].body);
                if (n && *n == folder)
                {
                    changed = true;
                    if (i + 1 == m.lines.size())
                    {
                        removed_last = true;
                        last_eol = m.lines[i].eol;
                    }
                    continue;
                }
                kept.push_back(m.lines[i]);
            }
            // The file's last line keeps the file's trailing newline (or its absence).
            if (removed_last && !kept.empty() && last_eol != "\n" && last_eol != "\r\n") kept.back().eol = last_eol;
            m.lines = std::move(kept);
            return changed;
        }
        std::string mt_serialize(const MtModel& m)
        {
            std::string s = m.bom ? "\xEF\xBB\xBF" : "";
            for (const auto& l : m.lines) s += l.body + l.eol;
            return s;
        }

        // ------------------------------------------------------------ the journal
        class Journal
        {
          public:
            ~Journal() { close(); }
            DWORD open_new(const std::wstring& path)
            {
                close();
                m_h = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
                return m_h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
            }
            DWORD line(const std::string& s)
            {
                if (m_h == INVALID_HANDLE_VALUE) return ERROR_INVALID_HANDLE;
                const std::string b = s + "\n";
                DWORD w = 0;
                if (!WriteFile(m_h, b.data(), static_cast<DWORD>(b.size()), &w, nullptr) || w != b.size()) return GetLastError() ? GetLastError() : ERROR_WRITE_FAULT;
                if (!FlushFileBuffers(m_h)) return GetLastError();
                return 0;
            }
            void close()
            {
                if (m_h != INVALID_HANDLE_VALUE) CloseHandle(m_h);
                m_h = INVALID_HANDLE_VALUE;
            }

          private:
            HANDLE m_h = INVALID_HANDLE_VALUE;
        };

        std::vector<std::string> split_tabs(const std::string& s)
        {
            std::vector<std::string> out;
            size_t start = 0;
            while (true)
            {
                const size_t i = s.find('\t', start);
                if (i == std::string::npos)
                {
                    out.push_back(s.substr(start));
                    return out;
                }
                out.push_back(s.substr(start, i - start));
                start = i + 1;
            }
        }
        std::vector<std::string> text_lines(const std::string& text)
        {
            std::vector<std::string> out;
            size_t start = 0;
            while (start < text.size())
            {
                size_t nl = text.find('\n', start);
                if (nl == std::string::npos) nl = text.size();
                std::string l = text.substr(start, nl - start);
                if (!l.empty() && l.back() == '\r') l.pop_back();
                out.push_back(l);
                start = nl + 1;
            }
            return out;
        }

        struct JournalState
        {
            bool exists = false, valid = false, done = false;
            std::string txn;
            std::vector<std::vector<std::string>> steps; // each step's fields, in order
        };

        // A folder a journal may create or remove: Mods\<Name>\... (a non-stock name, components allowed) or LogicMods.
        bool journal_dir_ok(const std::string& rel)
        {
            Target t;
            std::string why;
            // A folder is allowed when a file inside it would be an allowed mod target.
            if (parse_target(rel + "\\x", t, why) && t.kind == TargetKind::ModFile) return true;
            if (parse_target(rel + "\\x.pak", t, why) && t.kind == TargetKind::LogicPak) return true;
            return false;
        }

        JournalState read_journal(const Layout& l, const Paths& p)
        {
            JournalState j;
            std::string text;
            if (!file_exists(p.journal)) return j;
            j.exists = true;
            if (!read_file(p.journal, k_max_journal, text)) return j;
            // Each line is written and flushed before its step acts: a last line without its newline was cut short,
            // and its step never began.
            const size_t end = text.find_last_of('\n');
            text.resize(end == std::string::npos ? 0 : end + 1);
            const auto lines = text_lines(text);
            if (lines.empty() || (lines.size() == 1 && lines[0] == "nucleus-journal\t1"))
            {
                j.txn = std::string(32, '0');
                j.valid = true; // cut short before its first step
                return j;
            }
            if (lines.size() < 2 || lines[0] != "nucleus-journal\t1") return j;
            const auto t = split_tabs(lines[1]);
            if (t.size() != 2 || t[0] != "txn" || !is_hex(t[1], 32)) return j;
            j.txn = t[1];
            const std::string helper_rel = narrow(l.helper.substr(l.root.size() + 1));
            for (size_t i = 2; i < lines.size(); ++i)
            {
                const auto f = split_tabs(lines[i]);
                if (f.size() == 1 && f[0] == "done")
                {
                    if (i + 1 != lines.size()) return j;
                    j.done = true;
                    break;
                }
                Target tg;
                std::string why;
                auto file_ok = [&](const std::string& rel) { return parse_target(rel, tg, why) || rel == p.mods_txt_rel || rel == p.installed_rel; };
                bool ok = false;
                if (f[0] == "saved" && f.size() == 3)
                {
                    ok = !f[1].empty() && f[1].size() <= 5 && f[1].find_first_not_of("0123456789") == std::string::npos && file_ok(f[2]);
                }
                else if (f[0] == "absent" && f.size() == 2)
                {
                    ok = file_ok(f[1]);
                }
                else if ((f[0] == "mkdir" || f[0] == "rmdir") && f.size() == 2)
                {
                    ok = journal_dir_ok(f[1]);
                }
                else if (f[0] == "moved" && f.size() == 3)
                {
                    // Without case: put() names the set-aside copy after the plan's target, whose case may differ.
                    const std::string bin = parent_rel(helper_rel) + "\\";
                    const std::string stem = narrow(l.core_name) + "Restart.";
                    ok = same_text_nocase(widen(f[1]), widen(helper_rel)) && f[2].size() == bin.size() + stem.size() + 36 &&
                         same_text_nocase(widen(f[2].substr(0, bin.size() + stem.size())), widen(bin + stem)) && is_hex(f[2].substr(bin.size() + stem.size(), 32), 32) && f[2].ends_with(".old");
                }
                if (!ok) return j;
                j.steps.push_back(f);
            }
            j.valid = true;
            return j;
        }

        // Puts every journaled step back, last first. false (why set) when a step could not be undone; the journal is
        // then kept, so the next helper tries again.
        bool rollback(const Layout& l, const Paths& p, const JournalState& j, std::string& why, std::string& path)
        {
            bool ok = true;
            for (auto it = j.steps.rbegin(); it != j.steps.rend(); ++it)
            {
                const auto& f = *it;
                if (f[0] == "saved")
                {
                    const std::wstring target = abs_of(l, f[2]);
                    const std::wstring backup = p.backups + L"\\" + widen(f[1]);
                    const std::wstring tmp = target + L"." + widen(j.txn) + L".rb";
                    DeleteFileW((target + L"." + widen(j.txn) + L".tmp").c_str());
                    // Already as it was (the step never changed it, e.g. a target held open): nothing to put back.
                    uint64_t bs = 0, ts = 0;
                    std::string bh, th;
                    if (hash_file(backup, bs, bh) && hash_file(target, ts, th) && bs == ts && bh == th) continue;
                    DWORD e = copy_file(backup, tmp);
                    if (!e && !MoveFileExW(tmp.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) e = GetLastError();
                    if (e)
                    {
                        DeleteFileW(tmp.c_str());
                        if (ok) why = is_locked_error(e) ? "locked" : "io-error", path = f[2];
                        ok = false;
                    }
                }
                else if (f[0] == "absent")
                {
                    const std::wstring target = abs_of(l, f[1]);
                    DeleteFileW((target + L"." + widen(j.txn) + L".tmp").c_str());
                    if (file_exists(target) && !DeleteFileW(target.c_str()))
                    {
                        const DWORD e = GetLastError();
                        if (ok) why = is_locked_error(e) ? "locked" : "io-error", path = f[1];
                        ok = false;
                    }
                }
                else if (f[0] == "mkdir")
                {
                    RemoveDirectoryW(abs_of(l, f[1]).c_str()); // only when empty; a folder we made and left empty goes
                }
                else if (f[0] == "rmdir")
                {
                    const std::wstring d = abs_of(l, f[1]);
                    if (!dir_exists(d) && !CreateDirectoryW(d.c_str(), nullptr))
                    {
                        if (ok) why = "io-error", path = f[1];
                        ok = false;
                    }
                }
                else if (f[0] == "moved")
                {
                    const std::wstring target = abs_of(l, f[1]);
                    const std::wstring old = abs_of(l, f[2]);
                    DeleteFileW((target + L"." + widen(j.txn) + L".tmp").c_str());
                    if (file_exists(old))
                    {
                        if (file_exists(target) && !DeleteFileW(target.c_str()))
                        {
                            // The new copy may be the running image (a later helper): renamed aside, deleted later.
                            const std::wstring aside = old.substr(0, old.size() - 4) + L".rb.old";
                            DeleteFileW(aside.c_str());
                            MoveFileExW(target.c_str(), aside.c_str(), MOVEFILE_WRITE_THROUGH);
                        }
                        if (!MoveFileExW(old.c_str(), target.c_str(), MOVEFILE_WRITE_THROUGH))
                        {
                            if (ok) why = "io-error", path = f[1];
                            ok = false;
                        }
                    }
                }
            }
            return ok;
        }

        // ------------------------------------------------------------ attempts
        uint64_t read_attempts(const Paths& p, const std::string& txn)
        {
            std::string text;
            if (!read_file(p.attempts, 256, text)) return 0;
            const auto lines = text_lines(text);
            if (lines.empty()) return 0;
            const auto f = split_tabs(lines[0]);
            if (f.size() != 2 || f[0] != txn || f[1].empty() || f[1].size() > 3 || f[1].find_first_not_of("0123456789") != std::string::npos) return 0;
            return std::stoull(f[1]);
        }

        // ------------------------------------------------------------ other games
        // A game exe (other than this process): an image directly in <root>\ (the launcher) or under
        // <root>\NuclearNightmare\Binaries\, except core's own bin\ (other helpers). Not <root>\Engine\: the crash
        // reporter a crashed game leaves open there holds none of the targets.
        bool game_running(const Layout& l)
        {
            const HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap == INVALID_HANDLE_VALUE) return false;
            PROCESSENTRY32W pe{};
            pe.dwSize = sizeof pe;
            bool found = false;
            const std::wstring root = l.root + L"\\";
            const std::wstring binaries = root + L"NuclearNightmare\\Binaries\\";
            const std::wstring bin = l.core_dir + L"\\bin\\";
            const DWORD self = GetCurrentProcessId();
            for (BOOL more = Process32FirstW(snap, &pe); more && !found; more = Process32NextW(snap, &pe))
            {
                if (pe.th32ProcessID == self || pe.th32ProcessID == 0) continue;
                const HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
                if (!h) continue;
                std::vector<wchar_t> buf(32768);
                DWORD n = static_cast<DWORD>(buf.size());
                if (QueryFullProcessImageNameW(h, 0, buf.data(), &n))
                {
                    const std::wstring img(buf.data(), n);
                    const bool in_root = starts_with_nocase(img, root) && img.find(L'\\', root.size()) == std::wstring::npos;
                    if ((in_root || starts_with_nocase(img, binaries)) && !starts_with_nocase(img, bin)) found = true;
                }
                CloseHandle(h);
            }
            CloseHandle(snap);
            return found;
        }

        // Every existing component from <root> down (not <root> itself) is a plain folder or file, never a reparse point.
        bool no_reparse(const Layout& l, const std::wstring& abs)
        {
            if (!starts_with_nocase(abs, l.root + L"\\")) return false;
            size_t pos = l.root.size() + 1;
            while (pos <= abs.size())
            {
                size_t next = abs.find(L'\\', pos);
                if (next == std::wstring::npos) next = abs.size();
                const std::wstring prefix = abs.substr(0, next);
                const DWORD a = GetFileAttributesW(prefix.c_str());
                if (a == INVALID_FILE_ATTRIBUTES) return true; // nothing further exists
                if (a & FILE_ATTRIBUTE_REPARSE_POINT) return false;
                pos = next + 1;
            }
            return true;
        }

        // ------------------------------------------------------------ the transaction
        struct Failure
        {
            std::string reason, path;
        };

        class Txn
        {
          public:
            Txn(const ApplyOptions& o, const Paths& p, const Plan& plan) : m_o(o), m_l(o.layout), m_p(p), m_plan(plan) {}

            // Applies every step. nullopt on success (journal "done" written).
            std::optional<Failure> run()
            {
                if (m_j.open_new(m_p.journal)) return Failure{"io-error", "-"};
                if (m_j.line("nucleus-journal\t1") || m_j.line("txn\t" + m_plan.txn)) return Failure{"io-error", "-"};
                for (const auto& op : m_plan.ops)
                {
                    std::optional<Failure> f;
                    if (op.kind == OpKind::Put) f = put(op);
                    else if (op.kind == OpKind::Delete) f = del(op);
                    if (f) return f;
                }
                if (auto f = mods_txt()) return f;
                if (auto f = installed()) return f;
                if (m_j.line("done")) return Failure{"io-error", "-"};
                m_j.close();
                return std::nullopt;
            }
            void close() { m_j.close(); }

          private:
            const ApplyOptions& m_o;
            const Layout& m_l;
            const Paths& m_p;
            const Plan& m_plan;
            Journal m_j;
            int m_steps = 0;
            int m_backups = 0;

            // Before each write: the test build's forced failure and interruption.
            std::optional<Failure> step(const std::string& rel)
            {
                if (m_o.crash_after >= 0 && m_steps >= m_o.crash_after) TerminateProcess(GetCurrentProcess(), 9);
                if (m_o.fail_after >= 0 && m_steps >= m_o.fail_after) return Failure{"io-error", rel};
                ++m_steps;
                return std::nullopt;
            }
            std::optional<Failure> io(DWORD e, const std::string& rel) { return Failure{is_locked_error(e) ? "locked" : "io-error", rel}; }

            // Creates the missing folders of a target (journaled, so a rollback removes them again).
            std::optional<Failure> folders(const std::string& rel)
            {
                std::vector<std::string> missing;
                for (std::string d = parent_rel(rel); !d.empty() && !dir_exists(abs_of(m_l, d)); d = parent_rel(d)) missing.push_back(d);
                for (auto it = missing.rbegin(); it != missing.rend(); ++it)
                {
                    if (!journal_dir_ok(*it)) return Failure{"io-error", *it}; // the layout's own folders must exist
                    if (m_j.line("mkdir\t" + *it)) return Failure{"io-error", *it};
                    if (!CreateDirectoryW(abs_of(m_l, *it).c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return io(GetLastError(), *it);
                }
                return std::nullopt;
            }

            // Journals what a write to rel replaces: a backup ("saved") or "absent".
            std::optional<Failure> save(const std::string& rel)
            {
                const std::wstring target = abs_of(m_l, rel);
                if (file_exists(target))
                {
                    const int n = ++m_backups;
                    if (DWORD e = copy_file(target, m_p.backups + L"\\" + std::to_wstring(n))) return io(e, rel);
                    if (m_j.line("saved\t" + std::to_string(n) + "\t" + rel)) return Failure{"io-error", rel};
                }
                else if (m_j.line("absent\t" + rel))
                {
                    return Failure{"io-error", rel};
                }
                return std::nullopt;
            }

            // tmp (already written) renamed over rel.
            std::optional<Failure> place(const std::wstring& tmp, const std::string& rel)
            {
                if (!MoveFileExW(tmp.c_str(), abs_of(m_l, rel).c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                {
                    const DWORD e = GetLastError();
                    DeleteFileW(tmp.c_str());
                    return io(e, rel);
                }
                return std::nullopt;
            }

            std::optional<Failure> put(const Op& op)
            {
                const std::string& rel = op.target.rel;
                if (auto f = step(rel)) return f;
                if (auto f = folders(rel)) return f;
                const std::wstring target = abs_of(m_l, rel);
                const std::wstring tmp = target + L"." + widen(m_plan.txn) + L".tmp";
                const bool self = !m_o.self_image.empty() && same_text_nocase(target, m_o.self_image);
                auto copy_in = [&]() -> std::optional<Failure> {
                    if (DWORD e = copy_file(m_p.files + L"\\" + widen(op.sha256), tmp, op.sha256, op.size))
                    {
                        if (e == ERROR_INVALID_DATA) return Failure{"staged-file-mismatch", rel};
                        return io(e, rel);
                    }
                    return std::nullopt;
                };
                if (self)
                {
                    // Self-update: the running image can be renamed, not replaced. The renamed copy is the backup. The
                    // new copy is written first, so the image is missing only between the two renames (a helper cut
                    // short there leaves no helper to recover it).
                    const std::string old_rel = parent_rel(rel) + "\\" + narrow(m_l.core_name) + "Restart." + m_plan.txn + ".old";
                    const std::wstring old = abs_of(m_l, old_rel);
                    if (auto f = copy_in()) return f;
                    DeleteFileW(old.c_str());
                    if (m_j.line("moved\t" + rel + "\t" + old_rel)) return Failure{"io-error", rel};
                    if (!MoveFileExW(target.c_str(), old.c_str(), MOVEFILE_WRITE_THROUGH)) return io(GetLastError(), rel);
                    return place(tmp, rel);
                }
                if (auto f = save(rel)) return f;
                if (auto f = copy_in()) return f;
                return place(tmp, rel);
            }

            std::optional<Failure> del(const Op& op)
            {
                const std::string& rel = op.target.rel;
                const std::wstring target = abs_of(m_l, rel);
                if (!file_exists(target)) return std::nullopt; // already gone
                if (auto f = step(rel)) return f;
                if (auto f = save(rel)) return f;
                if (!DeleteFileW(target.c_str())) return io(GetLastError(), rel);
                // Folders the delete left empty, up to (not including) Mods, LogicMods or Paks.
                for (std::string d = parent_rel(rel); components(d) > op.target.keep; d = parent_rel(d))
                {
                    const std::wstring ad = abs_of(m_l, d);
                    WIN32_FIND_DATAW fd{};
                    const HANDLE h = FindFirstFileW((ad + L"\\*").c_str(), &fd);
                    bool empty = true;
                    if (h != INVALID_HANDLE_VALUE)
                    {
                        do
                        {
                            const std::wstring n = fd.cFileName;
                            if (n != L"." && n != L"..") empty = false;
                        } while (empty && FindNextFileW(h, &fd));
                        FindClose(h);
                    }
                    if (!empty) break;
                    if (m_j.line("rmdir\t" + d)) return Failure{"io-error", d};
                    if (!RemoveDirectoryW(ad.c_str())) break; // left in place: harmless
                }
                return std::nullopt;
            }

            std::optional<Failure> mods_txt()
            {
                bool any = false;
                for (const auto& op : m_plan.ops)
                    if (op.kind == OpKind::ModsTxt) any = true;
                if (!any) return std::nullopt;
                const std::string& rel = m_p.mods_txt_rel;
                std::string text;
                DWORD err = 0;
                if (!read_file(m_p.mods_txt, k_max_mods_txt, text, &err)) return io(err ? err : ERROR_FILE_NOT_FOUND, rel);
                MtModel m;
                if (!mt_parse(text, m)) return Failure{"io-error", rel};
                bool changed = false;
                for (const auto& op : m_plan.ops)
                {
                    if (op.kind != OpKind::ModsTxt) continue;
                    if (op.on ? mt_set_on(m, op.name) : mt_remove(m, op.name)) changed = true;
                }
                if (!changed) return std::nullopt;
                const std::string out = mt_serialize(m);
                if (out.size() > k_max_mods_txt) return Failure{"io-error", rel};
                if (auto f = step(rel)) return f;
                if (auto f = save(rel)) return f;
                const std::wstring tmp = m_p.mods_txt + L"." + widen(m_plan.txn) + L".tmp";
                if (DWORD e = write_plain(tmp, out)) return io(e, rel);
                return place(tmp, rel);
            }

            std::optional<Failure> installed()
            {
                const std::string& rel = m_p.installed_rel;
                std::vector<Installed> list;
                std::string text;
                // An existing record that can't be read or parsed fails the apply: rewriting it from this plan alone
                // would lose every other mod's entries.
                if (file_exists(m_p.installed))
                {
                    DWORD err = 0;
                    if (!read_file(m_p.installed, k_max_installed_bytes, text, &err)) return io(err ? err : ERROR_INVALID_DATA, rel);
                    if (!parse_installed(text, list)) return Failure{"io-error", rel};
                }
                for (const auto& op : m_plan.ops)
                {
                    if (op.kind == OpKind::ModsTxt) continue;
                    const std::wstring t = widen(op.target.rel);
                    list.erase(std::remove_if(list.begin(), list.end(), [&](const Installed& e) { return same_text_nocase(widen(e.target), t); }), list.end());
                    if (op.kind == OpKind::Put) list.push_back({op.owner, op.sha256, op.target.rel});
                }
                if (list.size() > k_max_installed_entries) return Failure{"io-error", rel};
                if (auto f = step(rel)) return f;
                if (auto f = save(rel)) return f;
                const std::wstring tmp = m_p.installed + L"." + widen(m_plan.txn) + L".tmp";
                if (DWORD e = write_plain(tmp, serialize_installed(list))) return io(e, rel);
                return place(tmp, rel);
            }

          public:
            static DWORD write_plain(const std::wstring& path, const std::string& text)
            {
                const HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                if (f == INVALID_HANDLE_VALUE) return GetLastError();
                DWORD w = 0;
                DWORD e = 0;
                if (!text.empty() && (!WriteFile(f, text.data(), static_cast<DWORD>(text.size()), &w, nullptr) || w != text.size())) e = GetLastError() ? GetLastError() : ERROR_WRITE_FAULT;
                if (!e && !FlushFileBuffers(f)) e = GetLastError();
                CloseHandle(f);
                if (e) DeleteFileW(path.c_str());
                return e;
            }
        };

        // The lock: exclusive and delete-on-close, so a crash never leaves it held.
        HANDLE take_lock(const Paths& p)
        {
            return CreateFileW(p.lock.c_str(), GENERIC_READ | GENERIC_WRITE | DELETE, 0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
        }

        ApplyReport finish(const Paths& p, ResultFile r, const std::string& detail)
        {
            ApplyReport rep;
            rep.result = r;
            rep.detail = detail;
            rep.acted = write_atomic(p.result, serialize_result(r)) == 0;
            return rep;
        }

        // Moves staged\ to failed\ (the previous failed\ deleted first).
        void discard_staged(const Paths& p)
        {
            delete_tree(p.failed);
            if (!MoveFileExW(p.staged.c_str(), p.failed.c_str(), MOVEFILE_WRITE_THROUGH)) delete_tree(p.staged);
        }

        ApplyReport run_locked(const ApplyOptions& o, const Paths& p)
        {
            const Layout& l = o.layout;
            // Recovery: an apply that never reached "done" is put back before anything else.
            JournalState j = read_journal(l, p);
            if (j.exists && !j.done)
            {
                std::string why = "journal-bad", path;
                if (!j.valid || !rollback(l, p, j, why, path))
                {
                    ResultFile r{j.txn.empty() ? std::string(32, '0') : j.txn, "failed", "rollback-incomplete", path, 0};
                    return finish(p, r, "recovery failed: " + why);
                }
                delete_tree(p.rollback);
                j = JournalState{};
            }
            std::string text;
            if (!file_exists(p.plan)) return ApplyReport{false, {}, "nothing staged"};
            Plan plan;
            std::string why, bad;
            const bool read = read_file(p.plan, k_max_plan_bytes, text);
            const bool parsed = read && parse_plan(text, plan, why, bad);
            // An apply that reached "done" but whose plan was not cleared yet: finish clearing it.
            if (parsed && j.exists && j.done && j.txn == plan.txn)
            {
                delete_tree(p.staged);
                return finish(p, ResultFile{plan.txn, "applied", "", "", read_attempts(p, plan.txn) + 1}, "already applied");
            }
            std::string txn = plan.txn;
            if (!parsed)
            {
                // The txn line, when readable, names the result; otherwise zeros.
                txn = std::string(32, '0');
                const auto lines = text_lines(text);
                if (lines.size() >= 2)
                {
                    const auto f = split_tabs(lines[1]);
                    if (f.size() == 2 && f[0] == "txn" && is_hex(f[1], 32)) txn = f[1];
                }
                const uint64_t tries = read_attempts(p, txn); // before discard_staged moves attempts.txt away
                discard_staged(p);
                return finish(p, ResultFile{txn, "discarded", "bad-plan", bad, tries}, "bad plan: " + (read ? why : std::string{"unreadable"}));
            }
            const uint64_t attempts = read_attempts(p, txn);
            // Every target (and the data folder) free of reparse points from <root> down.
            for (const auto& op : plan.ops)
            {
                if (op.kind == OpKind::ModsTxt) continue;
                if (!no_reparse(l, abs_of(l, op.target.rel)))
                {
                    discard_staged(p);
                    return finish(p, ResultFile{txn, "discarded", "bad-plan", op.target.rel, attempts}, "reparse point on " + op.target.rel);
                }
            }
            if (!no_reparse(l, p.files) || !no_reparse(l, p.mods_txt) || !no_reparse(l, p.rollback))
            {
                discard_staged(p);
                return finish(p, ResultFile{txn, "discarded", "bad-plan", "", attempts}, "reparse point on the data folder or mods.txt");
            }
            // Every staged file as the plan says; every hashed delete's file as the plan says.
            for (const auto& op : plan.ops)
            {
                if (op.kind == OpKind::Put)
                {
                    uint64_t size = 0;
                    std::string sha;
                    if (!hash_file(p.files + L"\\" + widen(op.sha256), size, sha) || size != op.size || sha != op.sha256)
                    {
                        discard_staged(p);
                        return finish(p, ResultFile{txn, "discarded", "staged-file-mismatch", op.target.rel, attempts}, "staged file mismatch");
                    }
                }
            }
            std::optional<Failure> fail;
            for (const auto& op : plan.ops)
            {
                if (op.kind != OpKind::Delete || op.sha256.empty()) continue;
                const std::wstring t = abs_of(l, op.target.rel);
                if (!file_exists(t)) continue;
                uint64_t size = 0;
                std::string sha;
                DWORD e = 0;
                if (!hash_file(t, size, sha, &e))
                {
                    fail = Failure{is_locked_error(e) ? "locked" : "io-error", op.target.rel};
                    break;
                }
                if (sha != op.sha256)
                {
                    fail = Failure{"target-changed", op.target.rel};
                    break;
                }
            }
            std::string detail;
            if (!fail)
            {
                // The previous apply's rollback copies go now; this apply's journal starts.
                delete_tree(p.rollback);
                if (!make_dirs(p.backups)) fail = Failure{"io-error", "-"};
            }
            if (!fail)
            {
                Txn t(o, p, plan);
                fail = t.run();
                t.close();
                if (!fail)
                {
                    delete_tree(p.staged);
                    return finish(p, ResultFile{txn, "applied", "", "", attempts + 1}, "applied");
                }
                JournalState now = read_journal(l, p);
                std::string rwhy, rpath;
                if (!now.valid || !rollback(l, p, now, rwhy, rpath))
                {
                    const ResultFile r{txn, "failed", "rollback-incomplete", rpath.empty() ? fail->path : rpath, attempts + 1};
                    write_atomic(p.attempts, txn + "\t" + std::to_string(attempts + 1) + "\n");
                    return finish(p, r, "rollback incomplete after " + fail->reason);
                }
                delete_tree(p.rollback);
                detail = "rolled back after " + fail->reason;
            }
            const std::string fpath = fail->path == "-" ? std::string{} : fail->path;
            if (fail->reason == "staged-file-mismatch")
            {
                discard_staged(p);
                return finish(p, ResultFile{txn, "discarded", fail->reason, fpath, attempts}, detail);
            }
            const uint64_t n = attempts + 1;
            if (n >= k_max_attempts)
            {
                discard_staged(p);
                return finish(p, ResultFile{txn, "discarded", fail->reason, fpath, n}, detail + "; discarded after " + std::to_string(n) + " attempts");
            }
            write_atomic(p.attempts, txn + "\t" + std::to_string(n) + "\n");
            return finish(p, ResultFile{txn, "failed", fail->reason, fpath, n}, detail);
        }
    } // namespace

    // ---------------------------------------------------------------- public
    DWORD write_atomic(const std::wstring& path, const std::string& text)
    {
        const std::wstring tmp = path + L".tmp";
        if (DWORD e = Txn::write_plain(tmp, text)) return e;
        if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        {
            const DWORD e = GetLastError();
            DeleteFileW(tmp.c_str());
            return e;
        }
        return 0;
    }

    bool make_dirs(const std::wstring& path)
    {
        if (path.empty()) return false;
        if (dir_exists(path)) return true;
        const std::wstring up = parent(path);
        if (up.empty() || up == path) return false;
        if (up.size() > 2 && !make_dirs(up)) return false;
        return CreateDirectoryW(path.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
    }

    void delete_old_helpers(const std::wstring& bin_dir)
    {
        try
        {
            WIN32_FIND_DATAW fd{};
            const HANDLE h = FindFirstFileW((bin_dir + L"\\*.old").c_str(), &fd);
            if (h == INVALID_HANDLE_VALUE) return;
            std::vector<std::wstring> names;
            do
            {
                if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) names.emplace_back(fd.cFileName);
            } while (FindNextFileW(h, &fd));
            FindClose(h);
            for (const auto& n : names) DeleteFileW((bin_dir + L"\\" + n).c_str()); // fails (kept) while in use
        }
        catch (...)
        {
        }
    }

    ApplyReport run_apply(const ApplyOptions& o)
    {
        try
        {
            const Paths p = paths_of(o.layout);
            if (!dir_exists(o.layout.data)) return ApplyReport{false, {}, "no data folder"};
            // Other game processes under <root> first (not an attempt; the plan stays).
            const ULONGLONG until = GetTickCount64() + o.game_wait_ms;
            while (game_running(o.layout))
            {
                if (GetTickCount64() >= until)
                {
                    std::string txn;
                    size_t ops = 0;
                    if (!staged_summary(o.layout, txn, ops)) return ApplyReport{false, {}, "game running, nothing staged"};
                    const Paths pp = paths_of(o.layout);
                    return finish(pp, ResultFile{txn, "failed", "game-running", "", read_attempts(pp, txn)}, "game running");
                }
                Sleep(500);
            }
            const HANDLE lock = take_lock(p);
            if (lock == INVALID_HANDLE_VALUE) return ApplyReport{false, {}, "lock held"};
            ApplyReport r;
            try
            {
                r = run_locked(o, p);
            }
            catch (...)
            {
                r = ApplyReport{false, {}, "internal error"};
            }
            CloseHandle(lock);
            return r;
        }
        catch (...)
        {
            return ApplyReport{false, {}, "internal error"};
        }
    }

    bool plan_exists(const Layout& l) { return file_exists(paths_of(l).plan); }

    StagedState staged_state(const Layout& l)
    {
        const Paths p = paths_of(l);
        if (file_exists(p.lock))
        {
            const HANDLE h = CreateFileW(p.lock.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h == INVALID_HANDLE_VALUE)
            {
                const DWORD e = GetLastError();
                if (e == ERROR_SHARING_VIOLATION || e == ERROR_ACCESS_DENIED) return StagedState::Applying;
            }
            else
            {
                CloseHandle(h);
            }
        }
        const JournalState j = read_journal(l, p);
        if (j.exists && !j.done) return StagedState::Interrupted;
        if (file_exists(p.plan)) return StagedState::Pending;
        return StagedState::None;
    }

    bool staged_summary(const Layout& l, std::string& txn, size_t& ops)
    {
        txn.clear();
        ops = 0;
        std::string text, why, bad;
        Plan plan;
        if (!read_file(paths_of(l).plan, k_max_plan_bytes, text) || !parse_plan(text, plan, why, bad)) return false;
        txn = plan.txn;
        ops = plan.ops.size();
        return true;
    }

    bool read_result(const Layout& l, ResultFile& out)
    {
        std::string text;
        return read_file(paths_of(l).result, k_max_result_bytes, text) && parse_result(text, out);
    }

    bool delete_result(const Layout& l, DWORD* err)
    {
        if (DeleteFileW(paths_of(l).result.c_str())) return true;
        if (err) *err = GetLastError();
        return false;
    }

    DWORD write_relaunch(const Layout& l, DWORD game_pid, DWORD helper_pid)
    {
        if (!dir_exists(l.data) && !make_dirs(l.data)) return GetLastError() ? GetLastError() : ERROR_PATH_NOT_FOUND;
        return write_atomic(paths_of(l).relaunch, "nucleus-relaunch\t1\ngame\t" + std::to_string(game_pid) + "\nhelper\t" + std::to_string(helper_pid) + "\n");
    }

    bool take_relaunch(const Layout& l, DWORD game_pid, DWORD helper_pid)
    {
        const Paths p = paths_of(l);
        std::string text;
        const bool read = read_file(p.relaunch, 256, text);
        DeleteFileW(p.relaunch.c_str());
        if (!read || game_pid == 0) return false;
        return text == "nucleus-relaunch\t1\ngame\t" + std::to_string(game_pid) + "\nhelper\t" + std::to_string(helper_pid) + "\n";
    }
} // namespace core_stage
