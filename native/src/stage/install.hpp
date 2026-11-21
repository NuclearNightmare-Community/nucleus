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
//      (else folder-in-use) and a version not newer than the pair's (else downgrade), except when that installed
//      (id, version) is revoked (find_revoked_installed against the verified list: story 6, a downgrade only away
//      from a revoked version);
//   6. (story 6: an update) the files of the installed version ("files of the installed version" below) that the new
//      zip doesn't put get delete lines with their SHA-256. An installed version neither installed.txt nor the
//      catalog knows gets no deletes.
// Files of the installed version (owner <Name>, the index name): installed.txt's records for <Name> when it has any;
// otherwise the release of the installed (id, version) named by the verified index, for any game build, downloaded and
// verified through story 2 even when revoked (its bytes are only read, never staged) and mapped as in step 4, each
// target with its entry's hash; otherwise not-in-catalog. A listed file is owned only when it is on disk with that
// hash; another hash is kept (counted), a missing one skipped. Player data is never listed.
// run_unstage (story 6, <Core>_CatalogUnstage) stages the removal of an installed (id, version): base-pack (Nucleus or
// Mod Manager: the installer removes those), not-installed (no Mods/<Name>/mod.json with this id), changed (its
// version isn't the pair's), not-in-catalog, story 2's download outcomes, applying, interrupted, error; on ok a delete
// line per owned file and modstxt <Name> remove, merged by owner like a stage (a pending install of <Name> is
// replaced). Payload of ok: {"txn","owners":[{"id","version","name","files","kept"}],"ops"}; else {"failed":<id>}.
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

    // Story 6: the removal of one installed (id, version) (above). Never throws.
    Outcome run_unstage(const Layout& l, const catalog::json::Value& ix, const Item& item, catalog::fetch::Transport& t, const std::filesystem::path& state_file,
                        const std::atomic<bool>& cancel, bool precheck = true);

    // The base pack's mods, which only the installer removes: core (<namespace>.<core name in lower case>) and Mod Manager.
    inline constexpr const char* k_base_namespace = "nuclearnightmare-community";
    bool is_base_pack(const std::string& normalized_id);

    // semver precedence: <0, 0, >0; nullopt-like 2 when either isn't semver.
    int semver_compare(const std::string& a, const std::string& b);
} // namespace core_stage::install
