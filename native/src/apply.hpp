// Staged changes in core's DLL (Mod Manager v2 story 3; api-contract.md "C++ natives", README "Staged changes"): the
// status of a staged change and its last result, starting the relaunch helper in apply mode, and acknowledging a
// result. The helper does the applying (restart_helper.cpp, stage/apply.cpp). Names come from CORE_NAME. None of the
// natives touches a UObject, so any thread may call them.
//   <Core>_ApplyStatus()   -> staged, result, txn, reason, path, attempts, changes (seven strings)
//   <Core>_ApplyStart()    -> true | nil, reason
//   <Core>_ApplyAck(txn)   -> true | nil, "no result" | "txn mismatch" | "delete failed: <code>"
#pragma once

#include <string>

#include "core_shared.hpp"

namespace core_native::apply
{
    extern const std::string g_fn_status; // <Core>_ApplyStatus
    extern const std::string g_fn_start;  // <Core>_ApplyStart
    extern const std::string g_fn_ack;    // <Core>_ApplyAck

    int l_status(const Lua& lua);
    int l_start(const Lua& lua);
    int l_ack(const Lua& lua);
} // namespace core_native::apply
