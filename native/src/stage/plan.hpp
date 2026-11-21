// Staged changes (Mod Manager v2 story 3; README "Staged changes"): the plan file, the result file, the install layout
// and the allowed targets, and SHA-256 through Windows CNG (BCrypt). Shared by the relaunch helper (restart_helper.cpp,
// which applies a plan: stage/apply.cpp), core's DLL (apply.cpp: <Core>_ApplyStatus/Start/Ack) and, later, the code
// that writes plans (Mod Manager v2 stories 5-7). Windows and the C++ standard library only, never UE4SS (the helper
// links no UE4SS); nothing here spells core's name (the caller passes it from CORE_NAME).
//
// Layout (from the helper's or main.dll's own module path, never from Lua or argv):
//   <root>\NuclearNightmare\Binaries\Win64\ue4ss\Mods\<Core>\{bin,dlls}\<file>
//   data folder <root>\NuclearNightmare\Binaries\Win64\ue4ss\<Core>Data\
//
// Plan (<Core>Data\staged\plan.txt; UTF-8 without BOM, "\n" or "\r\n", at most 1 MiB and 1024 operation lines, put
// sizes summing to at most 512 MiB, tab-separated; any unknown or malformed line refuses the whole plan):
//   nucleus-plan\t1
//   txn\t<32 lowercase hex>
//   put\t<Owner>\t<sha256>\t<size>\t<target>        copy staged\files\<sha256> to <root>\<target>
//   delete\t<Owner>\t<sha256 or ->\t<target>        delete <root>\<target> (with a hash: only that file)
//   modstxt\t<Name>\ton|remove                      mods.txt: every line of <Name> to 1 (one inserted above Keybinds
//                                                   when missing) | every line of <Name> removed
// Writers create plan.txt.tmp and rename it to plan.txt; readers read only plan.txt.
//
// Allowed targets (relative to <root>, "\" separators, fixed parts compared without case):
//   NuclearNightmare\Binaries\Win64\ue4ss\Mods\<Name>\<sub>     <sub>: 1-8 components of [A-Za-z0-9 ._-]{1,64}
//   NuclearNightmare\Content\Paks\LogicMods\<Name>.pak
//   NuclearNightmare\Content\Paks\<Name>_P.pak
// No component is "." or "..", ends in a dot or a space, or is a reserved device name; <Name> and <Owner> match
// [A-Za-z][A-Za-z0-9_-]{0,63}; <Name> is never a stock UE4SS mod folder (k_stock_mods). Two operations on one target
// (compared without case) refuse the plan.
//
// Result (<Core>Data\apply-result.txt): nucleus-result\t1, txn, outcome (applied|failed|discarded), reason, path,
// attempts; one "<key>\t<value>" line each, "-" for an empty value.
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

namespace core_stage
{
    inline constexpr size_t k_max_plan_bytes = 1024 * 1024;
    inline constexpr size_t k_max_ops = 1024;
    inline constexpr uint64_t k_max_put_total = 512ull * 1024 * 1024;
    inline constexpr size_t k_max_result_bytes = 64 * 1024;
    inline constexpr size_t k_max_installed_bytes = 4 * 1024 * 1024;
    inline constexpr size_t k_max_installed_entries = 16384;
    inline constexpr size_t k_max_sub_components = 8;
    inline constexpr size_t k_max_component = 64;
    inline constexpr size_t k_max_name = 64;

    // The folder names under ue4ss/Mods/ in the pinned UE4SS release zip v3.0.1-1181-g83330635
    // (tools/_downloads/ue4ss-1181-g83330635/UE4SS_v3.0.1-1181-g83330635.zip, the zip tools/release/base-pack.ps1 reads).
    // A plan never writes into, deletes from or edits the mods.txt line of one of them. Update with a UE4SS upgrade.
    inline constexpr std::array<const char*, 9> k_stock_mods = {"BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod",
                                                                "ConsoleCommandsMod",    "ConsoleEnablerMod", "Keybinds",
                                                                "LineTraceMod",          "shared",            "SplitScreenMod"};

