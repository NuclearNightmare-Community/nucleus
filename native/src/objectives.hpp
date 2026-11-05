// The intel objectives natives (objectives.cpp): fill, read back and tick an ObjectiveManager_C's task list, which Lua
// can't write (assigning that struct array from Lua crashes the pinned UE4SS). Names come from CORE_NAME.
#pragma once

#include <string>

#include "core_shared.hpp"

namespace core_native::objectives
{
    extern const std::string g_fn_set;      // <Core>_SetObjectives
    extern const std::string g_fn_describe; // <Core>_DescribeObjectives
    extern const std::string g_fn_traitor;  // <Core>_SetTraitorTaskState

    int l_set_objectives(const Lua& lua);
    int l_describe_objectives(const Lua& lua);
    int l_set_traitor_task_state(const Lua& lua);

    // The struct members the natives resolve by name prefix, in this order (keys as in error messages).
    constexpr int k_member_count = 7;
    extern const char* const k_member_keys[k_member_count];

#ifdef CORE_OBJECTIVES_TEST
    // <Core>_SetObjectives with member `key`'s name prefix replaced by one that can't exist, so it fails exactly as a
    // game patch that removed the member would. Compiled only into core's test DLL (test/SkelNative), never into core.
    // Arguments: (memberKey, managerPath, areaName, id1, text1, ...).
    int set_objectives_with_missing_member(const Lua& lua, const std::string& fn);
#endif
} // namespace core_native::objectives
