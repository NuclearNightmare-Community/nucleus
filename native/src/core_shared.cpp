// Definitions for core_shared.hpp: the game-thread rule, argument checks, and the live-object proof under SEH.
#include <excpt.h>

#include <mutex>

#include <Unreal/UObjectArray.hpp>

#include "core_shared.hpp"
#include "core_config.hpp"

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

namespace core_native
{
    std::string g_log_tag = CORE_NAME;
    std::atomic<bool> g_game_thread_known{false};
    std::thread::id g_game_thread{};

    void engine_tick_pre(Hook::TCallbackIterationData<void>&, UEngine*, float, bool)
    {
        // Registered with bOnce: runs on the first tick only. UE4SS removes a hook whose callback throws: catch everything.
        try
        {
            if (!g_game_thread_known.load())
            {
                g_game_thread = std::this_thread::get_id();
                g_game_thread_known = true;
                logf("game thread known (first engine tick)");
            }
        }
        catch (const std::exception& e)
        {
            logf("ERROR engine tick hook: {}", e.what());
        }
        catch (...)
        {
            logf("ERROR engine tick hook: unknown C++ exception");
        }
    }

    void require_game_thread(const std::string& fn)
    {
        if (g_game_thread_known.load() && std::this_thread::get_id() != g_game_thread)
        {
            throw ArgError(std::format("{} refused: called off the game thread", fn));
        }
    }

    // Describes argument 1 by its Lua type (lua_isnumber/lua_isstring would also accept numeric strings and numbers).
    auto describe_first_arg(const Lua& lua) -> std::string
    {
        if (lua.get_stack_size() < 1) return "nothing";
        const std::string type{lua.get_type_string()};
        if (type == "number") return lua.is_integer(1) ? "an integer" : "a float";
        if (type == "nil") return "nil";
        if (type == "boolean") return "a boolean";
        if (type == "string") return "a string";
        if (type == "table") return "a table";
        if (type == "function") return "a function";
        if (type == "userdata") return "a userdata";
        return "a " + type;
    }

    void require_args(const Lua& lua, const std::string& fn, int32_t want, const char* what)
    {
        const int32_t got = lua.get_stack_size();
        if (got != want)
        {
            throw ArgError(std::format("{}: expected {} argument{}{}, got {}", fn, want, want == 1 ? "" : "s", what, got));
        }
    }

    // ------------------------------------------------------------------ SEH last-resort guards

    int seh_filter(unsigned long code)
    {
        switch (code)
        {
        case 0xC0000005: // access violation
        case 0xC0000006: // in-page error
        case 0x80000002: // datatype misalignment
        case 0xC000001D: // illegal instruction
        case 0xC0000094: // integer divide by zero
        case 0xC0000096: // privileged instruction
            return EXCEPTION_EXECUTE_HANDLER;
        default:
            return EXCEPTION_CONTINUE_SEARCH; // C++ exceptions (0xE06D7363) and everything else pass through
        }
    }

    namespace
    {
        constexpr int32_t k_chunk = TUObjectArray::NumElementsPerChunk;
        // How to read FUObjectItem::Object without a call per item; found once by probe_object_array().
        int32_t g_item_stride = 0;
        int32_t g_object_offset = -1;
        bool g_contiguous_chunks = false;
        std::once_flag g_probe_once;

        // Finds where FUObjectItem keeps its object pointer and whether a chunk's items are contiguous, by comparing
        // against GetUObject() on live slots. Falls back to one GetUObject() call per slot if anything disagrees.
        // Returns 0 or an SEH fault code.
        unsigned long probe_object_array_raw(int32_t* stride, int32_t* offset, bool* contiguous)
        {
            __try
            {
                *stride = FUObjectArray::GetObjectItemSize();
                *offset = -1;
                *contiguous = false;
                const int32_t n = FUObjectArray::GetNumElements();
                if (*stride < 8 || *stride > 64 || n < 2) return 0;
                const auto* item0 = reinterpret_cast<const uint8_t*>(FUObjectArray::IndexToObject(0));
                const void* obj0 = item0 ? FUObjectArray::IndexToObject(0)->GetUObject() : nullptr;
                if (!obj0) return 0;
                for (int32_t off = 0; off + 8 <= *stride; off += 8)
                {
                    if (*reinterpret_cast<const void* const*>(item0 + off) == obj0)
                    {
                        *offset = off;
                        break;
                    }
                }
                if (*offset < 0) return 0;
                // Check the layout on a spread of slots in the first chunks.
                const int32_t limit = n < 2 * k_chunk ? n : 2 * k_chunk;
                for (int32_t i = 1; i < limit; i += 997)
                {
                    const int32_t base = (i / k_chunk) * k_chunk;
                    const auto* first = reinterpret_cast<const uint8_t*>(FUObjectArray::IndexToObject(base));
                    const auto* item = FUObjectArray::IndexToObject(i);
                    if (!first || !item) return 0;
                    if (reinterpret_cast<const uint8_t*>(item) != first + static_cast<size_t>(i - base) * *stride) return 0;
                    if (*reinterpret_cast<const void* const*>(reinterpret_cast<const uint8_t*>(item) + *offset) != item->GetUObject()) return 0;
                }
                *contiguous = true;
                return 0;
            }
            __except (seh_filter(GetExceptionCode()))
            {
                *contiguous = false;
                return GetExceptionCode();
            }
        }
    } // namespace

