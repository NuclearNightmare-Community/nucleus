// The strict zip reader (zip.hpp has the rules).
#include "zip.hpp"

#include <algorithm>
#include <memory>

#include "miniz.h"

namespace core_stage::zip
{
    namespace
    {
        constexpr uint32_t k_sig_eocd = 0x06054b50;
        constexpr uint32_t k_sig_zip64_locator = 0x07064b50;
        constexpr uint32_t k_sig_central = 0x02014b50;
        constexpr uint32_t k_sig_local = 0x04034b50;
        constexpr size_t k_eocd_size = 22;
        constexpr size_t k_central_size = 46;
        constexpr size_t k_local_size = 30;

        uint16_t u16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
        uint32_t u32(const uint8_t* p) { return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24); }

        bool fail(Error& err, const char* code, std::string message)
        {
            err.code = code;
            err.message = std::move(message);
            return false;
        }

        // At most 96 printable bytes of an entry name, for a message.
        std::string shown(const std::string& s)
        {
            std::string out;
            for (const unsigned char c : s.substr(0, 96)) out += (c >= 0x20 && c <= 0x7E) ? static_cast<char>(c) : '?';
            if (s.size() > 96) out += "...";
            return out;
        }

        bool valid_utf8(const std::string& s)
        {
            size_t i = 0;
            while (i < s.size())
            {
                const unsigned char c = static_cast<unsigned char>(s[i]);
                if (c < 0x80)
                {
                    ++i;
                    continue;
                }
                size_t len = 0;
                uint32_t cp = 0;
                if ((c & 0xE0) == 0xC0) len = 2, cp = c & 0x1F;
                else if ((c & 0xF0) == 0xE0) len = 3, cp = c & 0x0F;
                else if ((c & 0xF8) == 0xF0) len = 4, cp = c & 0x07;
                else return false;
                if (i + len > s.size()) return false;
                for (size_t k = 1; k < len; ++k)
                {
                    const unsigned char d = static_cast<unsigned char>(s[i + k]);
                    if ((d & 0xC0) != 0x80) return false;
                    cp = (cp << 6) | (d & 0x3F);
                }
                if ((len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && (cp < 0x10000 || cp > 0x10FFFF))) return false;
                if (cp >= 0xD800 && cp <= 0xDFFF) return false;
                i += len;
            }
            return true;
        }

        // The zip-style relative path rule (Install-NNMods.ps1's Is-SafeRel, plus no NUL and no control byte).
        bool safe_name(const std::string& n, bool dir)
        {
            if (n.empty() || n.size() > 1024 || n.front() == '/' || n.find('\\') != std::string::npos || n.find(':') != std::string::npos) return false;
            for (const unsigned char c : n)
                if (c < 0x20 || c == 0x7F) return false;
            if (!valid_utf8(n)) return false;
            const std::string body = dir ? n.substr(0, n.size() - 1) : n;
            if (body.empty()) return false;
            size_t start = 0;
            while (true)
            {
                const size_t i = body.find('/', start);
                const std::string seg = body.substr(start, i == std::string::npos ? std::string::npos : i - start);
                if (seg.empty() || seg == "." || seg == "..") return false;
                if (i == std::string::npos) return true;
                start = i + 1;
            }
        }

        std::string fold(const std::string& s)
        {
            std::string out = s;
            for (char& c : out)
                if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
            return out;
        }

        // Extra fields: well-formed (id, length, data) records; a zip64 record (0x0001) refuses the zip.
        bool extra_ok(const uint8_t* p, size_t n, bool& zip64)
        {
            zip64 = false;
            size_t i = 0;
            while (i < n)
            {
                if (n - i < 4) return false;
                const uint16_t id = u16(p + i);
                const uint16_t len = u16(p + i + 2);
                if (n - i - 4 < len) return false;
                if (id == 0x0001) zip64 = true;
                i += 4 + static_cast<size_t>(len);
            }
            return true;
        }

        struct Central
        {
            std::string name;
            uint16_t flags = 0, method = 0;
            uint32_t crc = 0;
            uint64_t csize = 0, usize = 0, local = 0;
            uint64_t data = 0; // where the data starts (after the local header)
            bool dir = false;
        };

