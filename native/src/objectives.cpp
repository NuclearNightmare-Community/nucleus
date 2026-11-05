// The intel objectives natives: an ObjectiveManager_C's Objectives (a TArray of the game's SObjectiveProperties, each
// with a TArray of STaskProperties), which Lua can't write: assigning that array from Lua crashed the pinned UE4SS (it
// zero-initializes FText members, which the engine treats as invalid; docs/custom-maps.md, stage 5c). Ported from the
// map spike's MapObjectives (mods/map-spike/native) under core's name and boundary rules (map-setup.md, "Native move").
//
// Lua globals (<Core> is CORE_NAME). Every error is a Lua error "<fn>: <problem>" (guarded, core_shared.hpp).
//   <Core>_SetObjectives(managerPath, areaName, id1, text1, ..., idN, textN) -> N
//       Fills the manager's still empty Objectives with one objective whose N tasks are (UniqueIdentifier = id,
//       Description = text, TraitorDescription = text, State = false, TraitorState = false), and sets its Area Name.
//       Once per manager; host only (the array replicates). Area Name RU and RUDescription stay empty.
//   <Core>_DescribeObjectives(managerPath) -> text
//       Reads the manager back, on any machine (read only), as lines (tab-separated; tabs and line breaks inside
//       values become spaces):
//         manager<TAB><objectives><TAB><selected objective><TAB><Objectives replicates 0|1><TAB><area name>
//         task<TAB><objective><TAB><task><TAB><State 0|1><TAB><id><TAB><text><TAB><TraitorState 0|1><TAB><imposter text>
//       Add-only: later versions may append fields to a line or add lines of other kinds; readers ignore both.
//   <Core>_SetTraitorTaskState(managerPath, taskId, state) -> number of tasks set
//       Sets TraitorState of the filled manager's task(s) with that id (the game's UpdateTaskTraitorState sets it on a
//       copy and never writes it back, decompile V8.1.5). Host only.
//
// Boundary: every argument is checked (type, count, size, characters) before anything is looked up; calls off the game
// thread are refused (before the first engine tick they are allowed: the lookup then just finds no manager). The
// manager is named by its object path; StaticFindObject only looks the name up, and the object is then proven live by
// core's GUObjectArray scan and slot state, its flags read under SEH: a CDO or archetype, an object flagged Garbage,
// PendingKill or Unreachable, a non-manager, and (for the writers) a manager in a world that isn't the host's are
// refused. Struct members are found by name prefix, exactly one match each, of the expected type. Array headers are
// read under SEH and checked for plausibility; elements are added through FScriptArrayHelper (the engine initializes
// them) and texts copied through the members' own properties. Every value is built before the first write.
//
// Rules (AGENTS.md, "C++ mods"): only LuaMadeSimple and other UE4SS.dll exports, never the Lua C API.

#include <excpt.h>

#include <cstdint>
#include <format>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

#define RC_UNREAL_DISABLE_PROPERTY_DEPRECATION_WARNINGS
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/FStrProperty.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/FString.hpp>
#include <Unreal/FText.hpp>
#include <Unreal/Property/FTextProperty.hpp>
#include <Unreal/UObjectArray.hpp>
#include <Unreal/UObjectGlobals.hpp>

#include "core_shared.hpp"
#include "core_config.hpp"
#include "objectives.hpp"

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

namespace core_native::objectives
{
    const std::string g_fn_set = std::string{CORE_NAME} + "_SetObjectives";
    const std::string g_fn_describe = std::string{CORE_NAME} + "_DescribeObjectives";
    const std::string g_fn_traitor = std::string{CORE_NAME} + "_SetTraitorTaskState";

    const char* const k_member_keys[k_member_count] = {"Actors", "Tasks", "State", "Description", "UniqueIdentifier", "TraitorDescription", "TraitorState"};

    namespace
    {
        constexpr const CharType* k_manager_class = STR("/Game/Gameplay/ClassifiedMaterials/ObjectiveManager.ObjectiveManager_C");
        constexpr const CharType* k_ksl_cdo = STR("/Script/Engine.Default__KismetSystemLibrary");
        constexpr const CharType* k_ksl_is_server = STR("/Script/Engine.KismetSystemLibrary:IsServer");
        constexpr const CharType* k_ksl_is_standalone = STR("/Script/Engine.KismetSystemLibrary:IsStandalone");

