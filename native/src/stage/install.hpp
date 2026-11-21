// Staging installs from the verified catalog (Mod Manager v2 story 5; README "Installing from the catalog"): the code
// behind <Core>_CatalogStage (catalog.cpp) and the catalog test exe's -Stage (catalog_cli.cpp). Shared with stories 6
// and 7 (update is this stage with an installed owner; uninstall needs only the delete and modstxt lines and the writer).
//
// run_stage takes up to 16 (id, version) pairs and, in input order, before anything is written:
//   1. finds the version in the verified index (kind "mod"), refused when the revoked list names it (story 2's rules);
//   2. downloads it through story 2's download (fetch::download_with_state, which reuses a still-valid
//      downloads/<sha256>.zip), reads the file into memory and checks its size and SHA-256 against the index again: every
//      later step works on these verified bytes;
//   3. reads the zip (zip.hpp);
//   4. maps each entry: NuclearNightmare/Binaries/Win64/ue4ss/Mods/<Name>/<sub>, NuclearNightmare/Content/Paks/
//      LogicMods/<X>.pak and NuclearNightmare/Content/Paks/<X>_P.pak become put lines at that target (plan.hpp's target
//      rule decides); anything else, more than one <Name>, UE4SS.dll or dwmapi.dll, or player data (settings.json and
//      settings.json.bak in Mods/<Name>/, state.json and state.json.mm-bak in Mods/ModManager/: Install-NNMods.ps1's
//      kept leaves) is bad-layout; a <Name> or <X> other than the index name (compared without case) is name-mismatch;
//   5. with a Mods/<Name>/ folder: Mods/<Name>/mod.json must be in the zip with the pair's id (normalized; else
//      id-mismatch), and modstxt <Name> on is added; the mod.json already on disk (at most 64 KiB) must have the same id
//      (else folder-in-use) and a version not newer than the pair's (else downgrade);
//   6. files installed.txt records for this owner that the new zip lacks get delete lines (with the recorded SHA-256).
// Then, holding <Core>Data\apply.lock (refused as applying while held, interrupted while a journal lacks "done"): the
// staged files are written as staged\files\<sha256>.tmp and renamed (a file already there with the right size and hash
// is reused); the existing plan.txt (if any) is read with story 3's parser, every operation of an owner (or modstxt
// name) in the new set is dropped, the new operations appended, story 3's caps checked, and plan.txt.tmp written with a
// fresh txn and renamed; staged files no operation references are removed, then the used downloads/<sha256>.zip files.
// On any failure the old plan and its files stay as they were and nothing new remains.
//
// Owner = the index name (plan.hpp's <Owner> rule); the plan never holds a name, path or hash from Lua: targets come
// from the verified zip's entry names through the mapping and the target rule, hashes from the verified bytes.
// Outcomes: ok, not-in-catalog, not-a-mod, revoked, too-large, downloads-full, size-mismatch, hash-mismatch,
// url-not-allowed, unreachable, bad-zip, bad-layout, name-mismatch, id-mismatch, folder-in-use, downgrade, applying,
// interrupted, error. Payload of ok: {"txn","owners":[{"id","version","name","files","bytes"}],"ops"} (ops: the
// operations in the plan now); otherwise {"failed":<id>|null}. Windows, the C++ library and core's catalog code (no
// UE4SS): core's DLL and the test exe both build it. Never throws.
#pragma once

#include <atomic>
#include <filesystem>
#include <string>
#include <vector>

#include "../catalog/fetch.hpp"
#include "../catalog/json.hpp"
#include "plan.hpp"

namespace core_stage::install
{
    inline constexpr size_t k_max_pairs = 16;
    inline constexpr size_t k_max_mod_json = 64 * 1024;

    struct Item
    {
        std::string id;      // normalized
        std::string version; // semver
    };

    struct Outcome
    {
        std::string outcome = "error";
        std::string message;
        std::string payload = "{\"failed\":null}";
        std::vector<std::string> details; // one line each, for the test exe and core's log
    };

    // "applying" (apply.lock held), "interrupted" (a journal without "done"), or "" (stageable now).
    std::string blocked(const Layout& l);

    // The whole stage (above). state_file: story 2's state.json, for download back-off (may be empty). precheck false
    // (the test exe's -NoPrecheck only) skips the applying/interrupted check before the downloads, so the checks made
    // once apply.lock is taken can be tested; they always run.
    Outcome run_stage(const Layout& l, const catalog::json::Value& ix, const catalog::json::Value* rv, const std::vector<Item>& items, catalog::fetch::Transport& t,
                      const std::filesystem::path& state_file, const std::atomic<bool>& cancel, bool precheck = true);

    // semver precedence: <0, 0, >0; nullopt-like 2 when either isn't semver.
    int semver_compare(const std::string& a, const std::string& b);
} // namespace core_stage::install