        bool inflate(const uint8_t* in, uint64_t csize, uint64_t usize, std::vector<uint8_t>& out, const std::string& name, Error& err)
        {
            // Output capped at the declared size + 1: one byte more than declared means the entry inflates past it.
            out.assign(static_cast<size_t>(usize + 1), 0);
            auto d = std::make_unique<tinfl_decompressor>();
            tinfl_init(d.get());
            size_t in_size = static_cast<size_t>(csize);
            size_t out_size = out.size();
            const tinfl_status st = tinfl_decompress(d.get(), in, &in_size, out.data(), out.data(), &out_size, TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
            if (st == TINFL_STATUS_HAS_MORE_OUTPUT || out_size > usize)
            {
                out.clear();
                return fail(err, "too-large", "entry " + shown(name) + " inflates past its declared size of " + std::to_string(usize) + " bytes");
            }
            if (st != TINFL_STATUS_DONE)
            {
                out.clear();
                return fail(err, "bad-zip", "entry " + shown(name) + " is not valid Deflate data");
            }
            if (in_size != csize)
            {
                out.clear();
                return fail(err, "bad-zip", "entry " + shown(name) + " has data after its Deflate stream");
            }
            if (out_size != usize)
            {
                out.clear();
                return fail(err, "bad-zip", "entry " + shown(name) + " inflates to " + std::to_string(out_size) + " bytes; its header says " + std::to_string(usize));
            }
            out.resize(static_cast<size_t>(usize));
            return true;
        }
    } // namespace

