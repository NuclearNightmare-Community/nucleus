// Strict, bounded JSON (json.hpp). Recursive descent with an explicit depth limit; never throws on bad input.
#include "json.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>
#include <system_error>

namespace catalog::json
{
    namespace
    {
        char lower(char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c + 32) : c; }
    } // namespace

    bool ascii_iequal(std::string_view a, std::string_view b)
    {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i)
        {
            if (lower(a[i]) != lower(b[i])) return false;
        }
        return true;
    }

    const Value* Value::get(std::string_view k) const
    {
        if (type != Type::Object) return nullptr;
        for (size_t n = 0; n < keys.size(); ++n)
        {
            if (keys[n] == k) return &vals[n];
        }
        return nullptr;
    }
    Value* Value::get(std::string_view k)
    {
        return const_cast<Value*>(static_cast<const Value*>(this)->get(k));
    }
    const Value* Value::get_ci(std::string_view k) const
    {
        if (const Value* v = get(k)) return v;
        if (type != Type::Object) return nullptr;
        for (size_t n = 0; n < keys.size(); ++n)
        {
            if (ascii_iequal(keys[n], k)) return &vals[n];
        }
        return nullptr;
    }
    void Value::set(std::string_view k, Value v)
    {
        if (type != Type::Object) return;
        for (size_t n = 0; n < keys.size(); ++n)
        {
            if (keys[n] == k)
            {
                vals[n] = std::move(v);
                return;
            }
        }
        keys.emplace_back(k);
        vals.push_back(std::move(v));
    }
    void Value::remove(std::string_view k)
    {
        if (type != Type::Object) return;
        for (size_t n = 0; n < keys.size(); ++n)
        {
            if (keys[n] == k)
            {
                keys.erase(keys.begin() + static_cast<std::ptrdiff_t>(n));
                vals.erase(vals.begin() + static_cast<std::ptrdiff_t>(n));
                return;
            }
        }
    }

    namespace
    {
        struct Parser
        {
            std::string_view t;
            size_t p = 0;
            int max_depth = 64;
            std::string err;

            bool fail(const char* why)
            {
                if (err.empty()) err = std::to_string(p) + ": " + why;
                return false;
            }
            void ws()
            {
                while (p < t.size() && (t[p] == ' ' || t[p] == '\t' || t[p] == '\n' || t[p] == '\r')) ++p;
            }
            bool lit(const char* w)
            {
                const std::string_view sv{w};
                if (t.substr(p, sv.size()) != sv) return fail("invalid literal");
                p += sv.size();
                return true;
            }
            static void put_utf8(std::string& o, uint32_t cp)
            {
                if (cp < 0x80) o.push_back(static_cast<char>(cp));
                else if (cp < 0x800)
                {
                    o.push_back(static_cast<char>(0xC0 | (cp >> 6)));
                    o.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                }
                else if (cp < 0x10000)
                {
                    o.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                    o.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                    o.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                }
                else
                {
                    o.push_back(static_cast<char>(0xF0 | (cp >> 18)));
                    o.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
                    o.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                    o.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                }
            }
            bool hex4(uint32_t& v)
            {
                if (p + 4 > t.size()) return fail("short \\u escape");
                v = 0;
                for (int k = 0; k < 4; ++k)
                {
                    const char c = t[p++];
                    v <<= 4;
                    if (c >= '0' && c <= '9') v |= static_cast<uint32_t>(c - '0');
                    else if (c >= 'a' && c <= 'f') v |= static_cast<uint32_t>(c - 'a' + 10);
                    else if (c >= 'A' && c <= 'F') v |= static_cast<uint32_t>(c - 'A' + 10);
                    else return fail("bad \\u escape");
                }
                return true;
            }
            // One raw UTF-8 sequence at p (first byte >= 0x80), validated: no overlongs, surrogates or > U+10FFFF.
            bool utf8(std::string& o)
            {
                const auto c = static_cast<unsigned char>(t[p]);
                int need;
                unsigned char lo = 0x80, hi = 0xBF;
                if (c >= 0xC2 && c <= 0xDF) need = 1;
                else if (c == 0xE0) { need = 2; lo = 0xA0; }
                else if (c == 0xED) { need = 2; hi = 0x9F; }
                else if (c >= 0xE1 && c <= 0xEF) need = 2;
                else if (c == 0xF0) { need = 3; lo = 0x90; }
                else if (c >= 0xF1 && c <= 0xF3) need = 3;
                else if (c == 0xF4) { need = 3; hi = 0x8F; }
                else return fail("invalid UTF-8");
                if (p + static_cast<size_t>(need) >= t.size()) return fail("invalid UTF-8");
                for (int k = 1; k <= need; ++k)
                {
                    const auto ck = static_cast<unsigned char>(t[p + static_cast<size_t>(k)]);
                    const unsigned char l = k == 1 ? lo : 0x80, h = k == 1 ? hi : 0xBF;
                    if (ck < l || ck > h) return fail("invalid UTF-8");
                }
                o.append(t.substr(p, static_cast<size_t>(need) + 1));
                p += static_cast<size_t>(need) + 1;
                return true;
            }
            bool str(std::string& o)
            {
                ++p; // opening quote
                while (true)
                {
                    if (p >= t.size()) return fail("unterminated string");
                    const auto c = static_cast<unsigned char>(t[p]);
                    if (c == '"')
                    {
                        ++p;
                        return true;
                    }
                    if (c < 0x20) return fail("control character in string");
                    if (c == '\\')
                    {
                        ++p;
                        if (p >= t.size()) return fail("unterminated string");
                        const char e = t[p++];
                        switch (e)
                        {
                        case '"': o.push_back('"'); break;
                        case '\\': o.push_back('\\'); break;
                        case '/': o.push_back('/'); break;
                        case 'b': o.push_back('\b'); break;
                        case 'f': o.push_back('\f'); break;
                        case 'n': o.push_back('\n'); break;
                        case 'r': o.push_back('\r'); break;
                        case 't': o.push_back('\t'); break;
                        case 'u':
                        {
                            uint32_t u{};
                            if (!hex4(u)) return false;
                            if (u >= 0xD800 && u <= 0xDBFF)
                            {
                                uint32_t lo{};
                                if (p + 2 > t.size() || t[p] != '\\' || t[p + 1] != 'u') return fail("lone surrogate");
                                p += 2;
                                if (!hex4(lo)) return false;
                                if (lo < 0xDC00 || lo > 0xDFFF) return fail("lone surrogate");
                                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                            }
                            else if (u >= 0xDC00 && u <= 0xDFFF)
                            {
                                return fail("lone surrogate");
                            }
                            put_utf8(o, u);
                            break;
                        }
                        default:
                            return fail("bad escape");
                        }
                        continue;
                    }
                    if (c >= 0x80)
                    {
                        if (!utf8(o)) return false;
                        continue;
                    }
                    o.push_back(static_cast<char>(c));
                    ++p;
                }
            }
            bool num(Value& v)
            {
                const size_t s = p;
                if (t[p] == '-') ++p;
                if (p >= t.size()) return fail("bad number");
                if (t[p] == '0') ++p;
                else if (t[p] >= '1' && t[p] <= '9')
                {
                    while (p < t.size() && t[p] >= '0' && t[p] <= '9') ++p;
                }
                else return fail("bad number");
                bool integer = true;
                if (p < t.size() && t[p] == '.')
                {
                    integer = false;
                    ++p;
                    if (p >= t.size() || t[p] < '0' || t[p] > '9') return fail("bad number");
                    while (p < t.size() && t[p] >= '0' && t[p] <= '9') ++p;
                }
                if (p < t.size() && (t[p] == 'e' || t[p] == 'E'))
                {
                    integer = false;
                    ++p;
                    if (p < t.size() && (t[p] == '+' || t[p] == '-')) ++p;
                    if (p >= t.size() || t[p] < '0' || t[p] > '9') return fail("bad number");
                    while (p < t.size() && t[p] >= '0' && t[p] <= '9') ++p;
                }
                const std::string_view lit = t.substr(s, p - s);
                if (integer)
                {
                    int64_t x{};
                    const auto r = std::from_chars(lit.data(), lit.data() + lit.size(), x);
                    if (r.ec == std::errc{} && r.ptr == lit.data() + lit.size())
                    {
                        v.type = Value::Type::Int;
                        v.i = x;
                    }
                    else
                    {
                        v.type = Value::Type::BigInt;
                        v.s = std::string{lit};
                    }
                    return true;
                }
                double d{};
                const auto r = std::from_chars(lit.data(), lit.data() + lit.size(), d);
                if (r.ptr != lit.data() + lit.size() || (r.ec != std::errc{} && r.ec != std::errc::result_out_of_range)) return fail("bad number");
                v.type = Value::Type::Float;
                v.f = d;
                return true;
            }
            bool value(Value& v, int depth)
            {
                ws();
                if (p >= t.size()) return fail("unexpected end");
                const char c = t[p];
                if (c == '{')
                {
                    if (depth >= max_depth) return fail("nested too deeply");
                    ++p;
                    v.type = Value::Type::Object;
                    ws();
                    if (p < t.size() && t[p] == '}')
                    {
                        ++p;
                        return true;
                    }
                    while (true)
                    {
                        ws();
                        if (p >= t.size() || t[p] != '"') return fail("expected a key");
                        std::string k;
                        if (!str(k)) return false;
                        for (const auto& have : v.keys)
                        {
                            if (ascii_iequal(have, k)) return fail("duplicate key");
                        }
                        ws();
                        if (p >= t.size() || t[p] != ':') return fail("expected ':'");
                        ++p;
                        Value m;
                        if (!value(m, depth + 1)) return false;
                        v.keys.push_back(std::move(k));
                        v.vals.push_back(std::move(m));
                        ws();
                        if (p < t.size() && t[p] == ',')
                        {
                            ++p;
                            continue;
                        }
                        if (p < t.size() && t[p] == '}')
                        {
                            ++p;
                            return true;
                        }
                        return fail("expected ',' or '}'");
                    }
                }
                if (c == '[')
                {
                    if (depth >= max_depth) return fail("nested too deeply");
                    ++p;
                    v.type = Value::Type::Array;
                    ws();
                    if (p < t.size() && t[p] == ']')
                    {
                        ++p;
                        return true;
                    }
                    while (true)
                    {
                        Value m;
                        if (!value(m, depth + 1)) return false;
                        v.items.push_back(std::move(m));
                        ws();
                        if (p < t.size() && t[p] == ',')
                        {
                            ++p;
                            continue;
                        }
                        if (p < t.size() && t[p] == ']')
                        {
                            ++p;
                            return true;
                        }
                        return fail("expected ',' or ']'");
                    }
                }
                if (c == '"')
                {
                    v.type = Value::Type::String;
                    return str(v.s);
                }
                if (c == 't')
                {
                    v = Value::boolean(true);
                    return lit("true");
                }
                if (c == 'f')
                {
                    v = Value::boolean(false);
                    return lit("false");
                }
                if (c == 'n')
                {
                    v = Value::null();
                    return lit("null");
                }
                if (c == '-' || (c >= '0' && c <= '9')) return num(v);
                return fail("unexpected character");
            }
        };

        void write_to(std::string& o, const Value& v, bool pretty, int indent)
        {
            auto nl = [&](int n) {
                if (!pretty) return;
                o += "\r\n";
                o.append(static_cast<size_t>(n) * 2, ' ');
            };
            switch (v.type)
            {
            case Value::Type::Null: o += "null"; break;
            case Value::Type::Bool: o += v.b ? "true" : "false"; break;
            case Value::Type::Int: o += std::to_string(v.i); break;
            case Value::Type::BigInt: o += v.s; break;
            case Value::Type::Float:
            {
                if (!std::isfinite(v.f))
                {
                    o += "null";
                    break;
                }
                char buf[64];
                const auto r = std::to_chars(buf, buf + sizeof buf, v.f);
                o.append(buf, r.ptr);
                break;
            }
            case Value::Type::String: o += quote(v.s); break;
            case Value::Type::Array:
                if (v.items.empty())
                {
                    o += "[]";
                    break;
                }
                o += '[';
                for (size_t i = 0; i < v.items.size(); ++i)
                {
                    if (i) o += ',';
                    nl(indent + 1);
                    write_to(o, v.items[i], pretty, indent + 1);
                }
                nl(indent);
                o += ']';
                break;
            case Value::Type::Object:
                if (v.keys.empty())
                {
                    o += "{}";
                    break;
                }
                o += '{';
                for (size_t i = 0; i < v.keys.size(); ++i)
                {
                    if (i) o += ',';
                    nl(indent + 1);
                    o += quote(v.keys[i]);
                    o += pretty ? ": " : ":";
                    write_to(o, v.vals[i], pretty, indent + 1);
                }
                nl(indent);
                o += '}';
                break;
            }
        }
    } // namespace

    bool parse(std::string_view text, Value& out, std::string& error, int max_depth)
    {
        if (text.size() >= 3 && static_cast<unsigned char>(text[0]) == 0xEF && static_cast<unsigned char>(text[1]) == 0xBB &&
            static_cast<unsigned char>(text[2]) == 0xBF)
        {
            text.remove_prefix(3);
        }
        Parser ps{text};
        ps.max_depth = max_depth;
        Value v;
        if (!ps.value(v, 0))
        {
            error = ps.err.empty() ? "invalid JSON" : ps.err;
            return false;
        }
        ps.ws();
        if (ps.p != text.size())
        {
            ps.fail("text after the value");
            error = ps.err;
            return false;
        }
        out = std::move(v);
        return true;
    }

    std::string quote(std::string_view s)
    {
        std::string o;
        o.reserve(s.size() + 2);
        o += '"';
        for (const char ch : s)
        {
            const auto c = static_cast<unsigned char>(ch);
            switch (c)
            {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            case '\b': o += "\\b"; break;
            case '\f': o += "\\f"; break;
            default:
                if (c < 0x20 || c == 0x7F)
                {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", c);
                    o += buf;
                }
                else
                {
                    o += ch;
                }
            }
        }
        o += '"';
        return o;
    }

    std::string write(const Value& v, bool pretty)
    {
        std::string o;
        write_to(o, v, pretty, 0);
        return o;
    }
} // namespace catalog::json
