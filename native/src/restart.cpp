// Restart now (Mod Manager story 8, core story 45; api-contract.md "C++ natives", README "Restart").
//
// <Core>_RestartMode() answers the restart rule (restart_mode.hpp) for this process's own exe. <Core>_RestartStart()
// starts the relaunch helper Mods/<Core>/bin/<Core>Restart.exe, found from this DLL's own module path (..\bin\), never
// from Lua. Everything the helper gets comes from the game process itself: its exe (GetModuleFileNameW(nullptr)), its
// command line (GetCommandLineW(), verbatim), its working folder (GetCurrentDirectoryW()) and one SYNCHRONIZE handle to
// this process, the only handle the helper inherits (PROC_THREAD_ATTRIBUTE_HANDLE_LIST). No Lua value reaches the
// helper's command line: both natives take no arguments. At most one helper waits at a time (a call while it waits
// answers "already started"; after it has exited a call starts a new one); the caller quits the game itself.
//
// Both natives touch no UObject, so any thread may call them. Every path returns a value or a "nil, reason" pair;
// argument problems raise "<fn>: takes no arguments"; a C++ exception becomes "<fn>: internal error ..." (guarded()).
#include <atomic>
#include <cstdint>
#include <format>
#include <mutex>
#include <string>
#include <vector>

#include "core_shared.hpp"
#include "core_config.hpp"
#include "restart.hpp"
// After the UE4SS headers (core_shared.hpp), so their own Windows setup wins.
#include "restart_mode.hpp"

namespace core_native::restart
{
    const std::string g_fn_mode = std::string{CORE_NAME} + "_RestartMode";
    const std::string g_fn_start = std::string{CORE_NAME} + "_RestartStart";

    namespace
    {
        std::mutex g_mutex;
        // Under g_mutex: a SYNCHRONIZE handle to the helper this session started, while it may still be waiting. Once
        // it has exited (it relaunched nothing because the game didn't quit within 120 s, or QuitGame failed), the next
        // start begins a new one.
        HANDLE g_helper = nullptr;

        void no_args(const Lua& lua, const std::string& fn)
        {
            if (lua.get_stack_size() != 0) throw ArgError(std::format("{}: takes no arguments", fn));
        }

        std::wstring widen_ascii(const char* s)
        {
            std::wstring w;
            for (; *s; ++s) w.push_back(static_cast<wchar_t>(static_cast<unsigned char>(*s)));
            return w;
        }

        // GetModuleFileNameW into a growing buffer (long paths). Empty on failure.
        std::wstring module_path(HMODULE m)
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

        std::wstring current_dir()
        {
            const DWORD need = GetCurrentDirectoryW(0, nullptr);
            if (need == 0 || need > 32768) return {};
            std::wstring s(need, L'\0');
            const DWORD n = GetCurrentDirectoryW(need, s.data());
            if (n == 0 || n >= need) return {};
            s.resize(n);
            return s;
        }

