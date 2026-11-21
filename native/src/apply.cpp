// Staged changes in core's DLL (Mod Manager v2 story 3; apply.hpp; api-contract.md "C++ natives").
//
// Every folder comes from this DLL's own path (Mods\<Core>\dlls\main.dll, checked against the install layout; never
// from Lua): ue4ss\<Core>Data\ (stage/plan.hpp, stage/apply.hpp).
//
//   <Core>_ApplyStatus() -> staged, result, txn, reason, path, attempts, changes
//     staged   none | pending (a plan is staged) | waiting (this session's apply helper waits for the game to exit) |
//              applying (apply.lock is held) | interrupted (a journal without "done": the next helper rolls it back)
//     result   none | applied | failed | discarded (apply-result.txt), and its txn, reason, path and attempts; txn is
//              the staged plan's when there is no result; attempts and changes (the staged plan's operations) are
//              decimal strings
//   <Core>_ApplyStart() -> true, or nil, "nothing staged" | "already started" | "applying" | "helper missing" |
//     "command line too long" | "start failed: <code>". Starts the helper in apply mode (restart.cpp's start path:
//     one inherited handle, the same breakaway fallback); it waits with no timeout.
//   <Core>_ApplyAck(txn) -> true (apply-result.txt deleted), or nil, "no result" | "txn mismatch" |
//     "delete failed: <code>". txn must be 32 lowercase hex digits, otherwise a Lua error.
// Status and Start take no arguments ("<fn>: takes no arguments"). Faults never pass the boundary (guarded()).
#include <format>
#include <string>

#include "apply.hpp"
#include "core_config.hpp"
#include "core_shared.hpp"
#include "restart.hpp"
// After the UE4SS headers (core_shared.hpp), so their own Windows setup wins.
#include "stage/apply.hpp"

namespace core_native::apply
{
    const std::string g_fn_status = std::string{CORE_NAME} + "_ApplyStatus";
    const std::string g_fn_start = std::string{CORE_NAME} + "_ApplyStart";
    const std::string g_fn_ack = std::string{CORE_NAME} + "_ApplyAck";

    namespace
    {
        void no_args(const Lua& lua, const std::string& fn)
        {
            if (lua.get_stack_size() != 0) throw ArgError(std::format("{}: takes no arguments", fn));
        }
        Result nil_reason(std::string why)
        {
            Result r;
            r.kind = Result::Kind::NilText;
            r.text = std::move(why);
            return r;
        }
        Result yes()
        {
            Result r;
            r.kind = Result::Kind::Bool;
            r.boolean = true;
            return r;
        }
    } // namespace

    int l_status(const Lua& lua)
    {
        return guarded(lua, g_fn_status, [&] {
            no_args(lua, g_fn_status);
            Result r;
            r.kind = Result::Kind::Texts;
            core_stage::Layout layout;
            restart::Guard guard;
            if (!restart::own_layout(layout))
            {
                r.texts = {"none", "none", "", "", "", "0", "0"};
                return r;
            }
            const core_stage::StagedState st = core_stage::staged_state(layout);
            std::string staged = "none";
            if (st != core_stage::StagedState::None)
            {
                if (st == core_stage::StagedState::Applying) staged = "applying";
                else if (restart::apply_waiting(nullptr)) staged = "waiting";
                else if (st == core_stage::StagedState::Interrupted) staged = "interrupted";
                else staged = "pending";
            }
            std::string plan_txn;
            size_t ops = 0;
            core_stage::staged_summary(layout, plan_txn, ops);
            core_stage::ResultFile res;
            if (core_stage::read_result(layout, res))
            {
                r.texts = {staged, res.outcome, res.txn, res.reason, res.path, std::to_string(res.attempts), std::to_string(ops)};
            }
            else
            {
                r.texts = {staged, "none", plan_txn, "", "", "0", std::to_string(ops)};
            }
            return r;
        });
    }

    int l_start(const Lua& lua)
    {
        return guarded(lua, g_fn_start, [&] {
            no_args(lua, g_fn_start);
            core_stage::Layout layout;
            restart::Guard guard;
            if (!restart::own_layout(layout)) return nil_reason("nothing staged");
            if (restart::apply_waiting(nullptr)) return nil_reason("already started");
            const core_stage::StagedState st = core_stage::staged_state(layout);
            if (st == core_stage::StagedState::Applying) return nil_reason("applying");
            if (st == core_stage::StagedState::None) return nil_reason("nothing staged");
            uint32_t pid = 0;
            const std::string why = restart::start_apply_helper(&pid);
            if (!why.empty())
            {
                logf("apply: helper not started: {}", why);
                return nil_reason(why);
            }
            return yes();
        });
    }

    int l_ack(const Lua& lua)
    {
        return guarded(lua, g_fn_ack, [&] {
            const std::string& fn = g_fn_ack;
            require_args(lua, fn, 1, " (txn)");
            if (!lua.is_string(1)) throw ArgError(std::format("{}: argument 1 (txn) must be a string, got {}", fn, describe_first_arg(lua)));
            const std::string txn{lua.get_string(1)};
            if (!core_stage::is_hex(txn, 32)) throw ArgError(std::format("{}: argument 1 (txn) must be 32 lowercase hex digits", fn));
            core_stage::Layout layout;
            restart::Guard guard;
            core_stage::ResultFile res;
            if (!restart::own_layout(layout) || !core_stage::read_result(layout, res)) return nil_reason("no result");
            if (res.txn != txn) return nil_reason("txn mismatch");
            DWORD e = 0;
            if (!core_stage::delete_result(layout, &e)) return nil_reason(std::format("delete failed: {}", e));
            logf("apply: result {} {} acknowledged", res.outcome, res.txn);
            return yes();
        });
    }
} // namespace core_native::apply
