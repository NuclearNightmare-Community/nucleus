// Applying a staged change (Mod Manager v2 story 3; README "Staged changes"). Run by the relaunch helper in apply mode
// once the game has exited; core's DLL uses only the read-only parts (status, result, ack, relaunch request).
//
// Files, all in <Core>Data\ (plan.hpp: the layout):
//   staged\plan.txt, staged\files\<sha256>   the staged change (written by stories 5-7, through plan.hpp)
//   staged\attempts.txt                      "<txn>\t<n>": failed attempts of that plan
//   apply.lock                               held (exclusive, delete-on-close) while an apply or a recovery runs
//   rollback\journal.txt, rollback\files\<n> the journal (one flushed line per step) and the backups of one apply; kept
//                                            after a successful apply until the next one starts
//   apply-result.txt                         the last outcome (plan.hpp)
//   installed.txt                            owner, SHA-256 and target of each file applied (plan.hpp)
//   failed\                                  the latest discarded plan (staged\ moved here)
//   relaunch.txt                             nucleus-relaunch\t1, game\t<pid>, helper\t<pid>: Restart now was pressed
//
// Order (run_apply): game exes gone (60 s; in <root>\ or under NuclearNightmare\Binaries\, not Engine\), the lock,
// recovery of an interrupted journal, the plan parsed and every target checked (allowed shape, no reparse point from
// <root> down), every staged file's size and SHA-256, every hashed delete's file; then the journal: per target a backup
// (or "absent"), <target>.<txn>.tmp written and renamed into place; mods.txt edited (Mod Manager's modstxt.lua rule);
// installed.txt (an existing one that can't be read or parsed fails the apply); "done". Any failure puts every step
// back in reverse order. A put to the helper's own image writes the new copy, then renames the running copy to
// bin\<Core>Restart.<txn>.old.
// Outcomes: applied (plan and staged\ cleared); failed (the plan stays; attempts +1; after 3 attempts discarded);
// discarded at once for a bad plan or a staged file that doesn't match. "game-running" is not an attempt.
#pragma once

#include <cstdint>
#include <string>

#include "plan.hpp"

namespace core_stage
{
    struct ApplyOptions
    {
        Layout layout;
        std::wstring self_image;       // this process's own image (a put to it is a self-update)
        DWORD game_wait_ms = 60000;    // how long other game exes under <root> may keep running
        int fail_after = -1;           // test build: the step after this many writes fails (io-error)
        int crash_after = -1;          // test build: the process ends after this many writes (an interrupted apply)
    };

    struct ApplyReport
    {
        bool acted = false;      // a result was written
        ResultFile result;
        std::string detail;      // one line for a test build's output
    };

    // The whole apply. Never throws.
    ApplyReport run_apply(const ApplyOptions& opts);

    // Deletes leftover <dir>\*.old files that aren't in use (bin\ of the helper). Never throws.
    void delete_old_helpers(const std::wstring& bin_dir);

    // ---------------------------------------------------------------- read-only parts (core's DLL)
    enum class StagedState
    {
        None,
        Pending,
        Applying,
        Interrupted
    };
    StagedState staged_state(const Layout& l);
    // A journal without "done" (an interrupted apply), whether or not apply.lock is held (stage writers check it under
    // the lock, where staged_state answers Applying).
    bool journal_interrupted(const Layout& l);
    bool plan_exists(const Layout& l);
    // The staged plan's txn and operation count (from the parsed plan); false when there is none or it doesn't parse.
    bool staged_summary(const Layout& l, std::string& txn, size_t& ops);
    bool read_result(const Layout& l, ResultFile& out);
    // Deletes the result file. false when it can't (err set).
    bool delete_result(const Layout& l, DWORD* err);
    // relaunch.txt for the helper (pid) that waits on the game (game pid). 0 on success, else a Win32 code.
    DWORD write_relaunch(const Layout& l, DWORD game_pid, DWORD helper_pid);
    // Reads and deletes relaunch.txt; true when it names game_pid and helper_pid.
    bool take_relaunch(const Layout& l, DWORD game_pid, DWORD helper_pid);

    // Writes text to path through <path>.tmp (flushed) and a rename. 0 on success, else a Win32 code.
    DWORD write_atomic(const std::wstring& path, const std::string& text);
    // Creates every missing folder of path (absolute). false on failure.
    bool make_dirs(const std::wstring& path);
} // namespace core_stage
