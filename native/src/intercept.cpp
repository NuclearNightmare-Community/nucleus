// Function interception (core story 43, CAP-13; README "Function interception"). Lua can't stop a Blueprint function or
// change what it returns (UE4SS hooks on Blueprint functions run after the body, docs/cpp-mods.md Q5); this can.
//
// A dependent installs a *rule* as data: a function on the allowlist (compiled in below, each entry pinned to its
// signature), one target object (a weak handle) or any instance (0), and skip or replace with a value (a weak handle).
// One ProcessLocalScriptFunction pre-callback, registered once in unreal_init and unregistered only in the destructor,
// applies the rules on the game thread. It sees every caller of a Blueprint function: ProcessEvent (delegate broadcasts
// such as OnClicked, UMG bindings such as ToolTipWidget, Lua calls) and Blueprint bytecode. It never calls Lua.
//
// Lua globals (<Core> is CORE_NAME; every error is "<fn>: <problem>", guarded, core_shared.hpp):
//   <Core>_FnIntercept(path, target, action, value) -> id     game thread
//   <Core>_FnRelease(id) -> boolean                            game thread
//   <Core>_FnSuspend(id, on)                                   game thread
//   <Core>_FnList() -> string                                  any thread
// The owner of a rule is the calling Lua mod (get_mod_ref), never an argument.
//
// The callback's hot path returns at once when no rule exists (an atomic count), off the game thread, or when the
// called function is none of the (at most four) functions a rule is on. A match re-checks the function's and the
// target's weak pointers (serial check, under SEH), picks the rule (one for this exact target beats an any rule), counts
// the call, and unless the rule is suspended writes the result (nullptr for skip, the value for replace; only when the
// function returns something and RESULT_PARAM is non-null) and prevents the original. Stack.Code is never touched: for
// a script function the caller's code pointer has already moved on. Everything runs inside try/catch: a C++ exception
// or an SEH fault is logged once per rule and the game's function runs; the hook must never throw (UE4SS would remove
// it). g_mutex is held only around reads and writes of the rule table, never across a call into the engine.
//
// Rules (AGENTS.md, "C++ mods"): only LuaMadeSimple and other UE4SS.dll exports, never the Lua C API; no Func swap; no
// native (FUNC_Native) or byte-pattern targets.

#include <excpt.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <format>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#define RC_UNREAL_DISABLE_PROPERTY_DEPRECATION_WARNINGS
#include <Mod/LuaMod.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FFrame.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/UObjectArray.hpp>
#include <Unreal/UObjectGlobals.hpp>

#include "core_config.hpp"
#include "core_shared.hpp"
#include "intercept.hpp"

// After the UE4SS headers, so their own Windows setup wins.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

using namespace RC;
using namespace RC::Unreal;

namespace core_native::intercept
{
    const std::string g_fn_intercept = std::string{CORE_NAME} + "_FnIntercept";
    const std::string g_fn_release = std::string{CORE_NAME} + "_FnRelease";
    const std::string g_fn_suspend = std::string{CORE_NAME} + "_FnSuspend";
    const std::string g_fn_list = std::string{CORE_NAME} + "_FnList";

    namespace
    {
        // ------------------------------------------------------------------ the allowlist (add-only)
        // Each entry is pinned to its signature: no parameters, and a return of nothing or one UWidget object. Install
        // re-validates the live UFunction against it; a mismatch is a game patch and is refused.
        enum class Ret
        {
            None,
            Widget
        };
        struct Entry
        {
            const char* path;
            Ret ret;
        };
        constexpr std::array<Entry, 4> k_allow{{
            {"/Game/Graphics/MainMenu/EnemySelect/EnemySlot_Button.EnemySlot_Button_C:"
             "BndEvt__EnemySlot_Button_Button_48_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature",
             Ret::None},
            {"/Game/Graphics/MainMenu/EnemySelect/EnemySlot_Button.EnemySlot_Button_C:GetToolTipWidget", Ret::Widget},
            {"/Game/Graphics/MainMenu/EnemySelect/BatSlot_Button1.BatSlot_Button1_C:"
             "BndEvt__EnemySlot_Button_Button_48_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature",
             Ret::None},
            {"/Game/Graphics/MainMenu/EnemySelect/BatSlot_Button1.BatSlot_Button1_C:GetToolTipWidget", Ret::Widget},
        }};
        constexpr size_t k_allow_n = k_allow.size();
        constexpr const CharType* k_widget_class = STR("/Script/UMG.Widget");

        constexpr size_t k_max_path = 512;
        constexpr size_t k_max_rules = 64;
        constexpr size_t k_max_per_mod = 16;
        constexpr int64_t k_max_id = (int64_t{1} << 53) - 1;

        enum class Action
        {
            Skip,
            Replace
        };