    // Scans from the last slot down to slot 0: objects a dependent just created (widgets, a new HUD) usually sit near
    // the end of the array, so the common case stops after a few slots instead of after ~100k (the array reuses freed
    // slots, so after a map change a new object can also sit lower). Same slots, same comparisons, only the order
    // differs; a miss still compares every slot.
    int scan_object_array(const void* target, ScanResult* out)
    {
        out->index = -1;
        out->scanned = 0;
        out->fault = 0;
        __try
        {
            const int32_t n = FUObjectArray::GetNumElements();
            if (n <= 0) return 0;
            if (g_contiguous_chunks)
            {
                for (int32_t base = ((n - 1) / k_chunk) * k_chunk; base >= 0; base -= k_chunk)
                {
                    const auto* first = reinterpret_cast<const uint8_t*>(FUObjectArray::IndexToObject(base));
                    // A chunk that is not there (should not happen below n): nothing to compare in it; the older
                    // chunks are still searched.
                    if (!first) continue;
                    const int32_t count = (n - base < k_chunk) ? (n - base) : k_chunk;
                    const uint8_t* slot0 = first + g_object_offset;
                    for (int32_t i = count - 1; i >= 0; --i)
                    {
                        const uint8_t* p = slot0 + static_cast<size_t>(i) * static_cast<size_t>(g_item_stride);
                        if (*reinterpret_cast<const void* const*>(p) == target)
                        {
                            out->index = base + i;
                            out->scanned += count - i;
                            return 1;
                        }
                    }
                    out->scanned += count;
                }
            }
            else
            {
                for (int32_t i = n - 1; i >= 0; --i)
                {
                    const auto* item = FUObjectArray::IndexToObject(i);
                    if (item && item->GetUObject() == target)
                    {
                        out->index = i;
                        out->scanned = n - i;
                        return 1;
                    }
                }
                out->scanned = n;
            }
            return 0;
        }
        __except (seh_filter(GetExceptionCode()))
        {
            out->fault = GetExceptionCode();
            return -1;
        }
    }

    void probe_object_array()
    {
        std::call_once(g_probe_once, [] {
            int32_t stride{}, offset{};
            bool contiguous{};
            const auto fault = probe_object_array_raw(&stride, &offset, &contiguous);
            g_item_stride = stride;
            g_object_offset = offset;
            g_contiguous_chunks = contiguous && fault == 0;
            logf("GUObjectArray layout: item size {}, object at +{}, scan mode {}{}", stride, offset,
                 g_contiguous_chunks ? "contiguous chunks" : "one GetUObject() per slot",
                 fault ? std::format(" (probe faulted 0x{:08X})", fault) : std::string{});
        });
    }

    int slot_state(int32_t index, const void* target, unsigned long* fault)
    {
        *fault = 0;
        __try
        {
            auto* item = FUObjectArray::IndexToObject(index);
            if (!item || item->GetUObject() != target) return 0;
            if (item->IsUnreachable() || item->IsPendingKill()) return 0;
            return 1;
        }
        __except (seh_filter(GetExceptionCode()))
        {
            *fault = GetExceptionCode();
            return -1;
        }
    }

    int object_flags(int32_t index, const void* target, uint32_t* bits, unsigned long* fault)
    {
        *fault = 0;
        *bits = 0;
        // UE5 values that UE4SS's UE4-era enums don't name: EInternalObjectFlags::Garbage and EObjectFlags::RF_MirroredGarbage.
        constexpr int32_t k_internal_garbage = 1 << 21;
        constexpr int32_t k_rf_mirrored_garbage = 0x40000000;
        __try
        {
            auto* item = FUObjectArray::IndexToObject(index);
            if (!item || item->GetUObject() != target) return 0;
            UObject* obj = item->GetUObject();
            uint32_t b = 0;
            if (obj->HasAnyFlags(RF_ClassDefaultObject)) b |= OF_ClassDefaultObject;
            if (obj->HasAnyFlags(RF_ArchetypeObject)) b |= OF_Archetype;
            if (item->HasAnyFlags(static_cast<EInternalObjectFlags>(k_internal_garbage)) || obj->HasAnyFlags(static_cast<EObjectFlags>(k_rf_mirrored_garbage)))
            {
                b |= OF_Garbage;
            }
            *bits = b;
            return 1;
        }
        __except (seh_filter(GetExceptionCode()))
        {
            *fault = GetExceptionCode();
            return -1;
        }
    }

    namespace
    {
        std::atomic<uint32_t> g_faults{0};
    }
    void log_fault(const std::string& fn, const char* what, unsigned long code, uint64_t detail)
    {
        const auto n = ++g_faults;
        if (n <= 16 || n % 256 == 0)
        {
            logf("FAULT {}: SEH exception 0x{:08X} while {} (detail 0x{:X}); call refused, game continues (fault #{})", fn, code, what, detail, n);
        }
    }
} // namespace core_native