        // Boundary limits (map-setup.md, "Native move" item 3).
        constexpr size_t k_max_path = 512;
        constexpr size_t k_max_area = 128;
        constexpr size_t k_max_id = 64;
        constexpr size_t k_max_text = 256;
        constexpr int32_t k_max_tasks = 64;
        // Plausibility caps for what the game's memory holds (a stock manager has a handful of each).
        constexpr int32_t k_cap_objectives = 1024;
        constexpr int32_t k_cap_tasks = 1024;
        constexpr int32_t k_cap_described_tasks = 4096;

        // Refusals about the manager (the object, its class, its world, the game's layout) are also logged: one line
        // per distinct refusal (up to 256 of them; after that every 256th refusal), so a bad manager is never silent
        // and a caller repeating one never floods the log. A count cap alone let early refusals hide later ones.
        constexpr size_t k_max_logged_refusals = 256;
        std::mutex g_refusals_mutex;
        std::unordered_set<std::string> g_logged_refusals;
        uint32_t g_unlogged_refusals = 0;
        [[noreturn]] void refuse(const std::string& error)
        {
            bool log = false;
            {
                std::lock_guard lock(g_refusals_mutex);
                if (g_logged_refusals.contains(error)) log = false;
                else if (g_logged_refusals.size() < k_max_logged_refusals) log = g_logged_refusals.insert(error).second;
                else log = (++g_unlogged_refusals % 256) == 0;
            }
            if (log) logf("REFUSED {}", error);
            throw ArgError(error);
        }

        // At most 64 printable bytes of untrusted text, for an error message.
        auto quote(std::string_view s) -> std::string
        {
            std::string out;
            for (unsigned char c : s.substr(0, 64)) out += (c >= 0x20 && c <= 0x7E) ? static_cast<char>(c) : '?';
            return out;
        }

        // ------------------------------------------------------------------ arguments

        // Argument `index` (always on top of what is left: each read removes it) must be a Lua string; never coerced.
        auto take_string(const Lua& lua, const std::string& fn, int32_t index, const char* name) -> std::string
        {
            if (!lua.is_string(1)) throw ArgError(std::format("{}: argument {} ({}) must be a string, got {}", fn, index, name, describe_first_arg(lua)));
            // get_string removes the value; copy it at once (nothing runs in between that could collect it).
            return std::string{lua.get_string(1)};
        }

        auto take_bool(const Lua& lua, const std::string& fn, int32_t index, const char* name) -> bool
        {
            if (!lua.is_bool(1)) throw ArgError(std::format("{}: argument {} ({}) must be a boolean, got {}", fn, index, name, describe_first_arg(lua)));
            return lua.get_bool(1);
        }

        bool printable_ascii(const std::string& s)
        {
            for (unsigned char c : s)
            {
                if (c < 0x20 || c > 0x7E) return false;
            }
            return true;
        }

        void check_text(const std::string& fn, const char* what, const std::string& s, size_t max)
        {
            if (s.empty() || s.size() > max) throw ArgError(std::format("{}: {} must be 1..{} characters, got {}", fn, what, max, s.size()));
            if (!printable_ascii(s)) throw ArgError(std::format("{}: {} must be printable ASCII", fn, what));
        }

        void check_id(const std::string& fn, const std::string& s)
        {
            if (s.empty() || s.size() > k_max_id) throw ArgError(std::format("{}: task id must be 1..{} characters, got {}", fn, k_max_id, s.size()));
            for (unsigned char c : s)
            {
                const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
                if (!ok) throw ArgError(std::format("{}: task id '{}' may hold only letters, digits, '_', '-' and '.'", fn, quote(s)));
            }
        }

        void check_path(const std::string& fn, const std::string& s)
        {
            check_text(fn, "manager path", s, k_max_path);
            if (s.front() != '/') throw ArgError(std::format("{}: manager path must be an object path starting with '/'", fn));
        }

        // ------------------------------------------------------------------ SEH guards (plain values only)

        struct RawArray
        {
            void* data;
            int32_t num;
            int32_t max;
        };

        unsigned long read_array_raw(const void* value, void** data, int32_t* num, int32_t* max)
        {
            __try
            {
                const auto* a = static_cast<const RawArray*>(value);
                *data = a->data;
                *num = a->num;
                *max = a->max;
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                return GetExceptionCode();
            }
        }

