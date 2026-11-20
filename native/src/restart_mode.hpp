// The restart rule (Mod Manager story 8, core story 45), shared by core's DLL (<Core>_RestartMode, <Core>_RestartStart)
// and the relaunch helper's test build (--probe-mode). Header-only, Windows and the C++ standard library only: the
// helper links no UE4SS. Nothing here spells core's name.
//
// From the running exe's path <game root>\NuclearNightmare\Binaries\Win64\<exe>:
//   <game root>\..\..\appmanifest_2909110.acf exists   -> steam  (a Steam install: relaunch through Steam)
//   else steam_appid.txt beside the exe                -> direct (a dev copy: the same exe, the same command line)
//   else                                               -> none   ("unsupported launch")
// The manifest is checked first, so a Steam install with a stray steam_appid.txt still restarts through Steam (and keeps
// the player's Steam launch options). An exe outside that layout can only be direct.
#pragma once

#include <string>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

namespace core_restart
{
    inline constexpr const wchar_t* k_manifest = L"appmanifest_2909110.acf";
    inline constexpr const wchar_t* k_appid_file = L"steam_appid.txt";
    inline constexpr const wchar_t* k_steam_url = L"steam://rungameid/2909110";
    inline constexpr const wchar_t* k_project = L"NuclearNightmare";
    // CreateProcessW's lpCommandLine holds at most 32,767 characters with its terminating null.
    inline constexpr size_t k_max_cmdline = 32766;

    enum class Mode
    {
        None,
        Steam,
        Direct
    };

    inline const char* mode_name(Mode m)
    {
        return m == Mode::Steam ? "steam" : m == Mode::Direct ? "direct" : "none";
    }

    // The folder part of a path ("" when there is none). A trailing separator is not expected (module paths have none).
    inline std::wstring parent_of(const std::wstring& p)
    {
        const auto i = p.find_last_of(L"\\/");
        return i == std::wstring::npos ? std::wstring{} : p.substr(0, i);
    }
    inline std::wstring leaf_of(const std::wstring& p)
    {
        const auto i = p.find_last_of(L"\\/");
        return i == std::wstring::npos ? p : p.substr(i + 1);
    }
    inline bool same_name(const std::wstring& a, const wchar_t* b)
    {
        return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()), b, -1, TRUE) == CSTR_EQUAL;
    }
    inline bool is_file(const std::wstring& p)
    {
        if (p.empty()) return false;
        const DWORD a = GetFileAttributesW(p.c_str());
        return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY) == 0;
    }

    // The rule above for an exe path. Reads only file attributes; never throws.
    inline Mode mode_for(const std::wstring& exe)
    {
        const std::wstring win64 = parent_of(exe);
        if (win64.empty()) return Mode::None;
        const std::wstring binaries = parent_of(win64);
        const std::wstring project = parent_of(binaries);
        const std::wstring root = parent_of(project);
        const bool layout = !root.empty() && same_name(leaf_of(win64), L"Win64") && same_name(leaf_of(binaries), L"Binaries") &&
                            same_name(leaf_of(project), k_project);
        if (layout)
        {
            const std::wstring steamapps = parent_of(parent_of(root));
            if (!steamapps.empty() && is_file(steamapps + L"\\" + k_manifest)) return Mode::Steam;
        }
        if (is_file(win64 + L"\\" + k_appid_file)) return Mode::Direct;
        return Mode::None;
    }
} // namespace core_restart
