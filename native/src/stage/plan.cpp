// Staged changes: plan, result, layout, targets, SHA-256 (plan.hpp has the formats and rules).
#include "plan.hpp"

#include <bcrypt.h>

#include <algorithm>
#include <charconv>

namespace core_stage
{
    namespace
    {
        bool ieq(char a, char b)
        {
            auto lo = [](char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; };
            return lo(a) == lo(b);
        }
        bool eq_nocase(std::string_view a, std::string_view b)
        {
            if (a.size() != b.size()) return false;
            for (size_t i = 0; i < a.size(); ++i)
                if (!ieq(a[i], b[i])) return false;
            return true;
        }
        bool ends_nocase(std::string_view s, std::string_view suffix)
        {
            return s.size() >= suffix.size() && eq_nocase(s.substr(s.size() - suffix.size()), suffix);
        }
        bool is_absolute(const std::wstring& p)
        {
            if (p.size() >= 3 && ((p[0] >= L'A' && p[0] <= L'Z') || (p[0] >= L'a' && p[0] <= L'z')) && p[1] == L':' && p[2] == L'\\') return true;
            return p.size() >= 3 && p[0] == L'\\' && p[1] == L'\\';
        }
        std::wstring parent(const std::wstring& p)
        {
            const auto i = p.find_last_of(L'\\');
            return i == std::wstring::npos ? std::wstring{} : p.substr(0, i);
        }
        std::wstring leaf(const std::wstring& p)
        {
            const auto i = p.find_last_of(L'\\');
            return i == std::wstring::npos ? p : p.substr(i + 1);
        }

        std::vector<std::string_view> split(std::string_view s, char sep)
        {
            std::vector<std::string_view> out;
            size_t start = 0;
            while (true)
            {
                const size_t i = s.find(sep, start);
                if (i == std::string_view::npos)
                {
                    out.push_back(s.substr(start));
                    return out;
                }
                out.push_back(s.substr(start, i - start));
                start = i + 1;
            }
        }

        // Lines of a text file: "\n" or "\r\n"; a final empty line (the text's trailing newline) is dropped. false on a
        // lone "\r", a NUL byte or a byte outside printable ASCII and tab.
        bool lines_of(std::string_view text, std::vector<std::string_view>& out)
        {
            out.clear();
            size_t start = 0;
            while (start < text.size())
            {
                size_t nl = text.find('\n', start);
                const bool last = nl == std::string_view::npos;
                if (last) nl = text.size();
                std::string_view line = text.substr(start, nl - start);
                if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
                for (char c : line)
                {
                    const auto u = static_cast<unsigned char>(c);
                    if (u != '\t' && (u < 0x20 || u > 0x7e)) return false;
                }
                out.push_back(line);
                start = last ? text.size() : nl + 1;
            }
            return true;
        }

        bool parse_u64(std::string_view s, uint64_t max, uint64_t& out)
        {
            if (s.empty() || s.size() > 19) return false;
            if (s.size() > 1 && s[0] == '0') return false;
            uint64_t v = 0;
            const auto r = std::from_chars(s.data(), s.data() + s.size(), v);
            if (r.ec != std::errc{} || r.ptr != s.data() + s.size() || v > max) return false;
            out = v;
            return true;
        }

        bool is_reserved_device(std::string_view comp)
        {
            std::string_view base = comp.substr(0, comp.find('.'));
            while (!base.empty() && base.back() == ' ') base.remove_suffix(1);
            for (const char* n : {"CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"})
                if (eq_nocase(base, n)) return true;
            if (base.size() == 4 && (eq_nocase(base.substr(0, 3), "COM") || eq_nocase(base.substr(0, 3), "LPT")) && base[3] >= '0' && base[3] <= '9')
                return true;
            return false;
        }
    } // namespace

    // ------------------------------------------------------------------ text
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
    bool same_text_nocase(std::wstring_view a, std::wstring_view b)
    {
        return CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(), static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
    }
    bool starts_with_nocase(std::wstring_view s, std::wstring_view prefix)
    {
        return s.size() >= prefix.size() && same_text_nocase(s.substr(0, prefix.size()), prefix);
    }

