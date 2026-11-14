-- Unit tests for nucleus.json (Mod Manager story 5): the strict, bounded reader and the writer, outside the game.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/json_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.9.0", floor = "0.1.0" } end
table.insert(package.searchers, 2, function(name)
    local rest = name:match("^nucleus%.(.+)$")
    if not rest then return nil end
    local path = ROOT .. "/lua/pkg/" .. rest:gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return "\n\tno file " .. path end
    f:close()
    return assert(loadfile(path)), path
end)

local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end

local J = require("nucleus.json")

-- ---------------------------------------------------------------- values
local v, o = J.decode('{"b":1,"a":[true,false,null],"c":"x","d":-2.5e1,"e":0,"f":-0,"g":1.0}')
ok(type(v) == "table", "object decodes", o)
eq(table.concat(o[v], ","), "b,a,c,d,e,f,g", "objects keep key order")
eq(math.type(v.b), "integer", "1 is an integer")
eq(v.d, -25.0, "-2.5e1"); eq(math.type(v.d), "float", "-2.5e1 is a float")
eq(math.type(v.g), "float", "1.0 is a float")
eq(v.f, 0, "-0 reads as 0"); eq(math.type(v.f), "integer", "-0 is an integer")
ok(J.isArray(v.a) and #v.a == 3 and v.a[1] == true and v.a[2] == false and v.a[3] == J.null, "array with true, false, null")
eq(v.c, "x", "string")
eq(select(1, J.decode("  42 \r\n\t")), 42, "top-level scalar with whitespace")
eq(select(1, J.decode('"\\u00e9\\u20ac\\ud83d\\ude00\\n\\t\\"\\\\\\/"')), "\195\169\226\130\172\240\159\152\128\n\t\"\\/", "escapes and a surrogate pair")
eq(select(1, J.decode("\239\187\191{}")) ~= nil, true, "a leading UTF-8 BOM is ignored")
eq(select(1, J.decode('"\127"')), "\127", "DEL is allowed unescaped")
eq(select(1, J.decode("9223372036854775807")), math.maxinteger, "max int64")
eq(math.type((J.decode("9223372036854775808"))), "float", "2^63 is a float")
eq(math.type((J.decode("123456789012345678901234567890"))), "float", "a huge integer is a float")
local e1 = J.decode("{}"); ok(type(e1) == "table" and not J.isArray(e1) and next(e1) == nil, "empty object")
local e2 = J.decode("[]"); ok(J.isArray(e2) and #e2 == 0, "empty array")
eq(select(1, J.decode('"\226\130\172"')), "\226\130\172", "raw UTF-8 passes")

-- ---------------------------------------------------------------- errors: nil, "<line>:<col> <reason>", never a raise
local bad = {
    { '{"a":1,"a":2}', "1:8 duplicate key" },
    { '{"a":1,}', "1:8 trailing comma" },
    { '[1,2,]', "1:6 trailing comma" },
    { '{"a":1} // c', "1:9 comments are not allowed" },
    { '/* c */ {}', "1:1 comments are not allowed" },
    { 'NaN', "1:1 unexpected character" },
    { 'Infinity', "1:1 unexpected character" },
    { '-Infinity', "1:1 unexpected character" },
    { '1e999', "1:1 number out of range" },
    { '"\\ud800"', "1:2 lone surrogate" },
    { '"\\udc00"', "1:2 lone surrogate" },
    { '"\\ud800\\u0041"', "1:2 lone surrogate" },
    { '{"a":', "1:6 unexpected end of input" },
    { '{"a"', "1:5 expected ':'" },
    { '{"a":1', "1:1 unterminated object" },
    { '[1', "1:1 unterminated array" },
    { '"abc', "1:1 unterminated string" },
    { '"a\nb"', "1:3 control character" },
    { '"a\tb"', "1:3 control character" },
    { '"\\x"', "1:2 bad escape" },
    { '"\\u12"', "1:2 bad \\u escape" },
    { '01', "1:1 leading zero" },
    { '-01', "1:1 leading zero" },
    { '1.', "1:2 bad number" },
    { '.5', "1:1 unexpected character" },
    { '1e', "1:2 bad number" },
    { '+1', "1:1 unexpected character" },
    { "{'a':1}", "1:2 expected a string key" },
    { '{a:1}', "1:2 expected a string key" },
    { 'tru', "1:1 unexpected character" },
    { '{} {}', "1:4 unexpected text after the value" },
    { '', "1:1 unexpected end of input" },
    { '"\255"', "1:2 invalid UTF-8" },
    { '"\192\128"', "1:2 invalid UTF-8" },
    { '"\237\160\128"', "1:2 invalid UTF-8" },
    { '{\n  "a": 1,\n  "a": 2\n}', "3:3 duplicate key" },
}
for i, c in ipairs(bad) do
    local okP, r, why = pcall(J.decode, c[1])
    ok(okP and r == nil and type(why) == "string" and why:sub(1, #c[2]) == c[2], "rejects " .. i .. " " .. c[1]:sub(1, 20):gsub("%c", "?"), tostring(why))
    ok(okP and why and why:find("^%d+:%d+ ") ~= nil, "error " .. i .. " starts with line:col", tostring(why))
end
for i, x in ipairs({ nil, 42, {}, true }) do
    local okP, r, why = pcall(J.decode, x)
    ok(okP and r == nil and type(why) == "string", "a non-string input is an error, not a raise (" .. i .. ")")
end

-- ---------------------------------------------------------------- caps
eq(select(2, J.decode(string.rep(" ", 65537))), "1:1 input is 65537 bytes, cap 65536", "input over 65,536 bytes")
ok(J.decode('"' .. string.rep("a", 65534) .. '"') == nil, "65,536 bytes passes the size cap (then the string cap)")
local deep16 = string.rep("[", 16) .. string.rep("]", 16)
ok(J.decode(deep16) ~= nil, "depth 16 is allowed")
local deep17 = string.rep("[", 17) .. string.rep("]", 17)
ok(select(2, J.decode(deep17)):find("nested deeper than 16", 1, true), "depth 17 is refused")
ok(select(2, J.decode(string.rep("[", 40) .. string.rep("]", 40))):find("nested deeper than 16", 1, true), "depth 40 is refused")
ok(select(2, J.decode(string.rep('{"a":', 40) .. "1" .. string.rep("}", 40))):find("nested deeper than 16", 1, true), "object depth 40 is refused")
local many = "[" .. string.rep("0,", 4094) .. "0]" -- 1 array + 4095 numbers = 4096 values
ok(J.decode(many) ~= nil, "4,096 values are allowed")
local tooMany = "[" .. string.rep("0,", 4095) .. "0]"
ok(select(2, J.decode(tooMany)):find("more than 4096 values", 1, true), "4,097 values are refused")
ok(J.decode('"' .. string.rep("a", 1024) .. '"') ~= nil, "a 1,024-byte string is allowed")
ok(select(2, J.decode('"' .. string.rep("a", 1025) .. '"')):find("longer than 1024 bytes", 1, true), "a 1,025-byte string is refused")
ok(select(2, J.decode('"' .. string.rep("\\u00e9", 513) .. '"')):find("longer than 1024 bytes", 1, true), "the string cap counts bytes after unescaping")
ok(select(2, J.decode('{"' .. string.rep("k", 1025) .. '":1}')):find("longer than 1024 bytes", 1, true), "keys have the string cap too")
ok(J.decode(string.rep(" ", 70000), { maxBytes = 100000 }) == nil, "caps can be raised (then the empty input is the error)")
eq(select(2, J.decode(string.rep(" ", 70000), { maxBytes = 100000 })), "1:70001 unexpected end of input", "raised cap: the next error")
ok(J.decode('{"a":{"b":1}}', { maxDepth = 1 }) == nil, "caps can be lowered")

-- never runs code: a Lua chunk is just a syntax error
ok(J.decode("return os.exit(1)") == nil, "Lua code is not JSON")

-- ---------------------------------------------------------------- writer
eq(J.encodeFlat({ b = 2, a = true, c = "x\"y\n", z = 1.5 }, { "c", "a", "b", "z", "missing" }), '{"c":"x\\"y\\n","a":true,"b":2,"z":1.5}', "flat object in the given order")
eq(J.encodeFlat({ n = 5 }, { "n" }), '{"n":5}', "integers as integers")
eq(J.encodeFlat({ n = 0.1 }, { "n" }), '{"n":0.1}', "shortest float that reads back")
eq(J.encodeFlat({ n = 1 / 3 }, { "n" }), '{"n":0.3333333333333333}', "1/3 round-trips")
eq(J.decode(J.encodeFlat({ n = 1 / 3 }, { "n" })).n, 1 / 3, "1/3 reads back exactly")
eq(J.encodeFlat({}, {}), "{}", "empty")
eq(J.encodeFlat({ c = "\1" }, { "c" }), '{"c":"\\u0001"}', "control characters escaped")
ok(J.encodeFlat({ n = 0 / 0 }, { "n" }) == nil, "NaN can't be written")
ok(J.encodeFlat({ n = math.huge }, { "n" }) == nil, "inf can't be written")
ok(J.encodeFlat({ t = {} }, { "t" }) == nil, "a table value can't be written")
ok(J.encodeFlat({ f = print }, { "f" }) == nil, "a function value can't be written")
ok(J.encodeFlat({}, { 1 }) == nil, "a non-string key can't be written")
-- round trip through the general writer, keeping order
local src = '{"z":1,"a":{"y":[1,2.5,"s",null,true],"b":{}},"m":[]}'
local dv, dord = J.decode(src)
eq(J.encode(dv, dord), src, "decode then encode gives the same text")
ok(J.encode({ f = print }) == nil, "encode refuses a function")
ok(J.encode({ [1] = 1, a = 2 }) == nil, "encode refuses a mixed table")
local deep = {}
local cur = deep
for _ = 1, 40 do cur.x = {}; cur = cur.x end
ok(J.encode(deep) == nil, "encode refuses deep nesting")

print(string.format("json_test: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