        struct Rule
        {
            int64_t id{};
            std::string mod;
            size_t entry{};          // allowlist index
            UFunction* fn_raw{};     // compared on the hot path only, never dereferenced there
            FWeakObjectPtr fn_weak{};
            bool any{};
            UObject* target_raw{};
            FWeakObjectPtr target_weak{};
            std::string target_name; // "any" or the object's full name, taken at install (FnList runs on any thread)
            Action action{};
            FWeakObjectPtr value_weak{}; // replace only
            uint64_t seen{};
            uint64_t applied{};
            bool suspended{};
            bool warned_gone{};
            bool warned_fault{};
        };

        std::mutex g_mutex;           // the rule table, the counters and the flags in it; never held across an engine call
        std::vector<Rule> g_rules;    // at most k_max_rules
        int64_t g_next_id = 1;
        std::atomic<size_t> g_count{0};                 // g_rules.size(), for the hot path
        std::array<std::atomic<UFunction*>, k_allow_n> g_hot{}; // per allowlist entry: the function its rules are on, or null
        std::atomic<bool> g_any_suspended{false};
        std::atomic<bool> g_warned_callback{false};


        // At most 64 printable bytes of untrusted text, for an error message.
        auto quote(std::string_view s) -> std::string
        {
            std::string out;
            for (unsigned char c : s.substr(0, 64)) out += (c >= 0x20 && c <= 0x7E) ? static_cast<char>(c) : '?';
            if (s.size() > 64) out += "...";
            return out;
        }

        bool same_weak(const FWeakObjectPtr& a, const FWeakObjectPtr& b)
        {
            return a.ObjectIndex == b.ObjectIndex && a.ObjectSerialNumber == b.ObjectSerialNumber;
        }

        // ------------------------------------------------------------------ SEH guards (plain values only)

        // A weak pointer for an object proven live by the caller (a StaticFindObject hit): built from the object's own
        // index, checked against its GUObjectArray slot. 1 = built, 0 = the slot doesn't hold obj, -1 = SEH fault.
        int make_weak_raw(UObject* obj, int32_t* index, int32_t* serial, unsigned long* fault)
        {
            *fault = 0;
            __try
            {
                const int32_t i = obj->GetInternalIndex();
                if (i < 0) return 0;
                auto* item = FUObjectArray::IndexToObject(i);
                if (!item || item->GetUObject() != obj) return 0;
                *index = i;
                *serial = FUObjectArray::AllocateSerialNumber(i);
                return 1;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                *fault = GetExceptionCode();
                return -1;
            }
        }

        // A GUObjectArray slot as evidence (core story 43 review): the item's raw words, the object there, its serial and
        // flags. 1 = read, 0 = no item, -1 = SEH fault.
        struct SlotDump
        {
            uint64_t q[3];
            void* obj;
            int32_t serial;
            int32_t refs;
            int root;
            int unreachable;
            int garbage;
        };
        int dump_slot_raw(int32_t index, SlotDump* d, unsigned long* fault)
        {
            *fault = 0;
            __try
            {
                auto* item = FUObjectArray::IndexToObject(index);
                if (!item) return 0;
                const auto* q = reinterpret_cast<const uint64_t*>(item);
                d->q[0] = q[0];
                d->q[1] = q[1];
                d->q[2] = q[2];
                d->obj = item->GetUObject();
                d->serial = item->GetSerialNumber();
                d->refs = item->GetRefCount();
                d->root = item->IsRootSet() ? 1 : 0;
                d->unreachable = item->IsUnreachable() ? 1 : 0;
                d->garbage = item->HasAnyFlags(static_cast<EInternalObjectFlags>(1 << 21)) ? 1 : 0;
                return 1;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                *fault = GetExceptionCode();
                return -1;
            }
        }
        auto slot_text(const FWeakObjectPtr& w) -> std::string
        {
            SlotDump d{};
            unsigned long fault{};
            const int got = dump_slot_raw(w.ObjectIndex, &d, &fault);
            if (got < 0) return std::format("slot {} unreadable (SEH 0x{:08X})", w.ObjectIndex, fault);
            if (got == 0) return std::format("slot {} has no item", w.ObjectIndex);
            return std::format("slot {} serial {} (held {}) object {} root={} unreachable={} garbage={} refs={} item=[{:016X} {:016X} {:016X}]", w.ObjectIndex,
                               d.serial, w.ObjectSerialNumber, d.obj, d.root, d.unreachable, d.garbage, d.refs, d.q[0], d.q[1], d.q[2]);
        }

        unsigned long write_result_raw(void* result, UObject* value)
        {
            __try
            {
                *static_cast<UObject**>(result) = value;
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                return GetExceptionCode();
            }
        }

