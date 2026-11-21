// The signed catalog in core's native part (Mod Manager v2 story 2): fetch and verify on one background worker, Lua
// gets results only. Natives (catalog.cpp), registered into every Lua state; none touches a UObject, so any thread may
// call them:
//   <Core>_CatalogRefresh()                 -> job | nil, "busy" | nil, "data folder unknown"
//   <Core>_CatalogDownload(id, version)     -> job | nil, reason
//   <Core>_CatalogPoll(job)                 -> "running" | "done", outcome, message, payloadJson | nil, "unknown job"
// Names come from CORE_NAME; the rules, outcomes and payloads are in catalog.cpp's header comment.
#pragma once

#include <string>

#include "core_shared.hpp"

namespace core_native::catalog_natives
{
    extern const std::string g_fn_refresh;  // <Core>_CatalogRefresh
    extern const std::string g_fn_download; // <Core>_CatalogDownload
    extern const std::string g_fn_poll;     // <Core>_CatalogPoll

    int l_refresh(const Lua& lua);
    int l_download(const Lua& lua);
    int l_poll(const Lua& lua);

    // Core's destructor: cancels the job in flight (closing its WinHTTP request aborts it) and joins the worker, so a
    // hot reload never unloads code the worker still runs. Never throws.
    void shutdown();
} // namespace core_native::catalog_natives
