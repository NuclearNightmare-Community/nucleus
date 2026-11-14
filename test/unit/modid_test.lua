-- Unit tests for nucleus.modid (distribution story 13): every case of the shared cases file
-- test/unit/fixtures/modid-cases.json (a byte-identical copy of the workspace's tools/release/tests/modid-cases.json,
-- which tools/release/tests/run-modid-tests.ps1 runs through the PowerShell normalizer) read through nucleus.json, plus
-- the legacy net ids. Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/modid_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
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

local J = require("nucleus.json")
local ID = require("nucleus.modid")

local f = assert(io.open(ROOT .. "/test/unit/fixtures/modid-cases.json", "rb"))
local text = f:read("a")
f:close()
local doc, err = J.decode(text)
assert(doc, "modid-cases.json: " .. tostring(err))
ok(doc.max == ID.MAX, "the cases' max equals M.MAX", tostring(doc.max))
local n = 0
for _, c in ipairs(doc.cases) do
    n = n + 1
    local input = c.input
    if input == J.null then input = nil end
    local okP, got, why = pcall(ID.normalize, input)
    if not okP then
        ok(false, c.name, "raised: " .. tostring(got))
    elseif c.id ~= nil then
        ok(got == c.id and why == nil, c.name, "got " .. tostring(got) .. " / " .. tostring(why) .. ", want " .. c.id)
    else
        ok(got == nil and why == c.error, c.name, "got " .. tostring(got) .. " / " .. tostring(why) .. ", want error " .. tostring(c.error))
    end
end
ok(n >= 40, "the cases file holds the shared cases", n)
-- a JSON null decodes to json.null (a table); the real nil is refused the same way
do local okP, got, why = pcall(ID.normalize) ok(okP and got == nil and why == ID.ERR.type, "normalize(nil): refused, never raises") end
do local okP, got, why = pcall(ID.normalize, string.rep("x", 10240)) ok(okP and got == nil and why == ID.ERR.long, "a 10 kB string") end

-- the net id (core stories 22 and 23): legacy bare ids too, lowercased
ok(ID.netId("skeltest") == "skeltest" and ID.netId("SkelTest") == "skeltest", "netId: a legacy bare id, lowercased")
ok(ID.netId(string.rep("a", 64)) == string.rep("a", 64) and ID.netId(string.rep("a", 65)) == nil, "netId: bare ids up to 64")
ok(ID.netId("github.com/Owner.Mod") == "owner.mod", "netId: a namespaced id normalized")
ok(ID.isNetId("skeltest") and ID.isNetId("nuclearnightmare-community.nucleus"), "isNetId: normalized forms")
ok(not ID.isNetId("SkelTest") and not ID.isNetId("github.com/owner.mod") and not ID.isNetId(5), "isNetId: not normalized")

print(("modid_test: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