        unsigned long call_function_raw(UObject* obj, UFunction* function, void* parms)
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

        struct ArrayView
        {
            uint8_t* data{};
            int32_t num{};
            int32_t elem{};
            auto at(int32_t i) const -> uint8_t* { return data + static_cast<size_t>(i) * static_cast<size_t>(elem); }
        };

        // A TArray of the game's, its header read under SEH and checked before any element is touched.
        auto read_array(const std::string& fn, FArrayProperty* prop, const void* value, int32_t cap, const char* what) -> ArrayView
        {
            void* data{};
            int32_t num{}, max{};
            const auto fault = read_array_raw(value, &data, &num, &max);
            if (fault)
            {
                log_fault(fn, what, fault, reinterpret_cast<uint64_t>(value));
                throw ArgError(std::format("{}: internal fault while reading {} (logged); nothing was changed", fn, what));
            }
            if (num < 0 || max < num || num > cap || (num > 0 && !data))
            {
                refuse(std::format("{}: implausible {} (count {}, capacity {})", fn, what, num, max));
            }
            const int32_t elem = prop->GetInner()->GetElementSize();
            if (elem <= 0 || elem > 4096) refuse(std::format("{}: implausible element size {} in {}", fn, elem, what));
            return {static_cast<uint8_t*>(data), num, elem};
        }

        // ------------------------------------------------------------------ the manager

        // The live object at path: looked up by name, then proven by core's GUObjectArray scan (pointer comparison
        // only), its slot state and its flags, all under SEH, before anything reads the object.
        auto live_object(const std::string& fn, const std::string& path) -> UObject*
        {
            UObject* obj{};
            try
            {
                obj = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, ensure_str(path));
            }
            catch (const std::exception& e)
            {
                // UE4SS's lookup throws for a name it can't parse (a path without a '.', for one): nothing is there.
                refuse(std::format("{}: no object at {} ({})", fn, path, e.what()));
            }
            if (!obj) refuse(std::format("{}: no object at {}", fn, path));
            probe_object_array();
            ScanResult scan{};
            const int found = scan_object_array(obj, &scan);
            if (found < 0)
            {
                log_fault(fn, "scanning GUObjectArray", scan.fault, reinterpret_cast<uint64_t>(obj));
                throw ArgError(std::format("{}: internal fault while scanning GUObjectArray (logged); nothing was changed", fn));
            }
            if (found == 0) refuse(std::format("{}: {} isn't a live object (not in GUObjectArray)", fn, path));
            unsigned long fault{};
            const int state = slot_state(scan.index, obj, &fault);
            if (state < 0)
            {
                log_fault(fn, "reading a GUObjectArray slot", fault, static_cast<uint64_t>(scan.index));
                throw ArgError(std::format("{}: internal fault while reading GUObjectArray (logged); nothing was changed", fn));
            }
            if (state == 0) refuse(std::format("{}: {} is being destroyed", fn, path));
            uint32_t bits{};
            const int read = object_flags(scan.index, obj, &bits, &fault);
            if (read < 0)
            {
                log_fault(fn, "reading an object's flags", fault, static_cast<uint64_t>(scan.index));
                throw ArgError(std::format("{}: internal fault while reading an object's flags (logged); nothing was changed", fn));
            }
            if (read == 0) refuse(std::format("{}: {} is being destroyed", fn, path));
            if (bits & OF_Garbage) refuse(std::format("{}: {} is being destroyed (flagged Garbage)", fn, path));
            if (bits & (OF_ClassDefaultObject | OF_Archetype)) refuse(std::format("{}: {} is a class default object or archetype, not a manager in a world", fn, path));
            return obj;
        }

