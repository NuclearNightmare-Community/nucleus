// A strict reader for release zips (Mod Manager v2 story 5; README "Installing from the catalog"), from an in-memory
// buffer of a zip whose size and SHA-256 were already checked against the verified index. Our own parsing, so every
// bound is ours; miniz (third_party/miniz-3.0.2) only inflates (tinfl_decompress) and checks CRC-32 (mz_crc32).
//
// Accepted: one disk, no zip64, no encryption, methods 0 (stored) and 8 (Deflate), the end-of-central-directory record
// in the last 65,557 bytes with the central directory right before it, entry counts and bounds that agree, a local
// header per entry whose name and method equal the central entry's, entries that don't overlap. Names are UTF-8 with
// "/" only (no "\", no leading "/", no NUL, no empty, "." or ".." segment); directory entries (a trailing "/" and size 0)
// are skipped; two names equal without case refuse the zip. Inflating is capped at the declared size + 1 byte, and the
// size and CRC-32 must match. Caps: 1024 entries, 256 MiB per entry, 512 MiB in all (story 3's plan cap).
// Outcomes: "bad-zip" (malformed, unsupported, CRC or size wrong) and "too-large" (a cap, or an entry inflating past
// its declared size). Windows-free, UE4SS-free; never throws on bad input.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace core_stage::zip
{
    inline constexpr size_t k_max_entries = 1024;
    inline constexpr uint64_t k_max_entry = 256ull * 1024 * 1024;
    inline constexpr uint64_t k_max_total = 512ull * 1024 * 1024;
    inline constexpr size_t k_eocd_window = 65557; // 22-byte record + a 65,535-byte comment

    struct Entry
    {
        std::string name;          // as in the zip ("/" separators)
        std::vector<uint8_t> data; // inflated, size and CRC-32 checked
    };

    struct Error
    {
        std::string code;    // bad-zip | too-large
        std::string message; // one line
    };

    // Reads every file entry of the zip in p[0..n). false with err set otherwise; out is then empty.
    bool read(const uint8_t* p, size_t n, std::vector<Entry>& out, Error& err);
} // namespace core_stage::zip