        // ------------------------------------------------------------------ keeping a replacement alive
        // Not SetRootSet. On UE 5.6 the garbage collector takes its roots from GRoots, a set that only the engine's own
        // FUObjectItem::SetRootFlags (AddToRoot) fills, and its keep-flag pass skips objects that carry RootSet ("tracked
        // with GRoots"); UE4SS's FUObjectItem::SetRootSet only ORs the flag bit, so an object rooted that way is collected
        // by the next GC (story 43 review: VM evidence in the story's change log). SetRootFlags isn't exported. So core
        // keeps a replacement the way the engine's UGameInstance::RegisterReferencedObject does: an entry in the game
        // instance's reflected UPROPERTY TArray<TObjectPtr<UObject>> ReferencedObjects, which the GC traces for as long
        // as the game instance lives (the whole process). Counted per object (index and serial), so two rules may share
        // one; an entry core didn't add is never touched.
        struct Held
        {
            int count{};
            bool added{};
            UObject* raw{};         // compared only, never dereferenced
            FWeakObjectPtr gi{};    // the game instance holding the entry
            int32_t offset{};       // ReferencedObjects in the game instance
        };
        std::mutex g_hold_mutex;
        std::unordered_map<uint64_t, Held> g_held;
        uint64_t hold_key(const FWeakObjectPtr& w)
        {
            return (static_cast<uint64_t>(static_cast<uint32_t>(w.ObjectIndex)) << 32) | static_cast<uint32_t>(w.ObjectSerialNumber);
        }

        constexpr const CharType* k_gi_class = STR("/Script/Engine.GameInstance");
        constexpr const CharType* k_gps_cdo = STR("/Script/Engine.Default__GameplayStatics");
        constexpr const CharType* k_gps_get_gi = STR("/Script/Engine.GameplayStatics:GetGameInstance");

        // UGameInstance and its ReferencedObjects (an array of object pointers), or a std::runtime_error.
        auto gi_layout() -> std::pair<UClass*, FArrayProperty*>
        {
            auto* cls = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, k_gi_class);
            if (!cls) throw std::runtime_error("GameInstance class not found");
            auto* arr = CastField<FArrayProperty>(cls->FindProperty(FName(STR("ReferencedObjects"), FNAME_Find)));
            auto* inner = arr ? CastField<FObjectProperty>(arr->GetInner()) : nullptr;
            if (!arr || !inner || inner->GetElementSize() != static_cast<int32_t>(sizeof(void*)) || arr->GetOffset_Internal() <= 0)
            {
                throw std::runtime_error("GameInstance.ReferencedObjects is not an array of object pointers");
            }
            return {cls, arr};
        }

        unsigned long process_event_raw(UObject* obj, UFunction* function, void* parms)
        {
            __try
            {
                obj->ProcessEvent(function, parms);
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                return GetExceptionCode();
            }
        }

