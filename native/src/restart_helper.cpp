// <Core>Restart.exe, core's relaunch helper (Mod Manager story 8, core story 45; Mod Manager v2 story 3 adds apply mode;
// README "Restart" and "Staged changes").
//
// Core's DLL starts it from the running game. It waits for that exact game process to exit, then:
//   restart mode (<Core>_RestartStart, the game then quits): starts the game again the way it was launched
//     steam   ShellExecuteW(open, "steam://rungameid/2909110"): Steam starts the game with the player's launch options
//     direct  CreateProcessW(<exe>, <the game's original command line, byte for byte>, cwd): a dev copy (its -userdir)
//   apply mode (--apply; <Core>_ApplyStart, as soon as a change is staged): applies the staged change in
//     ue4ss\<Core>Data\staged\ (stage/apply.cpp: verify, lock, journal, backups, write, mods.txt, rollback on any
//     failure, apply-result.txt), then starts the game again only when ue4ss\<Core>Data\relaunch.txt names the game
//     process it waited on and this helper (Restart now pressed while it waited); it deletes that file either way. The
//     relaunch comes after the apply, whatever its outcome. --mode none (an unsupported launch) applies and never
//     relaunches.
//
// Command line (built by core's DLL from the game process itself; no Lua value ever reaches it):
//   "<helper>" --wait <handle> [--apply] --mode steam|direct[|none with --apply] --cwd "<dir>" --exe "<path>" -- <tail>
// <handle> is a SYNCHRONIZE handle to the game process (in apply mode also PROCESS_QUERY_LIMITED_INFORMATION, to know
// its PID), the only handle the game lets this process inherit. Quoted values run to the next double quote (Windows
// paths can't contain one); the tail after "-- " is taken raw from this process's own command line, never re-quoted.
// Restart mode waits at most 120 s; apply mode has no timeout. On a timeout, a failed wait, or any bad, unknown,
// missing, repeated or oversized argument it launches nothing, writes nothing and exits non-zero.
//
// Files: only apply mode writes, and only inside the allowed targets, ue4ss\<Core>Data\ and the self-update rename of
// its own image to bin\<Core>Restart.<txn>.old (stage/plan.hpp, stage/apply.hpp). Every folder comes from this exe's
// own path <root>\NuclearNightmare\Binaries\Win64\ue4ss\Mods\<Core>\bin\<Core>Restart.exe, never from argv. At start in
// apply mode it deletes leftover bin\*.old files that aren't in use.
//
// GUI subsystem: no window, no console. No shell, no network. Links only Windows system libraries (kernel32, shell32,
// ole32, bcrypt) and the C runtime, never UE4SS.
//
// CORE_RESTART_TEST (the never-shipped <Core>RestartTest.exe, a console program for native/test/restart-helper.tests.ps1
// and native/test/apply.tests.ps1):
//   --record <file>     instead of launching, writes one line to <file> (UTF-8):
//                         direct exe=<exe> cwd=<cwd> cmdline=<tail>   or   steam <url>
//   --timeout-ms <n>    restart mode's limit (1..600000) instead of 120 s
//   --probe-mode <exe>  prints the restart rule's answer for that exe path (steam | direct | none) and exits 0
//   --root <dir>        apply mode: the layout under that folder instead of this exe's own path
//   --fail-after <n>    apply mode: the write after n writes fails (io-error), so everything is rolled back
//   --crash-after <n>   apply mode: the process ends after n writes, leaving the journal without "done"
//   apply mode prints "apply <outcome> <reason> <path> attempts=<n> | <detail>" (or "apply none | <detail>")
// The shipped helper treats these as unknown arguments.
#include <cstdint>
#include <string>

#include "restart_mode.hpp"
#include "stage/apply.hpp"

#include <objbase.h>
#include <shellapi.h>

#include "core_config.hpp"

// Core's name as a wide string literal (CORE_NAME from core_config.hpp, generated from mod.json).
#define CORE_WIDEN2(x) L##x
#define CORE_WIDEN(x) CORE_WIDEN2(x)
#define CORE_NAME_W CORE_WIDEN(CORE_NAME)

namespace
{
    using core_restart::Mode;