    bool read(const uint8_t* p, size_t n, std::vector<Entry>& out, Error& err)
    {
        out.clear();
        try
        {
            if (!p || n < k_eocd_size) return fail(err, "bad-zip", "too short to be a zip");
            // The end-of-central-directory record: the last one whose comment ends exactly at the end of the file.
            size_t eocd = SIZE_MAX;
            const size_t lowest = n > k_eocd_window ? n - k_eocd_window : 0;
            for (size_t i = n - k_eocd_size + 1; i-- > lowest;)
            {
                if (u32(p + i) != k_sig_eocd) continue;
                if (i + k_eocd_size + u16(p + i + 20) == n)
                {
                    eocd = i;
                    break;
                }
            }
            if (eocd == SIZE_MAX) return fail(err, "bad-zip", "no end of central directory record");
            const uint8_t* e = p + eocd;
            const uint16_t disk = u16(e + 4), cd_disk = u16(e + 6), here = u16(e + 8), total = u16(e + 10);
            const uint32_t cd_size = u32(e + 12), cd_off = u32(e + 16);
            if (eocd >= 20 && u32(p + eocd - 20) == k_sig_zip64_locator) return fail(err, "bad-zip", "zip64 is not supported");
            if (total == 0xFFFF || here == 0xFFFF || cd_size == 0xFFFFFFFFu || cd_off == 0xFFFFFFFFu) return fail(err, "bad-zip", "zip64 is not supported");
            if (disk != 0 || cd_disk != 0 || here != total) return fail(err, "bad-zip", "a multi-disk zip is not supported");
            if (total > k_max_entries) return fail(err, "too-large", "more than " + std::to_string(k_max_entries) + " entries");
            if (static_cast<uint64_t>(cd_off) + cd_size != eocd) return fail(err, "bad-zip", "the central directory's bounds disagree with its end record");

            // The central directory.
            std::vector<Central> entries;
            entries.reserve(total);
            uint64_t pos = cd_off;
            for (uint16_t k = 0; k < total; ++k)
            {
                if (pos + k_central_size > eocd || u32(p + pos) != k_sig_central) return fail(err, "bad-zip", "central directory entry " + std::to_string(k + 1) + " is malformed");
                const uint8_t* c = p + pos;
                Central ce;
                ce.flags = u16(c + 8);
                ce.method = u16(c + 10);
                ce.crc = u32(c + 16);
                const uint32_t cs = u32(c + 20), us = u32(c + 24);
                const uint16_t nlen = u16(c + 28), xlen = u16(c + 30), clen = u16(c + 32), dstart = u16(c + 34);
                const uint32_t loff = u32(c + 42);
                const uint64_t end = pos + k_central_size + nlen + xlen + clen;
                if (end > eocd) return fail(err, "bad-zip", "central directory entry " + std::to_string(k + 1) + " runs past the directory");
                ce.name.assign(reinterpret_cast<const char*>(c + k_central_size), nlen);
                bool z64 = false;
                if (!extra_ok(c + k_central_size + nlen, xlen, z64)) return fail(err, "bad-zip", "entry " + shown(ce.name) + " has a malformed extra field");
                if (z64 || cs == 0xFFFFFFFFu || us == 0xFFFFFFFFu || loff == 0xFFFFFFFFu) return fail(err, "bad-zip", "entry " + shown(ce.name) + ": zip64 is not supported");
                if (dstart != 0) return fail(err, "bad-zip", "entry " + shown(ce.name) + ": a multi-disk zip is not supported");
                if (ce.flags & 0x0041) return fail(err, "bad-zip", "entry " + shown(ce.name) + " is encrypted");
                if (ce.method != 0 && ce.method != 8) return fail(err, "bad-zip", "entry " + shown(ce.name) + " uses compression method " + std::to_string(ce.method) + " (only 0 and 8)");
                ce.csize = cs;
                ce.usize = us;
                ce.local = loff;
                ce.dir = !ce.name.empty() && ce.name.back() == '/';
                if (ce.dir && us != 0) return fail(err, "bad-zip", "folder entry " + shown(ce.name) + " has data");
                if (!safe_name(ce.name, ce.dir)) return fail(err, "bad-zip", "entry name " + shown(ce.name) + " is not a safe relative path");
                if (ce.method == 0 && cs != us) return fail(err, "bad-zip", "stored entry " + shown(ce.name) + " has two different sizes");
                entries.push_back(std::move(ce));
                pos = end;
            }
            if (pos != eocd) return fail(err, "bad-zip", "the central directory holds more than its end record counts");

            // Duplicates without case; caps on the declared sizes.
            {
                std::vector<std::string> seen;
                uint64_t sum = 0;
                for (const auto& ce : entries)
                {
                    const std::string f = fold(ce.dir ? ce.name.substr(0, ce.name.size() - 1) : ce.name);
                    if (std::find(seen.begin(), seen.end(), f) != seen.end()) return fail(err, "bad-zip", "entry " + shown(ce.name) + " is in the zip twice (names compared without case)");
                    seen.push_back(f);
                    if (ce.dir) continue;
                    if (ce.usize > k_max_entry) return fail(err, "too-large", "entry " + shown(ce.name) + " is over 256 MiB");
                    sum += ce.usize;
                    if (sum > k_max_total) return fail(err, "too-large", "the entries are over 512 MiB in all");
                }
            }

            // Local headers: name and method as in the central directory, data inside the file before the directory.
            for (auto& ce : entries)
            {
                if (ce.local + k_local_size > cd_off || u32(p + ce.local) != k_sig_local) return fail(err, "bad-zip", "entry " + shown(ce.name) + " has no local header");
                const uint8_t* l = p + ce.local;
                const uint16_t method = u16(l + 8);
                const uint16_t nlen = u16(l + 26), xlen = u16(l + 28);
                if (ce.local + k_local_size + nlen + xlen > cd_off) return fail(err, "bad-zip", "entry " + shown(ce.name) + "'s local header runs past the data");
                const std::string lname(reinterpret_cast<const char*>(l + k_local_size), nlen);
                if (lname != ce.name || method != ce.method) return fail(err, "bad-zip", "entry " + shown(ce.name) + "'s local header disagrees with the central directory");
                if (u16(l + 6) & 0x0041) return fail(err, "bad-zip", "entry " + shown(ce.name) + " is encrypted");
                bool z64 = false;
                if (!extra_ok(l + k_local_size + nlen, xlen, z64) || z64) return fail(err, "bad-zip", "entry " + shown(ce.name) + "'s local extra field is malformed or zip64");
                ce.data = ce.local + k_local_size + nlen + xlen;
                if (ce.data + ce.csize > cd_off) return fail(err, "bad-zip", "entry " + shown(ce.name) + "'s data runs past the central directory");
            }
            // No two entries share bytes (overlapping entries are a zip-bomb trick).
            {
                std::vector<std::pair<uint64_t, uint64_t>> spans;
                for (const auto& ce : entries) spans.emplace_back(ce.local, ce.data + ce.csize);
                std::sort(spans.begin(), spans.end());
                for (size_t i = 1; i < spans.size(); ++i)
                    if (spans[i].first < spans[i - 1].second) return fail(err, "bad-zip", "two entries overlap");
            }

            // Inflate and check.
            std::vector<Entry> files;
            for (const auto& ce : entries)
            {
                if (ce.dir) continue;
                Entry f;
                f.name = ce.name;
                if (ce.method == 0)
                {
                    f.data.assign(p + ce.data, p + ce.data + ce.csize);
                }
                else if (!inflate(p + ce.data, ce.csize, ce.usize, f.data, ce.name, err))
                {
                    return false;
                }
                const mz_ulong crc = mz_crc32(MZ_CRC32_INIT, f.data.empty() ? nullptr : f.data.data(), f.data.size());
                if (f.data.empty() ? ce.crc != 0 : static_cast<uint32_t>(crc) != ce.crc) return fail(err, "bad-zip", "entry " + shown(ce.name) + " fails its CRC-32 check");
                files.push_back(std::move(f));
            }
            out = std::move(files);
            return true;
        }
        catch (const std::bad_alloc&)
        {
            out.clear();
            return fail(err, "too-large", "not enough memory to read the zip");
        }
        catch (...)
        {
            out.clear();
            return fail(err, "bad-zip", "the zip could not be read");
        }
    }
} // namespace core_stage::zip
