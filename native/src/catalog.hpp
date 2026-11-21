// The signed catalog in core's native part (Mod Manager v2 story 2): fetch and verify on one background worker, Lua
// gets results only. Natives (catalog.cpp), registered into every Lua state; none touches a UObject, so any thread may
// call them:
//   <Core>_CatalogRefresh()                 -> job | nil, "busy" | nil, "data folder unknown"
//   <Core>_CatalogDownload(id, version)     -> job | nil, reason
//   <Core>_CatalogPoll(job)                 -> "running" | "done", outcome, message, payloadJson | nil, "unknown job"
//   <Core>_CatalogStage(id1, v1, ..., idN, vN) -> job | nil, reason   (Mod Manager v2 story 5; stage/install.hpp)
//   <Core>_CatalogUnstage(id, version)  -> job | nil, reason   (Mod Manager v2 story 6; stage/install.hpp)
// Names come from CORE_NAME; the rules, outcomes and payloads are in catalog.cpp's header comment.
#pragma once

#include <string>

#include "core_shared.hpp"

namespace core_native::catalog_natives
{
    extern const std::string g_fn_refresh;  // <Core>_CatalogRefresh
    extern const std::string g_fn_download; // <Core>_CatalogDownload
    extern const std::string g_fn_poll;     // <Core>_CatalogPoll
    extern const std::string g_fn_stage;    // <Core>_CatalogStage
    extern const std::string g_fn_unstage;  // <Core>_CatalogUnstage

    int l_refresh(const Lua& lua);
    int l_download(const Lua& lua);
    int l_poll(const Lua& lua);
    int l_stage(const Lua& lua);
    int l_unstage(const Lua& lua);

    // Core's destructor: cancels the job in flight (closing its WinHTTP request aborts it) and joins the worker, so a
    // hot reload never unloads code the worker still runs. Never throws.
    void shutdown();
} // namespace core_native::catalog_natives