    // Exit codes.
    constexpr int k_ok = 0;
    constexpr int k_bad_args = 2;
    constexpr int k_wait_failed = 3; // the timeout included
    constexpr int k_launch_failed = 4;
    constexpr int k_record_failed = 5;
    constexpr int k_internal = 6;
    constexpr int k_no_layout = 7; // apply mode: this exe is not at Mods\<Core>\bin\ of a game install

    constexpr DWORD k_default_timeout_ms = 120000;
    // After the game's process object is signalled: a moment for Steam (it tracks the game's process tree) and for the
    // old process's last handles before the new one starts (or the apply begins).
    constexpr DWORD k_settle_direct_ms = 1000;
    constexpr DWORD k_settle_steam_ms = 3000;
    constexpr size_t k_max_value = 32767;

    struct Args
    {
        bool has_wait = false, has_mode = false, has_cwd = false, has_exe = false, has_tail = false, apply = false;
        uint64_t wait = 0;
        Mode mode = Mode::None;
        std::wstring cwd, exe, tail;
#ifdef CORE_RESTART_TEST
        bool has_record = false, has_timeout = false, has_probe = false, has_root = false, has_fail = false, has_crash = false;
        std::wstring record, probe, root;
        DWORD timeout_ms = 0;
        int fail_after = -1, crash_after = -1;
#endif
    };

    bool is_space(wchar_t c) { return c == L' ' || c == L'\t'; }

    // One token at pos: "quoted" (to the next quote, which must end the token) or bare (to the next space). false on
    // an unterminated quote, a quote inside a bare token, or a token over k_max_value characters.
    bool read_token(const std::wstring& s, size_t& pos, std::wstring& out, bool& quoted)
    {
        out.clear();
        quoted = false;
        if (pos < s.size() && s[pos] == L'"')
        {
            quoted = true;
            const size_t end = s.find(L'"', pos + 1);
            if (end == std::wstring::npos) return false;
            out = s.substr(pos + 1, end - pos - 1);
            pos = end + 1;
            if (pos < s.size() && !is_space(s[pos])) return false;
        }
        else
        {
            const size_t start = pos;
            while (pos < s.size() && !is_space(s[pos]))
            {
                if (s[pos] == L'"') return false;
                ++pos;
            }
            out = s.substr(start, pos - start);
        }
        return out.size() <= k_max_value;
    }

    bool parse_decimal(const std::wstring& v, uint64_t min, uint64_t max, uint64_t& out)
    {
        if (v.empty() || v.size() > 15) return false;
        uint64_t n = 0;
        for (wchar_t c : v)
        {
            if (c < L'0' || c > L'9') return false;
            n = n * 10 + static_cast<uint64_t>(c - L'0');
        }
        if (n < min || n > max) return false;
        out = n;
        return true;
    }

    // An absolute path: X:\... or \\server\... (what GetModuleFileNameW and GetCurrentDirectoryW give).
    bool is_absolute(const std::wstring& p)
    {
        if (p.size() >= 3 && ((p[0] >= L'A' && p[0] <= L'Z') || (p[0] >= L'a' && p[0] <= L'z')) && p[1] == L':' && p[2] == L'\\') return true;
        return p.size() >= 3 && p[0] == L'\\' && p[1] == L'\\';
    }