    // ------------------------------------------------------------------ layout
    bool layout_from_root(const std::wstring& root_in, const std::wstring& core_name, Layout& out)
    {
        std::wstring root = root_in;
        while (root.size() > 3 && root.back() == L'\\') root.pop_back();
        if (!is_absolute(root) || core_name.empty()) return false;
        if (root.back() == L'\\') root.pop_back(); // "C:\" -> "C:"
        out.root = root;
        out.ue4ss = root + L"\\NuclearNightmare\\Binaries\\Win64\\ue4ss";
        out.mods = out.ue4ss + L"\\Mods";
        out.core_dir = out.mods + L"\\" + core_name;
        out.data = out.ue4ss + L"\\" + core_name + L"Data";
        out.helper = out.core_dir + L"\\bin\\" + core_name + L"Restart.exe";
        out.core_name = core_name;
        return true;
    }

    bool layout_from_module(const std::wstring& module_path, const std::wstring& core_name, Layout& out)
    {
        if (!is_absolute(module_path)) return false;
        std::wstring p = parent(module_path); // ...\{bin|dlls}
        const std::wstring sub = leaf(p);
        if (!(same_text_nocase(sub, L"bin") || same_text_nocase(sub, L"dlls"))) return false;
        const wchar_t* expect[] = {nullptr, L"Mods", L"ue4ss", L"Win64", L"Binaries", L"NuclearNightmare"};
        p = parent(p); // <Core>
        if (!same_text_nocase(leaf(p), core_name)) return false;
        for (size_t i = 1; i < std::size(expect); ++i)
        {
            p = parent(p);
            if (p.empty() || !same_text_nocase(leaf(p), expect[i])) return false;
        }
        const std::wstring root = parent(p);
        if (root.empty()) return false;
        return layout_from_root(root.size() == 2 && root[1] == L':' ? root + L"\\" : root, core_name, out);
    }

    std::wstring module_file(HMODULE m)
    {
        std::vector<wchar_t> buf(MAX_PATH);
        while (buf.size() <= 32768)
        {
            const DWORD n = GetModuleFileNameW(m, buf.data(), static_cast<DWORD>(buf.size()));
            if (n == 0) return {};
            if (n < buf.size()) return std::wstring(buf.data(), n);
            buf.resize(buf.size() * 2);
        }
        return {};
    }