        auto find_manager(const std::string& fn, const std::string& path) -> std::pair<UObject*, UClass*>
        {
            UObject* obj = live_object(fn, path);
            // Not loaded means no manager can exist, so whatever this is, it isn't one.
            auto* cls = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, k_manager_class);
            if (!cls || !obj->IsA(cls)) refuse(std::format("{}: {} isn't an ObjectiveManager_C", fn, path));
            return {obj, cls};
        }

        // KismetSystemLibrary's IsServer / IsStandalone with ctx as the world context, through ProcessEvent.
        bool ksl_bool(const std::string& fn, const CharType* function_path, UObject* ctx)
        {
            auto* ksl = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, k_ksl_cdo);
            auto* function = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, function_path);
            if (!ksl || !function) throw std::runtime_error(std::format("{} not found", to_string(StringType{function_path})));
            FProperty* ctx_prop = function->FindProperty(FName(STR("WorldContextObject"), FNAME_Find));
            auto* ret = CastField<FBoolProperty>(function->GetReturnProperty());
            const int32_t size = function->GetParmsSize();
            constexpr int32_t k_buffer = 64;
            if (!ctx_prop || !ret || size <= 0 || size > k_buffer || ctx_prop->GetElementSize() != static_cast<int32_t>(sizeof(void*)) ||
                ctx_prop->GetOffset_Internal() < 0 || ctx_prop->GetOffset_Internal() + 8 > size || ret->GetOffset_Internal() < 0 || ret->GetOffset_Internal() >= size)
            {
                throw std::runtime_error(std::format("{} has an unexpected signature", to_string(StringType{function_path})));
            }
            alignas(16) uint8_t parms[k_buffer]{};
            *reinterpret_cast<UObject**>(parms + ctx_prop->GetOffset_Internal()) = ctx;
            const auto fault = call_function_raw(ksl, function, parms);
            if (fault)
            {
                log_fault(fn, "asking KismetSystemLibrary for the net mode", fault, 0);
                throw ArgError(std::format("{}: internal fault while reading the net mode (logged); nothing was changed", fn));
            }
            return ret->GetPropertyValueInContainer(parms);
        }

        // The writers act only on the host: IsServer and not IsStandalone (AGENTS.md "Networking", isHost).
        void require_host_world(const std::string& fn, const std::string& path, UObject* manager)
        {
            if (!ksl_bool(fn, k_ksl_is_server, manager)) refuse(std::format("{}: {} isn't in the host's world (net mode: client)", fn, path));
            if (ksl_bool(fn, k_ksl_is_standalone, manager)) refuse(std::format("{}: {} isn't in the host's world (net mode: standalone)", fn, path));
        }

        // ------------------------------------------------------------------ the game's layout, resolved by reflection

        enum Member : int
        {
            M_Actors,
            M_Tasks,
            M_State,
            M_Description,
            M_UniqueIdentifier,
            M_TraitorDescription,
            M_TraitorState,
            M_Count
        };
        static_assert(M_Count == k_member_count);
        // The Blueprint compiler names a struct member <Name>_<number>_<GUID>; only the prefix is stable.
        constexpr const CharType* k_prefixes[M_Count] = {
            STR("Actors_"), STR("Tasks_"), STR("State_"), STR("Description_"), STR("UniqueIdentifier_"), STR("TraitorDescription_"), STR("TraitorState_"),
        };

        struct Layout
        {
            UObject* manager{};
            FArrayProperty* objectives{};
            FTextProperty* area{};
            FIntProperty* selected{};
            UScriptStruct* objective_struct{};
            FArrayProperty* actors{};
            FArrayProperty* tasks{};
            UScriptStruct* task_struct{};
            FBoolProperty* state{};
            FTextProperty* description{};
            FStrProperty* unique_id{};
            FTextProperty* traitor_description{};
            FBoolProperty* traitor_state{};
        };

        // Exactly one member of st whose name starts with search, of type T; else an error naming the member and its
        // real prefix (search differs from it only in core's forced-missing test).
        template <typename T>
        auto member(const std::string& fn, UStruct* st, int m, const CharType* search) -> T*
        {
            const StringViewType want{search};
            const StringViewType real{k_prefixes[m]};
            FProperty* found{};
            int32_t matches = 0;
            for (FProperty* p : TFieldRange<FProperty>(st, EFieldIterationFlags::None))
            {
                const auto name = p->GetName();
                if (StringViewType{name}.starts_with(want))
                {
                    found = p;
                    ++matches;
                }
            }
            const auto st_name = to_string(st->GetName());
            const char* key = k_member_keys[m];
            if (matches == 0) refuse(std::format("{}: member {} (name prefix '{}') is missing from {}", fn, key, to_string(StringType{real}), st_name));
            if (matches > 1) refuse(std::format("{}: member {} (name prefix '{}') is ambiguous in {} ({} matches)", fn, key, to_string(StringType{real}), st_name, matches));
            T* typed = CastField<T>(found);
            if (!typed) refuse(std::format("{}: member {} of {} ({}) has an unexpected type", fn, key, st_name, to_string(found->GetName())));
            return typed;
        }

        auto inner_struct(const std::string& fn, FArrayProperty* arr, const char* what) -> UScriptStruct*
        {
            auto* inner = CastField<FStructProperty>(arr->GetInner());
            UScriptStruct* st = inner ? inner->GetStruct().Get() : nullptr;
            if (!st) refuse(std::format("{}: {} isn't an array of structs", fn, what));
            return st;
        }

        // Resolves everything before anything is written. missing (a Member, or -1) replaces that member's prefix with
        // one that can't exist: core's forced-missing test (test/SkelNative); core itself always passes -1.
        auto resolve(const std::string& fn, UObject* manager, UClass* cls, int missing) -> Layout
        {
            Layout L{};
            L.manager = manager;
            L.objectives = CastField<FArrayProperty>(cls->FindProperty(FName(STR("Objectives"), FNAME_Find)));
            L.area = CastField<FTextProperty>(cls->FindProperty(FName(STR("Area Name"), FNAME_Find)));
            L.selected = CastField<FIntProperty>(cls->FindProperty(FName(STR("Selected Objective"), FNAME_Find)));
            if (!L.objectives) refuse(std::format("{}: ObjectiveManager_C has no array property Objectives", fn));
            if (!L.area) refuse(std::format("{}: ObjectiveManager_C has no text property 'Area Name'", fn));
            if (!L.selected) refuse(std::format("{}: ObjectiveManager_C has no int property 'Selected Objective'", fn));
            L.objective_struct = inner_struct(fn, L.objectives, "Objectives");

            auto prefix = [&](int m) -> const CharType* { return m == missing ? STR("NNMissingForTest_") : k_prefixes[m]; };
            L.actors = member<FArrayProperty>(fn, L.objective_struct, M_Actors, prefix(M_Actors));
            L.tasks = member<FArrayProperty>(fn, L.objective_struct, M_Tasks, prefix(M_Tasks));
            L.task_struct = inner_struct(fn, L.tasks, "Tasks");
            L.state = member<FBoolProperty>(fn, L.task_struct, M_State, prefix(M_State));
            L.description = member<FTextProperty>(fn, L.task_struct, M_Description, prefix(M_Description));
            L.unique_id = member<FStrProperty>(fn, L.task_struct, M_UniqueIdentifier, prefix(M_UniqueIdentifier));
            L.traitor_description = member<FTextProperty>(fn, L.task_struct, M_TraitorDescription, prefix(M_TraitorDescription));
            L.traitor_state = member<FBoolProperty>(fn, L.task_struct, M_TraitorState, prefix(M_TraitorState));

            // FText and FString values are copied through the engine's own properties into our locals and back; our
            // locals must be at least as large as the engine's values, and FText's engine copy must be resolved.
            int32 text_size = -1;
            try
            {
                text_size = FText::StaticSize();
            }
            catch (...)
            {
            }
            if (!FText::ValueOpsProperty || text_size <= 0 || text_size > FText::MaxStorageSize)
            {
                refuse(std::format("{}: UE4SS's FText isn't set up (size {}); refusing to build texts", fn, text_size));
            }
            for (FTextProperty* t : {L.description, L.traitor_description, L.area})
            {
                if (t->GetElementSize() != text_size) refuse(std::format("{}: FText size mismatch (engine member {}, UE4SS {})", fn, t->GetElementSize(), text_size));
            }
            if (L.unique_id->GetElementSize() != static_cast<int32>(sizeof(FString)))
            {
                refuse(std::format("{}: FString size mismatch (engine member {}, UE4SS {})", fn, L.unique_id->GetElementSize(), sizeof(FString)));
            }
            return L;
        }

        // Reads of the manager's reflected memory, each under SEH (plain values only; the caller owns any local the
        // engine copies into).
        unsigned long copy_value_raw(FProperty* prop, void* dest, const void* src)
        {
            __try
            {
                prop->CopyCompleteValue(dest, src);
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                return GetExceptionCode();
            }
        }

        unsigned long read_bool_raw(FBoolProperty* prop, const void* container, bool* out)
        {
            __try
            {
                *out = prop->GetPropertyValueInContainer(container);
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                return GetExceptionCode();
            }
        }

        unsigned long read_int_raw(const int32* value, int32* out)
        {
            __try
            {
                *out = *value;
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                return GetExceptionCode();
            }
        }

        [[noreturn]] void read_fault(const std::string& fn, const char* what, unsigned long fault, const void* at)
        {
            log_fault(fn, what, fault, reinterpret_cast<uint64_t>(at));
            throw ArgError(std::format("{}: internal fault while reading {} (logged); nothing was changed", fn, what));
        }

        auto read_text(const std::string& fn, const char* what, FTextProperty* prop, const void* value) -> std::string
        {
            FText local{};
            if (const auto fault = copy_value_raw(prop, &local, value)) read_fault(fn, what, fault, value);
            return to_string(local.ToString());
        }

        auto read_string(const std::string& fn, const char* what, FStrProperty* prop, const void* value) -> std::string
        {
            FString local{};
            if (const auto fault = copy_value_raw(prop, &local, value)) read_fault(fn, what, fault, value);
            return to_string(StringType(*local));
        }

        bool read_bool(const std::string& fn, const char* what, FBoolProperty* prop, const void* container)
        {
            bool v{};
            if (const auto fault = read_bool_raw(prop, container, &v)) read_fault(fn, what, fault, container);
            return v;
        }

        int32 read_int(const std::string& fn, const char* what, const int32* value)
        {
            int32 v{};
            if (const auto fault = read_int_raw(value, &v)) read_fault(fn, what, fault, value);
            return v;
        }

        // A readback field: tabs and line breaks become spaces, and it is cut at 512 characters (on a client the
        // values come from another player, so the result's size stays bounded).
        constexpr size_t k_max_field = 512;
        auto flat(std::string s) -> std::string
        {
            for (auto& c : s)
            {
                if (c == '\t' || c == '\n' || c == '\r') c = ' ';
            }
            if (s.size() > k_max_field) s.resize(k_max_field);
            return s;
        }

        bool replicates(FArrayProperty* p)
        {
            return (static_cast<uint64_t>(p->GetPropertyFlags()) & 0x20) != 0; // CPF_Net
        }

        // ------------------------------------------------------------------ the entry points

        struct TaskIn
        {
            std::string id;
            std::string text;
        };

        Result set_objectives(const Lua& lua, const std::string& fn, int missing)
        {
            const int32_t n = lua.get_stack_size();
            if (n < 2) throw ArgError(std::format("{}: expected (managerPath, areaName, id1, text1, ...), got {} argument{}", fn, n, n == 1 ? "" : "s"));
            if (n % 2 != 0) throw ArgError(std::format("{}: each task is an id and a text; got {} arguments (an odd count)", fn, n));
            const int32_t count = (n - 2) / 2;
            if (count < 1 || count > k_max_tasks) throw ArgError(std::format("{}: 1..{} tasks, got {}", fn, k_max_tasks, count));

            const std::string path = take_string(lua, fn, 1, "managerPath");
            const std::string area = take_string(lua, fn, 2, "areaName");
            std::vector<TaskIn> tasks;
            tasks.reserve(static_cast<size_t>(count));
            for (int32_t i = 0; i < count; ++i)
            {
                TaskIn t;
                t.id = take_string(lua, fn, 3 + 2 * i, "task id");
                t.text = take_string(lua, fn, 4 + 2 * i, "task text");
                tasks.push_back(std::move(t));
            }
            check_path(fn, path);
            check_text(fn, "area name", area, k_max_area);
            std::unordered_set<std::string> seen;
            for (const auto& t : tasks)
            {
                check_id(fn, t.id);
                check_text(fn, "task text", t.text, k_max_text);
                if (!seen.insert(t.id).second) throw ArgError(std::format("{}: task id '{}' given twice", fn, t.id));
            }

            auto [manager, cls] = find_manager(fn, path);
            require_host_world(fn, path, manager);
            Layout L = resolve(fn, manager, cls, missing);
            void* objectives_value = L.objectives->ContainerPtrToValuePtr<void>(L.manager);
            const ArrayView current = read_array(fn, L.objectives, objectives_value, k_cap_objectives, "Objectives");
            if (current.num != 0) throw ArgError(std::format("{}: {} already has {} objective(s); a manager is filled once only", fn, path, current.num));

            // Every value is built before the first write, so a failure here leaves the manager untouched.
            FText area_text{FString(ensure_str(area))};
            if (!area_text.GetTextData()) throw ArgError(std::format("{}: the engine built no text for the area name", fn));
            std::vector<FText> texts;
            std::vector<FString> ids;
            texts.reserve(tasks.size());
            ids.reserve(tasks.size());
            for (const auto& t : tasks)
            {
                texts.emplace_back(FString(ensure_str(t.text)));
                ids.emplace_back(ensure_str(t.id));
                if (!texts.back().GetTextData()) throw ArgError(std::format("{}: the engine built no text for task '{}'", fn, t.id));
            }

            // One objective, initialized by the engine (empty Actors, empty Tasks), then its tasks, each initialized by
            // the engine (State and TraitorState false, empty texts) before our values are copied in through the
            // members' properties. RUDescription and Area Name RU stay empty.
            FScriptArrayHelper objectives(L.objectives, objectives_value);
            objectives.AddValues(1);
            uint8* objective = objectives.GetRawPtr(0);
            FScriptArrayHelper task_array(L.tasks, L.tasks->ContainerPtrToValuePtr<void>(objective));
            task_array.AddValues(static_cast<int32>(tasks.size()));
            for (int32 i = 0; i < static_cast<int32>(tasks.size()); ++i)
            {
                uint8* task = task_array.GetRawPtr(i);
                const auto k = static_cast<size_t>(i);
                L.unique_id->CopyCompleteValue(L.unique_id->ContainerPtrToValuePtr<void>(task), &ids[k]);
                L.description->CopyCompleteValue(L.description->ContainerPtrToValuePtr<void>(task), &texts[k]);
                L.traitor_description->CopyCompleteValue(L.traitor_description->ContainerPtrToValuePtr<void>(task), &texts[k]);
                L.state->SetPropertyValueInContainer(task, false);
                L.traitor_state->SetPropertyValueInContainer(task, false);
            }
            L.area->CopyCompleteValue(L.area->ContainerPtrToValuePtr<void>(L.manager), &area_text);

            logf("SET {} area='{}' objectives=1 tasks={} (Objectives replicates={})", path, area, tasks.size(), replicates(L.objectives) ? 1 : 0);
            Result r;
            r.kind = Result::Kind::Integer;
            r.integer = static_cast<int64_t>(tasks.size());
            return r;
        }
    } // namespace

    int l_set_objectives(const Lua& lua)
    {
        return guarded(lua, g_fn_set, [&] {
            require_game_thread(g_fn_set);
            return set_objectives(lua, g_fn_set, -1);
        });
    }

    int l_describe_objectives(const Lua& lua)
    {
        const std::string& fn = g_fn_describe;
        return guarded(lua, fn, [&] {
            require_game_thread(fn);
            require_args(lua, fn, 1, " (managerPath)");
            const std::string path = take_string(lua, fn, 1, "managerPath");
            check_path(fn, path);
            // Read only, so on any machine: a client reads the replicated task list too.
            auto [manager, cls] = find_manager(fn, path);
            Layout L = resolve(fn, manager, cls, -1);
            const ArrayView objectives = read_array(fn, L.objectives, L.objectives->ContainerPtrToValuePtr<void>(L.manager), k_cap_objectives, "Objectives");
            const int32 selected = read_int(fn, "Selected Objective", L.selected->ContainerPtrToValuePtr<int32>(L.manager));
            Result r;
            r.kind = Result::Kind::String;
            r.text = std::format("manager\t{}\t{}\t{}\t{}", objectives.num, selected, replicates(L.objectives) ? 1 : 0,
                                 flat(read_text(fn, "Area Name", L.area, L.area->ContainerPtrToValuePtr<void>(L.manager))));
            int32_t described = 0;
            for (int32 o = 0; o < objectives.num; ++o)
            {
                uint8* objective = objectives.at(o);
                const ArrayView tasks = read_array(fn, L.tasks, L.tasks->ContainerPtrToValuePtr<void>(objective), k_cap_tasks, "an objective's Tasks");
                described += tasks.num;
                if (described > k_cap_described_tasks) refuse(std::format("{}: {} holds more than {} tasks", fn, path, k_cap_described_tasks));
                for (int32 t = 0; t < tasks.num; ++t)
                {
                    uint8* task = tasks.at(t);
                    r.text += std::format("\ntask\t{}\t{}\t{}\t{}\t{}\t{}\t{}", o, t, read_bool(fn, "a task's State", L.state, task) ? 1 : 0,
                                          flat(read_string(fn, "a task's UniqueIdentifier", L.unique_id, L.unique_id->ContainerPtrToValuePtr<void>(task))),
                                          flat(read_text(fn, "a task's Description", L.description, L.description->ContainerPtrToValuePtr<void>(task))),
                                          read_bool(fn, "a task's TraitorState", L.traitor_state, task) ? 1 : 0,
                                          flat(read_text(fn, "a task's TraitorDescription", L.traitor_description, L.traitor_description->ContainerPtrToValuePtr<void>(task))));
                }
            }
            return r;
        });
    }

    int l_set_traitor_task_state(const Lua& lua)
    {
        const std::string& fn = g_fn_traitor;
        return guarded(lua, fn, [&] {
            require_game_thread(fn);
            require_args(lua, fn, 3, " (managerPath, taskId, state)");
            const std::string path = take_string(lua, fn, 1, "managerPath");
            const std::string id = take_string(lua, fn, 2, "taskId");
            const bool state = take_bool(lua, fn, 3, "state");
            check_path(fn, path);
            check_id(fn, id);

            auto [manager, cls] = find_manager(fn, path);
            require_host_world(fn, path, manager);
            Layout L = resolve(fn, manager, cls, -1);
            const ArrayView objectives = read_array(fn, L.objectives, L.objectives->ContainerPtrToValuePtr<void>(L.manager), k_cap_objectives, "Objectives");
            if (objectives.num == 0) throw ArgError(std::format("{}: {} has no objectives yet; fill it with {} first", fn, path, g_fn_set));
            // Every matching task is found before the first write.
            std::vector<uint8*> hits;
            int32_t looked = 0;
            for (int32 o = 0; o < objectives.num; ++o)
            {
                const ArrayView tasks = read_array(fn, L.tasks, L.tasks->ContainerPtrToValuePtr<void>(objectives.at(o)), k_cap_tasks, "an objective's Tasks");
                looked += tasks.num;
                if (looked > k_cap_described_tasks) refuse(std::format("{}: {} holds more than {} tasks", fn, path, k_cap_described_tasks));
                for (int32 t = 0; t < tasks.num; ++t)
                {
                    uint8* task = tasks.at(t);
                    if (read_string(fn, "a task's UniqueIdentifier", L.unique_id, L.unique_id->ContainerPtrToValuePtr<void>(task)) == id) hits.push_back(task);
                }
            }
            if (hits.empty()) throw ArgError(std::format("{}: {} has no task with id '{}'", fn, path, id));
            for (uint8* task : hits) L.traitor_state->SetPropertyValueInContainer(task, state);
            logf("TRAITOR {} task '{}' TraitorState={} ({} task{})", path, id, state ? 1 : 0, hits.size(), hits.size() == 1 ? "" : "s");
            Result r;
            r.kind = Result::Kind::Integer;
            r.integer = static_cast<int64_t>(hits.size());
            return r;
        });
    }

#ifdef CORE_OBJECTIVES_TEST
    int set_objectives_with_missing_member(const Lua& lua, const std::string& fn)
    {
        return guarded(lua, fn, [&] {
            require_game_thread(fn);
            if (lua.get_stack_size() < 1) throw ArgError(std::format("{}: expected (memberKey, managerPath, areaName, id1, text1, ...)", fn));
            const std::string key = take_string(lua, fn, 1, "memberKey");
            int missing = -1;
            for (int m = 0; m < k_member_count; ++m)
            {
                if (key == k_member_keys[m]) missing = m;
            }
            if (missing < 0) throw ArgError(std::format("{}: unknown member key '{}'", fn, quote(key)));
            // The rest is <Core>_SetObjectives' own path; its messages name that function.
            return set_objectives(lua, g_fn_set, missing);
        });
    }
#endif
} // namespace core_native::objectives