    // Parses this process's own command line. false on anything not exactly as described at the top.
    bool parse(const std::wstring& s, Args& a)
    {
        if (s.size() > core_restart::k_max_cmdline) return false;
        size_t pos = 0;
        std::wstring tok;
        bool quoted = false;
        bool mode_none = false;
        if (!read_token(s, pos, tok, quoted)) return false; // this program's own path
        while (true)
        {
            while (pos < s.size() && is_space(s[pos])) ++pos;
            if (pos >= s.size()) break;
            if (!read_token(s, pos, tok, quoted)) return false;
            if (!quoted && tok == L"--")
            {
                // The tail: everything after exactly one space, verbatim.
                if (pos >= s.size() || s[pos] != L' ') return false;
                a.tail = s.substr(pos + 1);
                a.has_tail = true;
                break;
            }
            if (quoted) return false; // an option name is never quoted
            if (tok == L"--apply")
            {
                if (a.apply) return false;
                a.apply = true; // a flag: no value
                continue;
            }
            std::wstring val;
            bool vq = false;
            while (pos < s.size() && is_space(s[pos])) ++pos;
            if (pos >= s.size() || !read_token(s, pos, val, vq)) return false;
            if (!vq && val == L"--") return false;
            if (tok == L"--wait")
            {
                if (a.has_wait || !parse_decimal(val, 1, (uint64_t{1} << 47), a.wait)) return false;
                a.has_wait = true;
            }
            else if (tok == L"--mode")
            {
                if (a.has_mode) return false;
                if (val == L"steam") a.mode = Mode::Steam;
                else if (val == L"direct") a.mode = Mode::Direct;
                else if (val == L"none") mode_none = true;
                else return false;
                a.has_mode = true;
            }
            else if (tok == L"--cwd")
            {
                if (a.has_cwd || !is_absolute(val)) return false;
                a.cwd = val;
                a.has_cwd = true;
            }
            else if (tok == L"--exe")
            {
                if (a.has_exe || !is_absolute(val)) return false;
                a.exe = val;
                a.has_exe = true;
            }
#ifdef CORE_RESTART_TEST
            else if (tok == L"--record")
            {
                if (a.has_record || !is_absolute(val)) return false;
                a.record = val;
                a.has_record = true;
            }
            else if (tok == L"--timeout-ms")
            {
                uint64_t ms = 0;
                if (a.has_timeout || !parse_decimal(val, 1, 600000, ms)) return false;
                a.timeout_ms = static_cast<DWORD>(ms);
                a.has_timeout = true;
            }
            else if (tok == L"--probe-mode")
            {
                if (a.has_probe || val.empty()) return false;
                a.probe = val;
                a.has_probe = true;
            }
            else if (tok == L"--root")
            {
                if (a.has_root || !is_absolute(val)) return false;
                a.root = val;
                a.has_root = true;
            }
            else if (tok == L"--fail-after" || tok == L"--crash-after")
            {
                uint64_t n = 0;
                const bool fail = tok == L"--fail-after";
                if ((fail ? a.has_fail : a.has_crash) || !parse_decimal(val, 0, 100000, n)) return false;
                (fail ? a.fail_after : a.crash_after) = static_cast<int>(n);
                (fail ? a.has_fail : a.has_crash) = true;
            }
#endif
            else
            {
                return false;
            }
        }
#ifdef CORE_RESTART_TEST
        if (a.has_probe) return !(a.has_wait || a.has_mode || a.has_cwd || a.has_exe || a.has_tail || a.has_record || a.has_timeout || a.apply || a.has_root || a.has_fail || a.has_crash);
        if (!a.apply && (a.has_root || a.has_fail || a.has_crash)) return false; // apply-mode test options
        if (a.apply && a.has_timeout) return false;                              // apply mode has no timeout
#endif
        if (mode_none && !a.apply) return false; // restart mode always has somewhere to go
        return a.has_wait && a.has_mode && a.has_cwd && a.has_exe && a.has_tail && !a.tail.empty() && a.tail.size() <= k_max_value;
    }

#ifdef CORE_RESTART_TEST
    bool write_record(const std::wstring& file, const std::wstring& line)
    {
        const HANDLE f = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f == INVALID_HANDLE_VALUE) return false;
        const std::string bytes = core_stage::narrow(line) + "\n";
        DWORD wrote = 0;
        const BOOL ok = WriteFile(f, bytes.data(), static_cast<DWORD>(bytes.size()), &wrote, nullptr);
        CloseHandle(f);
        return ok && wrote == bytes.size();
    }
    void print(const std::string& line)
    {
        DWORD wrote = 0;
        const std::string l = line + "\n";
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), l.data(), static_cast<DWORD>(l.size()), &wrote, nullptr);
    }