    // ------------------------------------------------------------------ names and targets
    bool is_name(std::string_view s)
    {
        if (s.empty() || s.size() > k_max_name) return false;
        if (!((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z'))) return false;
        for (char c : s)
        {
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
        }
        return true;
    }
    bool is_stock_mod(std::string_view s)
    {
        for (const char* m : k_stock_mods)
            if (eq_nocase(s, m)) return true;
        return false;
    }
    bool is_hex(std::string_view s, size_t len)
    {
        if (s.size() != len) return false;
        for (char c : s)
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }
    bool is_component(std::string_view s)
    {
        if (s.empty() || s.size() > k_max_component) return false;
        for (char c : s)
        {
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ' ' || c == '.' || c == '_' || c == '-')) return false;
        }
        if (s == "." || s == "..") return false;
        if (s.back() == '.' || s.back() == ' ') return false;
        return !is_reserved_device(s);
    }

    bool parse_target(std::string_view rel, Target& out, std::string& why)
    {
        out = Target{};
        out.rel = std::string{rel};
        if (rel.empty()) return why = "empty target", false;
        if (rel.size() > 1024) return why = "target too long", false;
        const auto parts = split(rel, '\\');
        for (auto c : parts)
            if (!is_component(c)) return why = "a target component is not allowed", false;
        auto fixed = [&](std::initializer_list<const char*> names) {
            size_t i = 0;
            for (const char* n : names)
            {
                if (i >= parts.size() || !eq_nocase(parts[i], n)) return false;
                ++i;
            }
            return true;
        };
        if (fixed({"NuclearNightmare", "Binaries", "Win64", "ue4ss", "Mods"}))
        {
            if (parts.size() < 7) return why = "a mod file needs a folder and a file", false;
            if (parts.size() - 6 > k_max_sub_components) return why = "too many components", false;
            const auto name = parts[5];
            if (!is_name(name)) return why = "not a mod folder name", false;
            if (is_stock_mod(name)) return why = "a stock UE4SS mod", false;
            // The Mod Manager's own state (its writer is the Mod Manager alone; Mod Manager v2 story 3's Never list).
            if (parts.size() == 7 && eq_nocase(name, "ModManager") && eq_nocase(parts[6], "state.json")) return why = "the Mod Manager's state.json", false;
            out.kind = TargetKind::ModFile;
            out.name = std::string{name};
            out.keep = 5;
            return true;
        }
        if (fixed({"NuclearNightmare", "Content", "Paks", "LogicMods"}))
        {
            if (parts.size() != 5 || !ends_nocase(parts[4], ".pak")) return why = "a LogicMods target is <Name>.pak", false;
            const auto name = parts[4].substr(0, parts[4].size() - 4);
            if (!is_name(name)) return why = "not a pak name", false;
            if (is_stock_mod(name)) return why = "a stock UE4SS mod", false;
            out.kind = TargetKind::LogicPak;
            out.name = std::string{name};
            out.keep = 4;
            return true;
        }
        if (fixed({"NuclearNightmare", "Content", "Paks"}))
        {
            if (parts.size() != 4 || !ends_nocase(parts[3], "_P.pak")) return why = "a base pak target is <Name>_P.pak", false;
            const auto name = parts[3].substr(0, parts[3].size() - 6);
            if (!is_name(name)) return why = "not a pak name", false;
            if (is_stock_mod(name)) return why = "a stock UE4SS mod", false;
            out.kind = TargetKind::BasePak;
            out.name = std::string{name};
            out.keep = 3;
            return true;
        }
        return why = "not an install-layout path", false;
    }

    // ------------------------------------------------------------------ the plan
    bool parse_plan(std::string_view text, Plan& out, std::string& why, std::string& bad_target)
    {
        out = Plan{};
        bad_target.clear();
        if (text.size() > k_max_plan_bytes) return why = "plan over 1 MiB", false;
        if (text.size() >= 3 && static_cast<unsigned char>(text[0]) == 0xEF) return why = "plan has a BOM", false;
        std::vector<std::string_view> lines;
        if (!lines_of(text, lines)) return why = "plan has a byte outside printable ASCII", false;
        if (lines.size() < 3) return why = "plan has no operation", false;
        if (lines[0] != "nucleus-plan\t1") return why = "not a version 1 plan", false;
        {
            const auto f = split(lines[1], '\t');
            if (f.size() != 2 || f[0] != "txn" || !is_hex(f[1], 32)) return why = "bad txn line", false;
            out.txn = std::string{f[1]};
        }
        if (lines.size() - 2 > k_max_ops) return why = "more than 1024 operations", false;
        uint64_t total = 0;
        std::vector<std::wstring> targets;
        std::vector<std::string> names;
        for (size_t i = 2; i < lines.size(); ++i)
        {
            const auto f = split(lines[i], '\t');
            Op op;
            const std::string where = " (line " + std::to_string(i + 1) + ")";
            if (f[0] == "put")
            {
                if (f.size() != 5) return why = "malformed put" + where, false;
                op.kind = OpKind::Put;
                if (!is_name(f[1])) return why = "bad owner" + where, false;
                if (!is_hex(f[2], 64)) return why = "bad sha256" + where, false;
                if (!parse_u64(f[3], k_max_put_total, op.size)) return why = "bad size" + where, false;
                total += op.size;
                if (total > k_max_put_total) return why = "put sizes over 512 MiB", false;
                op.owner = std::string{f[1]};
                op.sha256 = std::string{f[2]};
                std::string twhy;
                if (!parse_target(f[4], op.target, twhy)) return bad_target = std::string{f[4]}, why = twhy + where, false;
            }
            else if (f[0] == "delete")
            {
                if (f.size() != 4) return why = "malformed delete" + where, false;
                op.kind = OpKind::Delete;
                if (!is_name(f[1])) return why = "bad owner" + where, false;
                if (f[2] != "-" && !is_hex(f[2], 64)) return why = "bad sha256" + where, false;
                op.owner = std::string{f[1]};
                op.sha256 = f[2] == "-" ? std::string{} : std::string{f[2]};
                std::string twhy;
                if (!parse_target(f[3], op.target, twhy)) return bad_target = std::string{f[3]}, why = twhy + where, false;
            }
            else if (f[0] == "modstxt")
            {
                if (f.size() != 3) return why = "malformed modstxt" + where, false;
                op.kind = OpKind::ModsTxt;
                if (!is_name(f[1])) return why = "bad mod name" + where, false;
                if (is_stock_mod(f[1])) return why = "a stock UE4SS mod" + where, false;
                if (f[2] == "on") op.on = true;
                else if (f[2] == "remove") op.on = false;
                else return why = "modstxt is on or remove" + where, false;
                for (const auto& n : names)
                    if (eq_nocase(n, f[1])) return why = "two modstxt lines for one mod" + where, false;
                names.emplace_back(f[1]);
                op.name = std::string{f[1]};
            }
            else
            {
                return why = "unknown line" + where, false;
            }
            if (op.kind != OpKind::ModsTxt)
            {
                const std::wstring t = widen(op.target.rel);
                for (const auto& other : targets)
                    if (same_text_nocase(other, t)) return bad_target = op.target.rel, why = "two operations on one target" + where, false;
                targets.push_back(t);
            }
            out.ops.push_back(std::move(op));
        }
        return true;
    }

    std::string serialize_plan(const Plan& plan)
    {
        std::string s = "nucleus-plan\t1\ntxn\t" + plan.txn + "\n";
        for (const auto& op : plan.ops)
        {
            switch (op.kind)
            {
            case OpKind::Put:
                s += "put\t" + op.owner + "\t" + op.sha256 + "\t" + std::to_string(op.size) + "\t" + op.target.rel + "\n";
                break;
            case OpKind::Delete:
                s += "delete\t" + op.owner + "\t" + (op.sha256.empty() ? std::string{"-"} : op.sha256) + "\t" + op.target.rel + "\n";
                break;
            case OpKind::ModsTxt:
                s += "modstxt\t" + op.name + "\t" + (op.on ? "on" : "remove") + "\n";
                break;
            }
        }
        return s;
    }

    // ------------------------------------------------------------------ the result
    bool parse_result(std::string_view text, ResultFile& out)
    {
        out = ResultFile{};
        if (text.size() > k_max_result_bytes) return false;
        std::vector<std::string_view> lines;
        if (!lines_of(text, lines) || lines.size() != 6 || lines[0] != "nucleus-result\t1") return false;
        const char* keys[] = {"txn", "outcome", "reason", "path", "attempts"};
        std::string vals[5];
        for (size_t i = 0; i < 5; ++i)
        {
            const auto f = split(lines[i + 1], '\t');
            if (f.size() != 2 || f[0] != keys[i] || f[1].empty() || f[1].size() > 1024) return false;
            vals[i] = f[1] == "-" ? std::string{} : std::string{f[1]};
        }
        if (!is_hex(vals[0], 32)) return false;
        if (vals[1] != "applied" && vals[1] != "failed" && vals[1] != "discarded") return false;
        for (char c : vals[2])
            if (!((c >= 'a' && c <= 'z') || c == '-')) return false;
        if (!parse_u64(vals[4], 1000000, out.attempts)) return false;
        out.txn = vals[0];
        out.outcome = vals[1];
        out.reason = vals[2];
        out.path = vals[3];
        return true;
    }
    std::string serialize_result(const ResultFile& r)
    {
        auto v = [](const std::string& s) { return s.empty() ? std::string{"-"} : s; };
        return "nucleus-result\t1\ntxn\t" + r.txn + "\noutcome\t" + r.outcome + "\nreason\t" + v(r.reason) + "\npath\t" + v(r.path) + "\nattempts\t" +
               std::to_string(r.attempts) + "\n";
    }

    // ------------------------------------------------------------------ installed.txt
    bool parse_installed(std::string_view text, std::vector<Installed>& out)
    {
        out.clear();
        if (text.size() > k_max_installed_bytes) return false;
        std::vector<std::string_view> lines;
        if (!lines_of(text, lines) || lines.empty() || lines[0] != "nucleus-installed\t1") return false;
        if (lines.size() - 1 > k_max_installed_entries) return false;
        for (size_t i = 1; i < lines.size(); ++i)
        {
            const auto f = split(lines[i], '\t');
            Target t;
            std::string why;
            if (f.size() != 3 || !is_name(f[0]) || !is_hex(f[1], 64) || !parse_target(f[2], t, why)) return false;
            out.push_back({std::string{f[0]}, std::string{f[1]}, std::string{f[2]}});
        }
        return true;
    }
    std::string serialize_installed(const std::vector<Installed>& list)
    {
        std::string s = "nucleus-installed\t1\n";
        for (const auto& e : list) s += e.owner + "\t" + e.sha256 + "\t" + e.target + "\n";
        return s;
    }

    // ------------------------------------------------------------------ files
    bool read_file(const std::wstring& path, size_t max, std::string& out, DWORD* err)
    {
        out.clear();
        const HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                                     FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (f == INVALID_HANDLE_VALUE)
        {
            if (err) *err = GetLastError();
            return false;
        }
        LARGE_INTEGER size{};
        BY_HANDLE_FILE_INFORMATION info{};
        bool ok = GetFileSizeEx(f, &size) && GetFileInformationByHandle(f, &info) && (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0 &&
                  size.QuadPart >= 0 && static_cast<uint64_t>(size.QuadPart) <= max;
        if (ok)
        {
            out.resize(static_cast<size_t>(size.QuadPart));
            size_t got = 0;
            while (ok && got < out.size())
            {
                DWORD n = 0;
                const DWORD want = static_cast<DWORD>(std::min<size_t>(out.size() - got, 1 << 20));
                ok = ReadFile(f, out.data() + got, want, &n, nullptr) && n > 0;
                got += n;
            }
        }
        if (!ok && err) *err = GetLastError() ? GetLastError() : ERROR_INVALID_DATA;
        CloseHandle(f);
        if (!ok) out.clear();
        return ok;
    }
    bool file_exists(const std::wstring& path)
    {
        const DWORD a = GetFileAttributesW(path.c_str());
        return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0;
    }
    bool dir_exists(const std::wstring& path)
    {
        const DWORD a = GetFileAttributesW(path.c_str());
        return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
    }

    // ------------------------------------------------------------------ SHA-256
    Sha256::Sha256()
    {
        BCRYPT_ALG_HANDLE alg = nullptr;
        BCRYPT_HASH_HANDLE h = nullptr;
        if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return;
        if (BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) != 0)
        {
            BCryptCloseAlgorithmProvider(alg, 0);
            return;
        }
        m_alg = alg;
        m_hash = h;
        m_ok = true;
    }
    Sha256::~Sha256()
    {
        if (m_hash) BCryptDestroyHash(static_cast<BCRYPT_HASH_HANDLE>(m_hash));
        if (m_alg) BCryptCloseAlgorithmProvider(static_cast<BCRYPT_ALG_HANDLE>(m_alg), 0);
    }
    void Sha256::update(const void* p, size_t n)
    {
        const auto* b = static_cast<const unsigned char*>(p);
        while (m_ok && n > 0)
        {
            const ULONG chunk = static_cast<ULONG>(std::min<size_t>(n, 1u << 30));
            if (BCryptHashData(static_cast<BCRYPT_HASH_HANDLE>(m_hash), const_cast<PUCHAR>(b), chunk, 0) != 0) m_ok = false;
            b += chunk;
            n -= chunk;
        }
    }
    std::string Sha256::hex()
    {
        if (!m_ok) return {};
        unsigned char d[32];
        if (BCryptFinishHash(static_cast<BCRYPT_HASH_HANDLE>(m_hash), d, sizeof d, 0) != 0)
        {
            m_ok = false;
            return {};
        }
        m_ok = false; // finished
        static const char* k = "0123456789abcdef";
        std::string s;
        for (unsigned char c : d)
        {
            s.push_back(k[c >> 4]);
            s.push_back(k[c & 15]);
        }
        return s;
    }

    bool hash_file(const std::wstring& path, uint64_t& size, std::string& sha, DWORD* err)
    {
        size = 0;
        sha.clear();
        // Shared with writers too: a file another program holds open can still be checked (and a later copy re-hashes).
        const HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                                     FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (f == INVALID_HANDLE_VALUE)
        {
            if (err) *err = GetLastError();
            return false;
        }
        Sha256 h;
        std::vector<unsigned char> buf(1 << 20);
        bool ok = h.ok();
        BY_HANDLE_FILE_INFORMATION info{};
        if (ok && (!GetFileInformationByHandle(f, &info) || (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)) ok = false;
        while (ok)
        {
            DWORD n = 0;
            if (!ReadFile(f, buf.data(), static_cast<DWORD>(buf.size()), &n, nullptr))
            {
                ok = false;
                break;
            }
            if (n == 0) break;
            h.update(buf.data(), n);
            size += n;
        }
        if (ok) sha = h.hex();
        if (sha.empty()) ok = false;
        if (!ok && err) *err = GetLastError() ? GetLastError() : ERROR_INVALID_DATA;
        CloseHandle(f);
        return ok;
    }
} // namespace core_stage