        // The game instance that will hold value: its outer chain first (a replacement made with the game instance as its
        // outer, as the README asks), else GameplayStatics:GetGameInstance with value as the world context. nullptr when
        // there is none. Game thread; value proven live.
        auto game_instance_for(const std::string& fn, UObject* value, UClass* gi_class) -> UObject*
        {
            int steps = 0;
            for (UObject* o = value; o && steps < 64; o = o->GetOuterPrivate(), ++steps)
            {
                if (o->IsA(gi_class)) return o;
            }
            auto* cdo = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, k_gps_cdo);
            auto* function = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, k_gps_get_gi);
            if (!cdo || !function) return nullptr;
            FProperty* ctx = function->FindProperty(FName(STR("WorldContextObject"), FNAME_Find));
            FProperty* ret = function->GetReturnProperty();
            const int32_t size = function->GetParmsSize();
            constexpr int32_t k_buffer = 64;
            if (!ctx || !ret || size <= 0 || size > k_buffer || ctx->GetOffset_Internal() < 0 || ctx->GetOffset_Internal() + 8 > size ||
                ret->GetOffset_Internal() < 0 || ret->GetOffset_Internal() + 8 > size)
            {
                return nullptr;
            }
            alignas(16) uint8_t parms[k_buffer]{};
            *reinterpret_cast<UObject**>(parms + ctx->GetOffset_Internal()) = value;
            const auto fault = process_event_raw(cdo, function, parms);
            if (fault)
            {
                log_fault(fn, "asking GameplayStatics for the game instance", fault, 0);
                return nullptr;
            }
            UObject* gi = *reinterpret_cast<UObject**>(parms + ret->GetOffset_Internal());
            return gi && gi->IsA(gi_class) ? gi : nullptr;
        }

        struct RawArray
        {
            void* data;
            int32_t num;
            int32_t max;
        };

        // Removes one entry equal to raw from the game instance's ReferencedObjects without reallocating (the last entry
        // takes its place), so a reader on another thread only ever sees valid pointers. 1 = removed, 0 = not there or
        // the game instance is gone, -1 = SEH fault.
        int unhold_raw(const FWeakObjectPtr* gi_weak, int32_t offset, UObject* raw, unsigned long* fault)
        {
            *fault = 0;
            __try
            {
                UObject* gi = gi_weak->Get();
                if (!gi) return 0;
                auto* a = reinterpret_cast<RawArray*>(reinterpret_cast<uint8_t*>(gi) + offset);
                if (a->num <= 0 || a->num > a->max || !a->data) return 0;
                auto** items = static_cast<UObject**>(a->data);
                for (int32_t i = a->num - 1; i >= 0; --i)
                {
                    if (items[i] != raw) continue;
                    items[i] = items[a->num - 1];
                    items[a->num - 1] = nullptr;
                    --a->num;
                    return 1;
                }
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                *fault = GetExceptionCode();
                return -1;
            }
        }

        // Game thread (install). gi was found by game_instance_for and is live.
        void hold(const FWeakObjectPtr& value, UObject* raw, UObject* gi)
        {
            const uint64_t key = hold_key(value);
            {
                std::lock_guard lock(g_hold_mutex);
                auto& h = g_held[key];
                if (h.count++ > 0) return;
                h.raw = raw;
            }
            bool added = false;
            int32_t offset = 0;
            FWeakObjectPtr gi_weak{};
            try
            {
                int32_t gi_index{}, gi_serial{};
                unsigned long fault{};
                if (make_weak_raw(gi, &gi_index, &gi_serial, &fault) != 1) throw std::runtime_error("the game instance is not in GUObjectArray");
                gi_weak.ObjectIndex = gi_index;
                gi_weak.ObjectSerialNumber = gi_serial;
                auto [cls, arr] = gi_layout();
                offset = arr->GetOffset_Internal();
                FScriptArrayHelper helper(arr, arr->ContainerPtrToValuePtr<void>(gi));
                const int32_t i = helper.AddValue();
                *reinterpret_cast<UObject**>(helper.GetRawPtr(i)) = raw;
                added = true;
            }
            catch (const std::exception& e)
            {
                logf("intercept: WARN could not hold a replacement in the game instance ({}); it may be collected", e.what());
            }
            std::lock_guard lock(g_hold_mutex);
            auto it = g_held.find(key);
            if (it != g_held.end())
            {
                it->second.added = added;
                it->second.gi = gi_weak;
                it->second.offset = offset;
            }
        }

        // Any thread (release, a stopping Lua mod, unload).
        void unhold(const FWeakObjectPtr& value)
        {
            const uint64_t key = hold_key(value);
            Held h{};
            {
                std::lock_guard lock(g_hold_mutex);
                auto it = g_held.find(key);
                if (it == g_held.end()) return;
                if (--it->second.count > 0) return;
                h = it->second;
                g_held.erase(it);
            }
            if (!h.added || h.offset <= 0) return;
            unsigned long fault{};
            if (unhold_raw(&h.gi, h.offset, h.raw, &fault) < 0) log_fault(g_fn_release, "letting a replacement object go", fault, key);
        }

        // ------------------------------------------------------------------ the table (call with g_mutex held)
        void refresh_hot_locked()
        {
            for (size_t e = 0; e < k_allow_n; ++e)
            {
                UFunction* f = nullptr;
                for (const auto& r : g_rules)
                {
                    if (r.entry == e)
                    {
                        f = r.fn_raw;
                        break;
                    }
                }
                g_hot[e].store(f, std::memory_order_release);
            }
            g_count.store(g_rules.size(), std::memory_order_release);
        }

        auto find_locked(int64_t id) -> Rule*
        {
            for (auto& r : g_rules)
            {
                if (r.id == id) return &r;
            }
            return nullptr;
        }

        // Removes the rules pred selects; returns their value pointers (replace rules) for letting go outside the lock.
        template <typename Pred>
        auto take_locked(Pred pred, size_t* n) -> std::vector<FWeakObjectPtr>
        {
            std::vector<FWeakObjectPtr> values;
            *n = 0;
            for (auto it = g_rules.begin(); it != g_rules.end();)
            {
                if (pred(*it))
                {
                    if (it->action == Action::Replace) values.push_back(it->value_weak);
                    ++*n;
                    it = g_rules.erase(it);
                }
                else
                {
                    ++it;
                }
            }
            refresh_hot_locked();
            return values;
        }

        // ------------------------------------------------------------------ arguments
        auto caller_mod(const Lua& lua, const std::string& fn) -> std::string
        {
            auto* mod = get_mod_ref(lua);
            if (!mod) throw std::runtime_error(std::format("{}: could not tell which mod is calling", fn));
            std::string name = to_string(StringType{mod->get_name()});
            if (name.empty()) throw std::runtime_error(std::format("{}: the calling mod has no name", fn));
            return name;
        }

        auto take_id(const Lua& lua, const std::string& fn, int32_t index) -> int64_t
        {
            if (!lua.is_integer(1)) throw ArgError(std::format("{}: argument {} (id) must be an integer, got {}", fn, index, describe_first_arg(lua)));
            const int64_t id = lua.get_integer(1);
            if (id < 1 || id > k_max_id) throw ArgError(std::format("{}: id {} is out of range (1..{})", fn, id, k_max_id));
            return id;
        }

        auto class_name(UObject* cls) -> std::string
        {
            return cls ? to_string(cls->GetName()) : std::string{"?"};
        }

        // The live object behind a handle: unknown, freed or gone -> an error naming what.
        auto handle_object(const std::string& fn, const char* what, int64_t handle, FWeakObjectPtr* weak) -> UObject*
        {
            if (!handle_weak(handle, weak)) throw ArgError(std::format("{}: {} handle {} is not a live object (unknown or freed)", fn, what, handle));
            unsigned long fault{};
            UObject* obj = weak_get(weak, &fault);
            if (fault)
            {
                log_fault(fn, "resolving a handle", fault, static_cast<uint64_t>(handle));
                throw ArgError(std::format("{}: internal fault while resolving {} handle {} (logged)", fn, what, handle));
            }
            if (!obj) throw ArgError(std::format("{}: {} handle {} is not a live object (gone)", fn, what, handle));
            return obj;
        }

        // The live UFunction against its allowlist entry. Throws a "changed its signature" refusal on a mismatch.
        auto check_signature(const std::string& fn, const std::string& path, UFunction* f, const Entry& entry) -> UClass*
        {
            auto refuse = [&](const std::string& why) {
                const std::string msg = std::format("{}: {} changed its signature ({}); refused (a game patch? the allowlist needs a new entry)", fn, path, why);
                logf("intercept: REFUSED {}", msg);
                throw ArgError(msg);
            };
            if (f->HasAnyFunctionFlags(FUNC_Native)) refuse("it is native now");
            FProperty* ret = nullptr;
            int returns = 0;
            for (FProperty* p : TFieldRange<FProperty>(f, EFieldIterationFlags::IncludeDeprecated))
            {
                if (!p->HasAnyPropertyFlags(CPF_Parm)) continue;
                if (p->HasAnyPropertyFlags(CPF_ReturnParm))
                {
                    ++returns;
                    ret = p;
                }
                else
                {
                    refuse(std::format("it takes parameter {}", to_string(p->GetName())));
                }
            }
            if (entry.ret == Ret::None)
            {
                if (returns != 0) refuse("it returns a value now");
                return nullptr;
            }
            if (returns != 1 || !ret) refuse("it returns nothing now");
            auto* op = CastField<FObjectProperty>(ret);
            if (!op) refuse("it returns something other than an object now");
            UClass* pc = op->GetPropertyClass().Get();
            auto* widget = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, k_widget_class);
            if (!widget || pc != widget) refuse(std::format("it returns a {} instead of a Widget", class_name(pc)));
            return widget;
        }

        void warn_rule(int64_t id, bool Rule::* flag, const std::string& line)
        {
            {
                std::lock_guard lock(g_mutex);
                Rule* r = find_locked(id);
                if (!r || r->*flag) return;
                r->*flag = true;
            }
            logf("intercept: WARN {}", line);
        }

        // ------------------------------------------------------------------ the callback's match path
        struct Pick
        {
            bool set{};
            int64_t id{};
            bool any{};
            FWeakObjectPtr fn_weak{};
            FWeakObjectPtr target_weak{};
            FWeakObjectPtr value_weak{};
            Action action{};
            Ret ret{};
        };

        void apply(Hook::TCallbackIterationData<void>& data, UObject* context, UFunction* node, void* result)
        {
            Pick exact{}, any{};
            {
                std::lock_guard lock(g_mutex);
                for (const auto& r : g_rules)
                {
                    if (r.fn_raw != node) continue;
                    Pick* p = r.any ? &any : (r.target_raw == context ? &exact : nullptr);
                    if (!p) continue;
                    *p = Pick{true, r.id, r.any, r.fn_weak, r.target_weak, r.value_weak, r.action, k_allow[r.entry].ret};
                }
            }
            if (!exact.set && !any.set) return;

            // The weak pointers again (serial check): the function and the target are still the objects the rule was
            // made for, never another object that took over the address.
            Pick* chosen = nullptr;
            unsigned long fault{};
            if (exact.set)
            {
                UObject* f = weak_get(&exact.fn_weak, &fault);
                UObject* t = fault ? nullptr : weak_get(&exact.target_weak, &fault);
                if (fault)
                {
                    warn_rule(exact.id, &Rule::warned_fault, std::format("rule {}: SEH fault 0x{:08X} while checking it; the game's function runs (logged once per rule)", exact.id, fault));
                    return;
                }
                if (f == node && t == context) chosen = &exact;
            }
            if (!chosen && any.set)
            {
                UObject* f = weak_get(&any.fn_weak, &fault);
                if (fault)
                {
                    warn_rule(any.id, &Rule::warned_fault, std::format("rule {}: SEH fault 0x{:08X} while checking it; the game's function runs (logged once per rule)", any.id, fault));
                    return;
                }
                if (f == node) chosen = &any;
            }
            if (!chosen) return;

            bool suspended = false;
            {
                std::lock_guard lock(g_mutex);
                Rule* r = find_locked(chosen->id);
                if (!r) return; // released meanwhile
                ++r->seen;
                suspended = r->suspended;
            }
            if (suspended) return;

            UObject* out = nullptr;
            if (chosen->action == Action::Replace)
            {
                out = weak_get(&chosen->value_weak, &fault);
                if (fault || !out)
                {
                    warn_rule(chosen->id, fault ? &Rule::warned_fault : &Rule::warned_gone,
                              fault ? std::format("rule {}: SEH fault 0x{:08X} while resolving its value; the game's function runs (logged once per rule)", chosen->id, fault)
                                    : std::format("rule {}: its replacement object is gone ({}); the game's function runs (logged once per rule)", chosen->id,
                                                  slot_text(chosen->value_weak)));
                    return;
                }
            }
            if (chosen->ret != Ret::None && result)
            {
                const unsigned long wf = write_result_raw(result, out);
                if (wf)
                {
                    warn_rule(chosen->id, &Rule::warned_fault, std::format("rule {}: SEH fault 0x{:08X} while writing the result; the game's function runs (logged once per rule)", chosen->id, wf));
                    return;
                }
            }
            data.PreventOriginalFunctionCall();
            std::lock_guard lock(g_mutex);
            if (Rule* r = find_locked(chosen->id)) ++r->applied;
        }

        auto line_of(const Rule& r) -> std::string
        {
            return std::format("id={} mod={} fn={} target={} action={} seen={} applied={} suspended={}", r.id, r.mod, k_allow[r.entry].path, r.target_name,
                               r.action == Action::Skip ? "skip" : "replace", r.seen, r.applied, r.suspended ? "true" : "false");
        }
    } // namespace

    // ------------------------------------------------------------------ the callbacks

    void plsf_pre(Hook::TCallbackIterationData<void>& data, UObject* context, FFrame& stack, void* result)
    {
        if (g_count.load(std::memory_order_acquire) == 0) return;
        try
        {
            if (!g_game_thread_known.load(std::memory_order_acquire) || std::this_thread::get_id() != g_game_thread) return;
            UFunction* node = stack.Node();
            if (!node) return;
            bool hit = false;
            for (const auto& h : g_hot)
            {
                if (h.load(std::memory_order_acquire) == node)
                {
                    hit = true;
                    break;
                }
            }
            if (!hit) return;
            apply(data, context, node, result);
        }
        catch (const std::exception& e)
        {
            if (!g_warned_callback.exchange(true)) logf("intercept: WARN the callback caught a C++ exception ({}); the game's function ran (logged once)", e.what());
        }
        catch (...)
        {
            if (!g_warned_callback.exchange(true)) logf("intercept: WARN the callback caught an unknown C++ exception; the game's function ran (logged once)");
        }
    }

    void tick_pre(Hook::TCallbackIterationData<void>&, UEngine*, float, bool)
    {
        try
        {
            if (!g_any_suspended.exchange(false, std::memory_order_acq_rel)) return;
            std::lock_guard lock(g_mutex);
            for (auto& r : g_rules) r.suspended = false;
        }
        catch (...)
        {
            // Never throw from an engine hook (UE4SS would remove it); nothing here can, short of a broken mutex.
        }
    }

    size_t release_mod(const std::string& mod)
    {
        try
        {
            size_t n{};
            std::vector<FWeakObjectPtr> values;
            {
                std::lock_guard lock(g_mutex);
                values = take_locked([&](const Rule& r) { return r.mod == mod; }, &n);
            }
            for (const auto& v : values) unhold(v);
            return n;
        }
        catch (...)
        {
            logf("ERROR intercept: releasing the rules of {} failed (unknown exception)", mod);
            return 0;
        }
    }

    size_t release_all()
    {
        try
        {
            size_t n{};
            std::vector<FWeakObjectPtr> values;
            {
                std::lock_guard lock(g_mutex);
                values = take_locked([](const Rule&) { return true; }, &n);
            }
            for (const auto& v : values) unhold(v);
            return n;
        }
        catch (...)
        {
            logf("ERROR intercept: releasing every rule failed (unknown exception)");
            return 0;
        }
    }

    // ------------------------------------------------------------------ the natives

    // <Core>_FnIntercept(path, target, action, value) -> id
    int l_intercept(const Lua& lua)
    {
        const std::string& fn = g_fn_intercept;
        return guarded(lua, fn, [&] {
            require_game_thread(fn);
            require_args(lua, fn, 4, " (path, target, action, value)");
            // Arguments are taken from the bottom of the stack: each read removes argument 1.
            if (!lua.is_string(1)) throw ArgError(std::format("{}: argument 1 (path) must be a string, got {}", fn, describe_first_arg(lua)));
            const std::string path{lua.get_string(1)};
            if (!lua.is_integer(1)) throw ArgError(std::format("{}: argument 2 (target) must be an integer (a handle, or 0 for any instance), got {}", fn, describe_first_arg(lua)));
            const int64_t target = lua.get_integer(1);
            if (!lua.is_string(1)) throw ArgError(std::format("{}: argument 3 (action) must be a string, got {}", fn, describe_first_arg(lua)));
            const std::string action_text{lua.get_string(1)};
            bool value_nil = false;
            int64_t value = 0;
            if (lua.is_nil(1))
            {
                lua.discard_value(1);
                value_nil = true;
            }
            else if (lua.is_integer(1))
            {
                value = lua.get_integer(1);
            }
            else
            {
                throw ArgError(std::format("{}: argument 4 (value) must be nil or an integer handle, got {}", fn, describe_first_arg(lua)));
            }

            if (path.empty() || path.size() > k_max_path) throw ArgError(std::format("{}: path must be 1..{} bytes, got {}", fn, k_max_path, path.size()));
            size_t entry = k_allow_n;
            for (size_t i = 0; i < k_allow_n; ++i)
            {
                if (path == k_allow[i].path) entry = i;
            }
            if (entry == k_allow_n) throw ArgError(std::format("{}: '{}' is not on the allowlist", fn, quote(path)));
            if (target < 0 || target > k_max_id) throw ArgError(std::format("{}: target handle {} is out of range (0 for any instance, or 1..{})", fn, target, k_max_id));
            Action action{};
            if (action_text == "skip") action = Action::Skip;
            else if (action_text == "replace") action = Action::Replace;
            else throw ArgError(std::format("{}: action must be 'skip' or 'replace', got '{}'", fn, quote(action_text)));
            if (action == Action::Skip && !value_nil) throw ArgError(std::format("{}: value must be nil for 'skip'", fn));
            if (action == Action::Replace)
            {
                if (k_allow[entry].ret == Ret::None) throw ArgError(std::format("{}: 'replace' needs a function that returns an object; {} returns nothing", fn, path));
                if (value_nil) throw ArgError(std::format("{}: 'replace' needs a value (a live handle)", fn));
                if (value < 1 || value > k_max_id) throw ArgError(std::format("{}: value handle {} is out of range (1..{})", fn, value, k_max_id));
            }
            const std::string owner = caller_mod(lua, fn);

            // One StaticFindObject; a miss means the class isn't loaded (or the game renamed the function).
            UFunction* f{};
            try
            {
                f = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, ensure_str(path));
            }
            catch (const std::exception&)
            {
                f = nullptr;
            }
            if (!f) throw ArgError(std::format("{}: {} is not loaded (open the screen that uses it first)", fn, path));
            UClass* ret_class = check_signature(fn, path, f, k_allow[entry]);
            int32_t fi{}, fs{};
            unsigned long fault{};
            const int made = make_weak_raw(f, &fi, &fs, &fault);
            if (made < 0)
            {
                log_fault(fn, "making a weak pointer to the function", fault, 0);
                throw ArgError(std::format("{}: internal fault while reading the function (logged); nothing was installed", fn));
            }
            if (made == 0) throw ArgError(std::format("{}: {} is not a live function (being unloaded?)", fn, path));
            FWeakObjectPtr fn_weak{};
            fn_weak.ObjectIndex = fi;
            fn_weak.ObjectSerialNumber = fs;
            auto* fn_class = static_cast<UClass*>(f->GetOuterPrivate());

            Rule rule{};
            rule.mod = owner;
            rule.entry = entry;
            rule.fn_raw = f;
            rule.fn_weak = fn_weak;
            rule.action = action;
            if (target == 0)
            {
                rule.any = true;
                rule.target_name = "any";
            }
            else
            {
                UObject* t = handle_object(fn, "target", target, &rule.target_weak);
                if (!fn_class || !t->IsA(fn_class)) throw ArgError(std::format("{}: target {} is not a {}", fn, quote(to_string(t->GetName())), class_name(fn_class)));
                rule.target_raw = t;
                rule.target_name = to_string(t->GetFullName());
            }
            UObject* value_raw = nullptr;
            UObject* holder = nullptr;
            if (action == Action::Replace)
            {
                UObject* v = handle_object(fn, "value", value, &rule.value_weak);
                if (!v->IsA(ret_class)) throw ArgError(std::format("{}: value {} is not a {}", fn, quote(to_string(v->GetName())), class_name(ret_class)));
                // The game instance keeps it alive while the rule holds it (see "keeping a replacement alive").
                holder = game_instance_for(fn, v, gi_layout().first);
                if (!holder) throw ArgError(std::format("{}: value {} has no game instance to keep it alive (create it with the game instance as its outer)", fn, quote(to_string(v->GetName()))));
                value_raw = v;
            }

            FWeakObjectPtr old_value{};
            bool had_old_value = false;
            Result r;
            r.kind = Result::Kind::Integer;
            {
                std::lock_guard lock(g_mutex);
                Rule* same = nullptr;
                size_t mine = 0;
                for (auto& x : g_rules)
                {
                    if (x.mod == owner) ++mine;
                    if (x.fn_raw == f && x.any == rule.any && (rule.any || same_weak(x.target_weak, rule.target_weak))) same = &x;
                }
                if (same && same->mod != owner)
                {
                    throw ArgError(std::format("{}: {} on {} is already intercepted by {}", fn, path, rule.target_name, same->mod));
                }
                if (same)
                {
                    // The same mod and key: the rule is replaced and keeps its id (and its counters).
                    rule.id = same->id;
                    rule.seen = same->seen;
                    rule.applied = same->applied;
                    if (same->action == Action::Replace)
                    {
                        old_value = same->value_weak;
                        had_old_value = true;
                    }
                    *same = rule;
                }
                else
                {
                    if (g_rules.size() >= k_max_rules) throw ArgError(std::format("{}: too many rules ({} in all); release some with {}", fn, k_max_rules, g_fn_release));
                    if (mine >= k_max_per_mod) throw ArgError(std::format("{}: {} has too many rules ({} per mod); release some with {}", fn, owner, k_max_per_mod, g_fn_release));
                    if (g_next_id > k_max_id) throw ArgError(std::format("{}: rule id space exhausted", fn));
                    rule.id = g_next_id++;
                    g_rules.push_back(rule);
                }
                refresh_hot_locked();
                r.integer = rule.id;
            }
            // New value first, then the old one: a rule that keeps its object never drops to zero holds.
            if (action == Action::Replace) hold(rule.value_weak, value_raw, holder);
            if (had_old_value) unhold(old_value);
            return r;
        });
    }

    // <Core>_FnRelease(id) -> true (the caller's own rule, released), false (unknown id); another mod's rule: an error.
    int l_release(const Lua& lua)
    {
        const std::string& fn = g_fn_release;
        return guarded(lua, fn, [&] {
            require_game_thread(fn);
            require_args(lua, fn, 1, " (id)");
            const int64_t id = take_id(lua, fn, 1);
            const std::string owner = caller_mod(lua, fn);
            Result r;
            r.kind = Result::Kind::Bool;
            std::vector<FWeakObjectPtr> values;
            {
                std::lock_guard lock(g_mutex);
                Rule* x = find_locked(id);
                if (!x) return r; // false
                if (x->mod != owner) throw ArgError(std::format("{}: rule {} belongs to {}, not {}", fn, id, x->mod, owner));
                size_t n{};
                values = take_locked([&](const Rule& y) { return y.id == id; }, &n);
            }
            for (const auto& v : values) unhold(v);
            r.boolean = true;
            return r;
        });
    }

    // <Core>_FnSuspend(id, on): the caller's own rule; every suspension is cleared at the next engine tick.
    int l_suspend(const Lua& lua)
    {
        const std::string& fn = g_fn_suspend;
        return guarded(lua, fn, [&] {
            require_game_thread(fn);
            require_args(lua, fn, 2, " (id, on)");
            const int64_t id = take_id(lua, fn, 1);
            if (!lua.is_bool(1)) throw ArgError(std::format("{}: argument 2 (on) must be a boolean, got {}", fn, describe_first_arg(lua)));
            const bool on = lua.get_bool(1);
            const std::string owner = caller_mod(lua, fn);
            std::lock_guard lock(g_mutex);
            Rule* x = find_locked(id);
            if (!x) throw ArgError(std::format("{}: no rule {}", fn, id));
            if (x->mod != owner) throw ArgError(std::format("{}: rule {} belongs to {}, not {}", fn, id, x->mod, owner));
            x->suspended = on;
            if (on) g_any_suspended.store(true, std::memory_order_release);
            return Result{};
        });
    }

    // <Core>_FnList() -> one line per rule (any thread; touches no UObject).
    int l_list(const Lua& lua)
    {
        const std::string& fn = g_fn_list;
        return guarded(lua, fn, [&] {
            require_args(lua, fn, 0, "");
            Result r;
            r.kind = Result::Kind::String;
            std::lock_guard lock(g_mutex);
            for (const auto& x : g_rules)
            {
                if (!r.text.empty()) r.text += '\n';
                r.text += line_of(x);
            }
            return r;
        });
    }
} // namespace core_native::intercept