#endif

    int launch(const Args& a)
    {
        if (a.mode == Mode::Steam)
        {
#ifdef CORE_RESTART_TEST
            if (a.has_record) return write_record(a.record, std::wstring{L"steam "} + core_restart::k_steam_url) ? k_ok : k_record_failed;
#endif
            const HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
            const auto r = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", core_restart::k_steam_url, nullptr, nullptr, SW_SHOWNORMAL));
            if (SUCCEEDED(co)) CoUninitialize();
            return r > 32 ? k_ok : k_launch_failed;
        }
#ifdef CORE_RESTART_TEST
        if (a.has_record) return write_record(a.record, L"direct exe=" + a.exe + L" cwd=" + a.cwd + L" cmdline=" + a.tail) ? k_ok : k_record_failed;
#endif
        std::wstring cmd = a.tail; // CreateProcessW may write into its command line buffer
        STARTUPINFOW si{};
        si.cb = sizeof(si);
        PROCESS_INFORMATION pi{};
        if (!CreateProcessW(a.exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, a.cwd.c_str(), &si, &pi)) return k_launch_failed;
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return k_ok;
    }

    // Apply mode: no timeout; the staged change applied; the relaunch only when relaunch.txt asks for it.
    int run_apply(const Args& a, HANDLE h)
    {
        core_stage::Layout layout;
        const std::wstring self = core_stage::module_file(nullptr);
        bool have_layout = core_stage::layout_from_module(self, CORE_NAME_W, layout);
#ifdef CORE_RESTART_TEST
        if (a.has_root) have_layout = core_stage::layout_from_root(a.root, CORE_NAME_W, layout);
#endif
        if (!have_layout)
        {
            CloseHandle(h);
            return k_no_layout;
        }
        // An interrupted apply's journal may still need a bin\*.old copy (a self-update's "moved" step): kept until the
        // recovery after the wait has put it back.
        if (core_stage::staged_state(layout) != core_stage::StagedState::Interrupted) core_stage::delete_old_helpers(layout.core_dir + L"\\bin");
        const DWORD game_pid = GetProcessId(h); // 0 without PROCESS_QUERY_LIMITED_INFORMATION: never relaunched
        const DWORD w = WaitForSingleObject(h, INFINITE);
        CloseHandle(h);
        if (w != WAIT_OBJECT_0) return k_wait_failed;
        Sleep(k_settle_direct_ms);
        core_stage::ApplyOptions o;
        o.layout = layout;
        o.self_image = self;
#ifdef CORE_RESTART_TEST
        o.fail_after = a.fail_after;
        o.crash_after = a.crash_after;
#endif
        const core_stage::ApplyReport rep = core_stage::run_apply(o);
#ifdef CORE_RESTART_TEST
        if (rep.acted)
        {
            const auto& r = rep.result;
            print("apply " + r.outcome + " " + (r.reason.empty() ? "-" : r.reason) + " " + (r.path.empty() ? "-" : r.path) + " attempts=" + std::to_string(r.attempts) +
                  " | " + rep.detail);
        }
        else
        {
            print("apply none | " + rep.detail);
        }
#endif
        const bool relaunch = core_stage::take_relaunch(layout, game_pid, GetCurrentProcessId());
        if (!relaunch || a.mode == Mode::None) return k_ok;
        if (a.mode == Mode::Steam) Sleep(k_settle_steam_ms - k_settle_direct_ms);
        return launch(a);
    }

    int run()
    {
        Args a;
        if (!parse(GetCommandLineW(), a)) return k_bad_args;
#ifdef CORE_RESTART_TEST
        if (a.has_probe)
        {
            print(core_restart::mode_name(core_restart::mode_for(a.probe)));
            return k_ok;
        }
#endif
        const auto h = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(a.wait));
        DWORD flags = 0;
        if (!GetHandleInformation(h, &flags)) return k_bad_args; // not a handle this process holds
        if (a.apply) return run_apply(a, h);
        DWORD timeout = k_default_timeout_ms;
#ifdef CORE_RESTART_TEST
        if (a.has_timeout) timeout = a.timeout_ms;
#endif
        const DWORD w = WaitForSingleObject(h, timeout);
        CloseHandle(h);
        if (w != WAIT_OBJECT_0) return k_wait_failed;
        Sleep(a.mode == Mode::Steam ? k_settle_steam_ms : k_settle_direct_ms);
        return launch(a);
    }

    int guarded_run()
    {
        try
        {
            return run();
        }
        catch (...)
        {
            return k_internal;
        }
    }
} // namespace

#ifdef CORE_RESTART_TEST
int wmain()
{
    return guarded_run();
}
#else
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    return guarded_run();
}
#endif
