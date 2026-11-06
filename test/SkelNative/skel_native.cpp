// <Core>SkelNative: core's test-only C++ part (never shipped; deploy.ps1 -Test installs it for the bad-input scenario).
// It compiles core's own objectives.cpp with CORE_OBJECTIVES_TEST and registers one Lua global into every Lua mod:
//   <Core>SkelNative_SetObjectivesMissing(memberKey, managerPath, areaName, id1, text1, ...)
// which runs <Core>_SetObjectives' own code with one struct member's name prefix replaced by one that can't exist
// (memberKey: Actors, Tasks, State, Description, UniqueIdentifier, TraitorDescription, TraitorState). It must fail
// exactly as a game patch that removed the member would, and write nothing (map-setup.md, "bad-input cases": the
// forced missing struct member, kept out of core's public natives).
// Rules (AGENTS.md, "C++ mods"): as core's DLL.

#include <string>
#include <vector>

#include <Mod/CppUserModBase.hpp>

#include "core_shared.hpp"
#include "core_config.hpp"
#include "objectives.hpp"

using namespace RC;
using namespace RC::Unreal;
using namespace core_native;

namespace
{
    const std::string g_name = std::string{CORE_NAME} + "SkelNative";
    const std::string g_fn_missing = g_name + "_SetObjectivesMissing";

    int l_set_missing(const Lua& lua)
    {
        return objectives::set_objectives_with_missing_member(lua, g_fn_missing);
    }
} // namespace

class CoreSkelNative : public CppUserModBase
{
    std::vector<Hook::GlobalCallbackId> m_hooks;

  public:
    CoreSkelNative() : CppUserModBase()
    {
        g_log_tag = g_name;
        ModName = ensure_str(g_name);
        ModVersion = ensure_str(std::string{CORE_VERSION});
        ModDescription = STR("Core's test-only native part (bad-input: forced missing struct member)");
        ModAuthors = STR("nuclear-nightmare workspace");
        logf("loaded (test only), core {}", CORE_VERSION);

        register_on_unreal_init([](CppUserModBase* self) {
            try
            {
                auto* me = static_cast<CoreSkelNative*>(self);
                me->m_hooks.push_back(Hook::RegisterEngineTickPreCallback(&engine_tick_pre, {true, true, ensure_str(g_name), STR("engine_tick_pre")}));
            }
            catch (const std::exception& e)
            {
                logf("ERROR unreal init: {}", e.what());
            }
            catch (...)
            {
                logf("ERROR unreal init: unknown C++ exception");
            }
        });
        register_on_lua_start([](CppUserModBase*, CStringView, Lua& lua, Lua&, Lua&, Lua*) {
            try
            {
                lua.register_function(g_fn_missing.c_str(), &l_set_missing);
            }
            catch (const std::exception& e)
            {
                logf("ERROR registering natives into a Lua mod: {}", e.what());
            }
            catch (...)
            {
                logf("ERROR registering natives into a Lua mod: unknown C++ exception");
            }
        });
    }

    ~CoreSkelNative() override
    {
        try
        {
            for (auto id : m_hooks)
            {
                Hook::UnregisterCallback(id);
            }
            logf("unloading: unregistered {} hooks", m_hooks.size());
        }
        catch (...)
        {
            logf("ERROR while unloading (unknown exception)");
        }
    }
};

extern "C"
{
    __declspec(dllexport) CppUserModBase* start_mod()
    {
        return new CoreSkelNative();
    }
    __declspec(dllexport) void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
