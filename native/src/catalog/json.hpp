// A strict, bounded JSON reader and writer for the signed catalog (Mod Manager v2 story 2). It reads what
// tools/release/verify.ps1 reads with ConvertFrom-Json -Depth 64, so the native verifier decides the same way:
//   - strict RFC 8259 over UTF-8: one value, whitespace only space/tab/LF/CR, a leading UTF-8 BOM ignored (as
//     Get-Content does); comments, trailing commas, single quotes, NaN/Infinity, leading zeros, raw control
//     characters in strings, invalid UTF-8 and lone surrogate escapes are errors;
//   - integers (no fraction, no exponent) that fit 64 bits are Int, larger ones BigInt (ConvertFrom-Json's
//     BigInteger: not an [int] or [long]); every other number is Float;
//   - object keys are case-sensitive, and a key repeated in the same object, also differing only in ASCII case, is an
//     error (ConvertFrom-Json refuses both);
//   - at most 64 nested arrays/objects.
// Objects keep their members in document order. Nothing here throws on bad input: parse() returns false with a
// reason. Windows-free and UE4SS-free: the test exe (catalog_cli.cpp) and core's DLL both build it.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace catalog::json
{
    struct Value
    {
        enum class Type
        {
            Null,
            Bool,
            Int,
            BigInt, // an integer literal beyond int64 (text in s)
            Float,
            String,
            Array,
            Object
        };
        Type type = Type::Null;
        bool b{};
        int64_t i{};
        double f{};
        std::string s;                  // String: UTF-8; BigInt: the literal
        std::vector<Value> items;       // Array
        std::vector<std::string> keys;  // Object: member names, in order
        std::vector<Value> vals;        // Object: member values, parallel to keys

        static Value null() { return {}; }
        static Value boolean(bool v) { Value x; x.type = Type::Bool; x.b = v; return x; }
        static Value integer(int64_t v) { Value x; x.type = Type::Int; x.i = v; return x; }
        static Value string(std::string v) { Value x; x.type = Type::String; x.s = std::move(v); return x; }
        static Value array() { Value x; x.type = Type::Array; return x; }
        static Value object() { Value x; x.type = Type::Object; return x; }

        bool is_null() const { return type == Type::Null; }
        bool is_obj() const { return type == Type::Object; }
        bool is_arr() const { return type == Type::Array; }
        bool is_str() const { return type == Type::String; }
        bool is_int() const { return type == Type::Int; }

        // verify.ps1's Has: an object with a member of exactly this name.
        bool has(std::string_view k) const { return get(k) != nullptr; }
        // The member of exactly this name, or nullptr (also when this isn't an object).
        const Value* get(std::string_view k) const;
        Value* get(std::string_view k);
        // PowerShell property access ($obj.name): exactly this name, else a member equal ignoring ASCII case.
        const Value* get_ci(std::string_view k) const;
        // Replaces the member's value in place, or appends it. Only on an object.
        void set(std::string_view k, Value v);
        void remove(std::string_view k);
    };

    // Parses text (a leading UTF-8 BOM is skipped). On failure returns false and sets error ("<offset>: <reason>").
    bool parse(std::string_view text, Value& out, std::string& error, int max_depth = 64);

    // JSON text for v: compact, or indented by two spaces with CRLF line ends (as ConvertTo-Json writes on Windows).
    // Strings escape only ", \ and control characters; other UTF-8 passes through.
    std::string write(const Value& v, bool pretty = false);
    // One JSON string literal.
    std::string quote(std::string_view s);

    bool ascii_iequal(std::string_view a, std::string_view b);
} // namespace catalog::json