    // ------------------------------------------------------------------ layout
    struct Layout
    {
        std::wstring root;     // the folder holding NuclearNightmare\ (no trailing separator)
        std::wstring ue4ss;    // <root>\NuclearNightmare\Binaries\Win64\ue4ss
        std::wstring mods;     // <ue4ss>\Mods
        std::wstring core_dir; // <mods>\<Core>
        std::wstring data;     // <ue4ss>\<Core>Data
        std::wstring helper;   // <core_dir>\bin\<Core>Restart.exe
        std::wstring core_name;
    };
    // The layout for a root folder (absolute: X:\... or \\server\...). false when root isn't absolute.
    bool layout_from_root(const std::wstring& root, const std::wstring& core_name, Layout& out);
    // The layout from a module path <root>\NuclearNightmare\Binaries\Win64\ue4ss\Mods\<Core>\{bin|dlls}\<file>; false when
    // the path doesn't have that shape (fixed parts compared without case).
    bool layout_from_module(const std::wstring& module_path, const std::wstring& core_name, Layout& out);
    // GetModuleFileNameW into a growing buffer (long paths). Empty on failure.
    std::wstring module_file(HMODULE m);

    // ------------------------------------------------------------------ names and targets
    bool is_name(std::string_view s);    // [A-Za-z][A-Za-z0-9_-]{0,63}
    bool is_stock_mod(std::string_view s); // compared without case
    bool is_hex(std::string_view s, size_t len); // exactly len lowercase hex digits
    bool is_component(std::string_view s);       // a <sub> component (see the top)

    enum class TargetKind
    {
        ModFile,  // Mods\<Name>\<sub>
        LogicPak, // Content\Paks\LogicMods\<Name>.pak
        BasePak   // Content\Paks\<Name>_P.pak
    };
    struct Target
    {
        TargetKind kind{};
        std::string rel;  // as written in the plan
        std::string name; // <Name>
        // How many leading components form the folder a delete may empty but never removes: Mods (5), LogicMods (4),
        // Paks (3).
        size_t keep = 0;
    };
    // true when rel is an allowed target; why names the rule otherwise.
    bool parse_target(std::string_view rel, Target& out, std::string& why);

    // ------------------------------------------------------------------ the plan
    enum class OpKind
    {
        Put,
        Delete,
        ModsTxt
    };
    struct Op
    {
        OpKind kind{};
        std::string owner;  // put, delete
        std::string sha256; // put; delete ("" for "-")
        uint64_t size = 0;  // put
        Target target;      // put, delete
        std::string name;   // modstxt
        bool on = false;    // modstxt: on (true) | remove (false)
    };
    struct Plan
    {
        std::string txn;
        std::vector<Op> ops;
    };
    // Parses and validates a whole plan. false with why (and bad_target set when a target was refused) otherwise.
    bool parse_plan(std::string_view text, Plan& out, std::string& why, std::string& bad_target);
    std::string serialize_plan(const Plan& plan);

    // ------------------------------------------------------------------ the result
    struct ResultFile
    {
        std::string txn, outcome, reason, path;
        uint64_t attempts = 0;
    };
    bool parse_result(std::string_view text, ResultFile& out);
    std::string serialize_result(const ResultFile& r);

    // ------------------------------------------------------------------ installed.txt (owner, SHA-256, target per file)
    struct Installed
    {
        std::string owner, sha256, target;
    };
    // nucleus-installed\t1, then <owner>\t<sha256>\t<target> lines. false on a malformed file (callers start empty).
    bool parse_installed(std::string_view text, std::vector<Installed>& out);
    std::string serialize_installed(const std::vector<Installed>& list);

    // ------------------------------------------------------------------ text, files and SHA-256
    std::wstring widen(std::string_view s); // UTF-8 -> UTF-16 (plans hold ASCII only)
    std::string narrow(std::wstring_view w); // UTF-16 -> UTF-8
    bool same_text_nocase(std::wstring_view a, std::wstring_view b);
    bool starts_with_nocase(std::wstring_view s, std::wstring_view prefix);
    // The whole file, when it is a regular file of at most max bytes. false otherwise (missing, bigger, unreadable).
    bool read_file(const std::wstring& path, size_t max, std::string& out, DWORD* err = nullptr);
    bool file_exists(const std::wstring& path);
    bool dir_exists(const std::wstring& path);

    class Sha256
    {
      public:
        Sha256();
        ~Sha256();
        Sha256(const Sha256&) = delete;
        Sha256& operator=(const Sha256&) = delete;
        bool ok() const { return m_ok; }
        void update(const void* p, size_t n);
        std::string hex(); // finishes; lowercase hex ("" when CNG failed)

      private:
        void* m_alg = nullptr;
        void* m_hash = nullptr;
        bool m_ok = false;
    };
    // A file's size and SHA-256 (lowercase hex). false when it can't be read (err set).
    bool hash_file(const std::wstring& path, uint64_t& size, std::string& sha, DWORD* err = nullptr);
} // namespace core_stage