        // Mods/<Core>/bin/<Core>Restart.exe from this DLL's path Mods/<Core>/dlls/main.dll. Empty when unknown.
        std::wstring helper_path()
        {
            HMODULE self = nullptr;
            if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                    reinterpret_cast<LPCWSTR>(&helper_path), &self))
            {
                return {};
            }
            const std::wstring dll = module_path(self);
            const std::wstring mod = core_restart::parent_of(core_restart::parent_of(dll));
            if (mod.empty()) return {};
            return mod + L"\\bin\\" + widen_ascii(CORE_NAME) + L"Restart.exe";
        }

        Result nil_reason(std::string why)
        {
            Result r;
            r.kind = Result::Kind::NilText;
            r.text = std::move(why);
            return r;
        }

        // Starts the helper; returns the Win32 error code (0 on success). Closes everything it opened.
        DWORD start_helper(const std::wstring& helper, core_restart::Mode mode, const std::wstring& exe, const std::wstring& cwd, DWORD* pid,
                           bool* too_long, HANDLE* helper_handle)
        {
            *helper_handle = nullptr;
            *too_long = false;
            HANDLE wait = nullptr;
            if (!DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(), &wait, SYNCHRONIZE, TRUE, 0)) return GetLastError();
            std::wstring cmd = L"\"" + helper + L"\" --wait " + std::to_wstring(reinterpret_cast<uintptr_t>(wait)) + L" --mode " +
                               (mode == core_restart::Mode::Steam ? L"steam" : L"direct") + L" --cwd \"" + cwd + L"\" --exe \"" + exe + L"\" -- " +
                               GetCommandLineW();
            if (cmd.size() > core_restart::k_max_cmdline)
            {
                CloseHandle(wait);
                *too_long = true;
                return 0;
            }
            SIZE_T attr_size = 0;
            InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
            std::vector<unsigned char> attr_buf(attr_size);
            auto attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attr_buf.data());
            if (attr_size == 0 || !InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size))
            {
                const DWORD e = GetLastError();
                CloseHandle(wait);
                return e ? e : ERROR_INVALID_PARAMETER;
            }
            DWORD err = 0;
            if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &wait, sizeof(wait), nullptr, nullptr))
            {
                err = GetLastError();
            }
            else
            {
                STARTUPINFOEXW si{};
                si.StartupInfo.cb = sizeof(si);
                si.lpAttributeList = attrs;
                PROCESS_INFORMATION pi{};
                // Out of the game's job when the job allows it (so the helper outlives the game); otherwise inside it.
                BOOL ok = CreateProcessW(helper.c_str(), cmd.data(), nullptr, nullptr, TRUE, EXTENDED_STARTUPINFO_PRESENT | CREATE_BREAKAWAY_FROM_JOB,
                                         nullptr, nullptr, &si.StartupInfo, &pi);
                if (!ok && GetLastError() == ERROR_ACCESS_DENIED)
                {
                    ok = CreateProcessW(helper.c_str(), cmd.data(), nullptr, nullptr, TRUE, EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr,
                                        &si.StartupInfo, &pi);
                }
                if (ok)
                {
                    *pid = pi.dwProcessId;
                    // Keep only SYNCHRONIZE: enough to ask whether the helper is still waiting.
                    if (!DuplicateHandle(GetCurrentProcess(), pi.hProcess, GetCurrentProcess(), helper_handle, SYNCHRONIZE, FALSE, 0)) *helper_handle = nullptr;
                    CloseHandle(pi.hThread);
                    CloseHandle(pi.hProcess);
                }
                else
                {
                    err = GetLastError();
                    if (err == 0) err = ERROR_GEN_FAILURE;
                }
            }
            DeleteProcThreadAttributeList(attrs);
            CloseHandle(wait); // the helper holds its own inherited copy
            return err;
        }
    } // namespace

    int l_mode(const Lua& lua)
    {
        return guarded(lua, g_fn_mode, [&] {
            no_args(lua, g_fn_mode);
            const core_restart::Mode m = core_restart::mode_for(module_path(nullptr));
            if (m == core_restart::Mode::None) return nil_reason("unsupported launch");
            Result r;
            r.kind = Result::Kind::String;
            r.text = core_restart::mode_name(m);
            return r;
        });
    }

    int l_start(const Lua& lua)
    {
        return guarded(lua, g_fn_start, [&] {
            no_args(lua, g_fn_start);
            std::lock_guard guard{g_mutex};
            if (g_helper)
            {
                if (WaitForSingleObject(g_helper, 0) == WAIT_TIMEOUT) return nil_reason("already started");
                CloseHandle(g_helper); // that helper has exited: start a new one, as on a first call
                g_helper = nullptr;
                logf("restart: the earlier helper has exited; starting a new one");
            }
            const std::wstring exe = module_path(nullptr);
            const core_restart::Mode m = core_restart::mode_for(exe);
            if (m == core_restart::Mode::None)
            {
                logf("restart: not started: unsupported launch");
                return nil_reason("unsupported launch");
            }
            const std::wstring helper = helper_path();
            if (!core_restart::is_file(helper))
            {
                logf("restart: not started: helper missing (bin/{}Restart.exe)", CORE_NAME);
                return nil_reason("helper missing");
            }
            const std::wstring cwd = current_dir();
            if (cwd.empty() || exe.empty())
            {
                const DWORD e = GetLastError();
                logf("restart: not started: the game's folder or exe could not be read ({})", e);
                return nil_reason(std::format("start failed: {}", e ? e : ERROR_GEN_FAILURE));
            }
            DWORD pid = 0;
            bool too_long = false;
            HANDLE started = nullptr;
            const DWORD err = start_helper(helper, m, exe, cwd, &pid, &too_long, &started);
            if (too_long)
            {
                logf("restart: not started: command line too long");
                return nil_reason("command line too long");
            }
            if (err != 0)
            {
                logf("restart: not started: start failed: {}", err);
                return nil_reason(std::format("start failed: {}", err));
            }
            // Without a handle (duplication failed) a second call can't tell whether it waits: it starts another one,
            // which is harmless (each relaunches only after this game exits; the second finds Steam or the new game up).
            g_helper = started;
            logf("restart: helper started (mode={}, pid={})", core_restart::mode_name(m), pid);
            Result r;
            r.kind = Result::Kind::Bool;
            r.boolean = true;
            return r;
        });
    }
} // namespace core_native::restart
