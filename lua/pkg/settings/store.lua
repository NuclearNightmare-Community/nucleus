-- Core's settings service (Mod Manager story 5; runs in core's own Lua state only, on the game thread). Reads each
-- mod's declared settings from Mods/<Folder>/mod.json, keeps their values in Mods/<Folder>/settings.json (atomic
-- write, .bak recovery), checks every value, and answers the channel ops settings-get and settings-set. One writer for
-- every mod's values: the Mod Manager and the mods themselves all go through here.
--
-- A mod is addressed by its folder under ue4ss/Mods (validated before any path is built). Nothing is ever executed:
-- mod.json and settings.json are read with the bounded JSON reader. Only Mods/<Folder>/settings.json, .tmp and .bak are
-- ever written, renamed or removed.
--
-- init{ modsDir, core = <core's folder>, log, publishRev = fn(n), world = fn() -> world name or nil, rev = <start> }
-- op(name, payload) -> reply ("ok:..." | "err:<code> <detail>"); name is "settings-get" or "settings-set".
-- describe(folder), set(folder, key, value) for core's own use and the unit tests.
local BASE = (...):gsub("%.settings%.store$", "")
local json = require(BASE .. ".json")
local schema = require(BASE .. ".settings.schema")

local M = {}

M.FOLDER = "^[A-Za-z0-9_-]+$"
M.MAX_FOLDER = 64
M.MAX_VALUES_FILE = 16384
M.MAX_MANIFEST = 65536

local E -- the environment init gave
local mods = {} -- folder -> state (this session)
local rev = 0

local quote = schema.quote

local function validFolder(f) return type(f) == "string" and #f >= 1 and #f <= M.MAX_FOLDER and f:find(M.FOLDER) ~= nil end
M.validFolder = validFolder

local function path(folder, file) return E.modsDir .. "\\" .. folder .. "\\" .. file end

-- Reads a whole file up to cap bytes. -> text | nil, "missing" | reason
local function readFile(p, cap)
    local f = io.open(p, "rb")
    if not f then return nil, "missing" end
    local ok, text = pcall(f.read, f, cap + 1)
    pcall(f.close, f)
    if not ok then return nil, "unreadable" end
    text = text or ""
    if #text > cap then return nil, string.format("larger than %d bytes", cap) end
    return text
end
M._readFile = readFile

local function warn(fmt, ...) if E and E.log then pcall(E.log.warn, fmt, ...) end end
local function info(fmt, ...) if E and E.log then pcall(E.log.info, fmt, ...) end end

function M.init(env)
    if type(env) ~= "table" or type(env.modsDir) ~= "string" or env.modsDir == "" then
        error("settings store: init needs a non-empty modsDir string", 0)
    end
    E = env
    mods = {}
    rev = math.type(env.rev) == "integer" and env.rev or 0
end
function M.rev() return rev end

-- -------------------------------------------------------------- values file
-- Reads Mods/<folder>/settings.json into { key -> value } (checked against the declarations). Missing: defaults with
-- one info line; corrupt or invalid: defaults with one WARN (once per folder per session each). A missing file with a
-- .bak beside it (a write interrupted between its renames) is restored from the .bak first.
local function loadValues(st)
    local target, bak = path(st.folder, "settings.json"), path(st.folder, "settings.json.bak")
    local text, why = readFile(target, M.MAX_VALUES_FILE)
    if why == "missing" then
        local btext = readFile(bak, M.MAX_VALUES_FILE)
        if btext then
            local okR = os.rename(bak, target)
            info("settings: %s: settings.json was missing; restored it from settings.json.bak%s", st.folder, okR and "" or " (rename failed; read the .bak)")
            text, why = btext, nil
        end
    end
    local values = {}
    -- The values file's problems, rebuilt on every read (a later good write clears them); the WARNs stay once per session.
    st.fileProblems = {}
    if not text then
        if why == "missing" then
            if not st.toldMissing then st.toldMissing = true; info("settings: %s: no settings.json; using the declared defaults", st.folder) end
        else
            st.fileProblems[1] = "settings.json " .. why .. "; defaults used"
            if not st.warned then
                st.warned = true
                warn("settings: %s: settings.json %s; using the declared defaults", st.folder, why)
            end
        end
        return values
    end
    local root, err = json.decode(text, { maxBytes = M.MAX_VALUES_FILE })
    if root == nil or type(root) ~= "table" or json.isArray(root) or root == json.null then
        local reason = root == nil and ("is corrupt (" .. quote(err) .. ")") or "is not a JSON object"
        st.fileProblems[1] = "settings.json " .. reason .. "; defaults used"
        if not st.warned then
            st.warned = true
            warn("settings: %s: settings.json %s; using the declared defaults", st.folder, reason)
        end
        return values
    end
    local dropped = {}
    for _, k in ipairs(err[root] or {}) do -- err is the orders table on success
        local d = st.manifest.byKey[k]
        local v = root[k]
        if not d then dropped[#dropped + 1] = quote(k) .. " (unknown)"
        elseif d.readOnly then dropped[#dropped + 1] = k .. " (read-only)"
        else
            local cv, bad = schema.check(d, v)
            if cv == nil then dropped[#dropped + 1] = k .. " (" .. bad .. ")" else values[k] = cv end
        end
    end
    if #dropped > 0 then
        local list = table.concat(dropped, ", ", 1, math.min(#dropped, 8)) .. (#dropped > 8 and ", ..." or "")
        st.fileProblems[1] = "settings.json entries ignored: " .. list
        if not st.warnedDropped then
            st.warnedDropped = true
            warn("settings: %s: settings.json entries ignored: %s", st.folder, list)
        end
    end
    return values
end

-- The state of one folder, loaded on first use this session. -> st | nil, code, detail
local function state(folder)
    if not validFolder(folder) then return nil, "bad-request", "folder must match [A-Za-z0-9_-]{1,64}" end
    -- Windows paths ignore case, so Clock and clock are one folder: one state, keyed by the lowercase name.
    local st = mods[folder:lower()]
    if st then return st end
    local text, why = readFile(path(folder, "mod.json"), M.MAX_MANIFEST)
    if not text then return nil, "unknown-mod", folder .. (why == "missing" and " has no mod.json" or (": mod.json " .. why)) end
    local m, perr = schema.parse(text, folder)
    if not m then return nil, "unknown-mod", folder .. ": " .. perr end
    st = { folder = folder, manifest = m, problems = {} }
    for _, p in ipairs(m.problems) do
        st.problems[#st.problems + 1] = p
        warn("settings: %s", p)
    end
    -- A mod that declares no settings has no values file to read (and no line about a missing one).
    st.saved = m.hasSettings and loadValues(st) or {}
    st.session = {}
    for k, v in pairs(st.saved) do st.session[k] = v end
    mods[folder:lower()] = st
    return st
end

-- The value a setting has now: for restart settings the one loaded at session start.
local function effective(st, d)
    if d.readOnly then return nil end
    if d.changeable == "restart" then
        local v = st.session[d.key]
        if v == nil then return d.default end
        return v
    end
    local v = st.saved[d.key]
    if v == nil then return d.default end
    return v
end
local function savedValue(st, d)
    local v = st.saved[d.key]
    if v == nil then return d.default end
    return v
end

local function describeEntry(st, d)
    local e = { key = d.key, type = d.type, label = d.label, changeable = d.changeable, readOnly = d.readOnly,
                restart = d.changeable == "restart", pendingRestart = false }
    if d.default ~= nil then e.default = d.default end
    e.min, e.max, e.step, e.help, e.scope, e.source = d.min, d.max, d.step, d.help, d.scope, d.source
    if d.values then e.values = json.array({ table.unpack(d.values) }) end
    if not d.readOnly then
        e.value = effective(st, d)
        if d.changeable == "restart" then
            local saved = savedValue(st, d)
            if saved ~= e.value then e.pendingRestart = true; e.saved = saved end
        end
    end
    return e
end
local ENTRY_ORDER = { "key", "type", "default", "min", "max", "step", "values", "label", "help", "changeable", "scope", "source",
                      "value", "readOnly", "restart", "pendingRestart", "saved" }

-- describe(folder) -> description, orders | nil, code, detail
function M.describe(folder)
    local st, code, detail = state(folder)
    if not st then return nil, code, detail end
    if not st.manifest.hasSettings then return nil, "no-settings", folder .. " declares no settings" end
    local orders = {}
    local list = json.array()
    for _, d in ipairs(st.manifest.settings) do
        local e = describeEntry(st, d)
        orders[e] = ENTRY_ORDER
        list[#list + 1] = e
    end
    -- The manifest's problems, then the values file's (each capped at a UTF-8 boundary, so the reply stays readable).
    local problems = json.array()
    for _, list in ipairs({ st.problems, st.fileProblems or {} }) do
        for _, p in ipairs(list) do problems[#problems + 1] = schema.cut(p, schema.MAX_PROBLEM) end
    end
    local desc = { id = st.manifest.id, name = st.manifest.name, folder = folder, settings = list, problems = problems }
    orders[desc] = { "id", "name", "folder", "settings", "problems" }
    return desc, orders
end

-- Writes the values that differ from the defaults, in declaration order: tmp written, flushed, closed, re-read and
-- compared; target -> .bak; tmp -> target; .bak removed. -> true | nil, reason. On failure the previous file stays.
local function writeValues(st, values)
    local keys, out = {}, {}
    for _, d in ipairs(st.manifest.settings) do
        local v = values[d.key]
        if v ~= nil and not d.readOnly and v ~= d.default then keys[#keys + 1] = d.key; out[d.key] = v end
    end
    local text, why = json.encodeFlat(out, keys)
    if not text then return nil, "encode: " .. why end
    if #text > M.MAX_VALUES_FILE then return nil, "values file would be " .. #text .. " bytes" end
    local target, tmp, bak = path(st.folder, "settings.json"), path(st.folder, "settings.json.tmp"), path(st.folder, "settings.json.bak")
    local f, oerr = io.open(tmp, "wb")
    if not f then return nil, "open tmp: " .. tostring(oerr) end
    local okW, werr = pcall(function()
        assert(f:write(text))
        assert(f:flush())
    end)
    local okC = pcall(f.close, f)
    if not okW or not okC then os.remove(tmp) return nil, "write tmp: " .. tostring(werr) end
    local back = readFile(tmp, M.MAX_VALUES_FILE)
    if back ~= text then os.remove(tmp) return nil, "tmp read back differs" end
    local hadTarget = io.open(target, "rb")
    if hadTarget then
        hadTarget:close()
        os.remove(bak) -- a stale .bak from an interrupted write; the target is newer
        local okB, berr = os.rename(target, bak)
        if not okB then os.remove(tmp) return nil, "rename to .bak: " .. tostring(berr) end
    end
    local okT, terr = os.rename(tmp, target)
    if not okT then
        if hadTarget then os.rename(bak, target) end
        os.remove(tmp)
        return nil, "rename tmp: " .. tostring(terr)
    end
    if hadTarget then os.remove(bak) end
    return true
end

-- set(folder, key, value) -> entry, orders | nil, code, detail. The menu window reads the current world from init's world().
function M.set(folder, key, value)
    local st, code, detail = state(folder)
    if not st then return nil, code, detail end
    if not st.manifest.hasSettings then return nil, "no-settings", folder .. " declares no settings" end
    if type(key) ~= "string" then return nil, "bad-request", "key must be a string" end
    local d = st.manifest.byKey[key]
    if not d then return nil, "unknown-key", "'" .. key .. "' in " .. folder end
    if d.readOnly then return nil, "read-only", key .. " comes from " .. d.source end
    local v, bad = schema.check(d, value)
    if v == nil then return nil, "bad-value", key .. " " .. bad end
    if d.changeable == "lobby" then return nil, "locked", key .. " changes only in the lobby" end
    if d.changeable == "menu" then
        local w = E.world and E.world() or nil
        if type(w) ~= "string" or not w:find("NewMainMenu", 1, true) then return nil, "locked", key .. " changes only at the main menu" end
    end
    local values = {}
    for k, x in pairs(st.saved) do values[k] = x end
    values[key] = v
    local okW, werr = writeValues(st, values)
    if not okW then
        warn("settings: %s: could not write settings.json (%s); %s unchanged", folder, quote(werr), key)
        return nil, "write-failed", key .. ": " .. werr
    end
    -- Read back what was written: the file is the truth from here on.
    st.saved = loadValues(st)
    rev = rev + 1
    if E.publishRev then pcall(E.publishRev, rev) end
    local e = describeEntry(st, d)
    return e, { [e] = ENTRY_ORDER }
end

local function reply(code, detail) return "err:" .. code .. " " .. quote(detail) end

-- The channel ops. payload is the text after "<op>:" or nil.
function M.op(name, payload)
    if name == "settings-get" then
        if type(payload) ~= "string" or payload == "" then return reply("bad-request", "settings-get:<Folder>") end
        if not validFolder(payload) then return reply("bad-request", "folder must match [A-Za-z0-9_-]{1,64}") end
        local desc, a, b = M.describe(payload)
        if not desc then return reply(a, b) end
        local text, why = json.encode(desc, a)
        if not text then return reply("internal", why) end
        return "ok:" .. text
    elseif name == "settings-set" then
        if type(payload) ~= "string" or payload == "" then return reply("bad-request", 'settings-set:{"mod","key","value"}') end
        local req, err = json.decode(payload, { maxDepth = 2, maxValues = 16 })
        if req == nil then return reply("bad-request", "payload: " .. err) end
        if type(req) ~= "table" or json.isArray(req) or req == json.null then return reply("bad-request", "payload must be a JSON object") end
        if type(req.mod) ~= "string" then return reply("bad-request", "mod must be a string") end
        if type(req.key) ~= "string" then return reply("bad-request", "key must be a string") end
        if req.value == nil or req.value == json.null or type(req.value) == "table" then return reply("bad-request", "value must be a bool, number or string") end
        if not validFolder(req.mod) then return reply("bad-request", "mod must match [A-Za-z0-9_-]{1,64}") end
        local e, a, b = M.set(req.mod, req.key, req.value)
        if not e then return reply(a, b) end
        local text, why = json.encode(e, a)
        if not text then return reply("internal", why) end
        return "ok:" .. text
    end
    return reply("unknown-op", name)
end

-- Test hook: forget every folder (a new session).
function M._reset() mods = {} end

return M
