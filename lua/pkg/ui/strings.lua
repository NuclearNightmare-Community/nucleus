-- Story 21 (Mod Manager story 2): core's user-facing strings, per language, and the one rule that picks a string from
-- a per-language table: the game's current language tag (KismetInternationalizationLibrary:GetCurrentLanguage, e.g.
-- "zh-Hans"), then its prefix before "-" ("zh"), then English. The game registers no string tables a mod could add to
-- (docs/mod-manager-research.md 9.2), so labels are Lua tables. Every string core shows next to the game's own labels
-- is upper case, like theirs (their Transform Policy is none).
--
-- A dependent's label table (menu.entry's label) is validated here: en required (the fallback), at most 16
-- languages, keys of letters and "-" (at most 16 characters), each string 1 to 64 bytes; en must be upper case.
local BASE = (...):gsub("%.ui%.strings$", "")
local C = require(BASE .. ".ui.common")

local S = {}
S.MAX_LANGS = 16
S.MAX_TAG = 16
S.MAX_BYTES = 64

-- Core's own strings: language -> key -> string. Add a language as one table; English is required for every key.
S.CORE = {
    en = { close = "CLOSE", back = "BACK" }, -- core story 27: BACK replaces CLOSE on windows; close stays
}

local KIL = "/Script/Engine.Default__KismetInternationalizationLibrary"

-- The game's current language tag ("en", "zh-Hans", ...), or "en" when it can't be read. Reads a class default
-- object that always exists (a hash hit, never a scan), so it is safe inside a hook.
function S.language()
    local ok, lang = pcall(function()
        local kil = C.found(KIL)
        if not kil then return nil end
        local v = kil:GetCurrentLanguage()
        if type(v) == "string" then return v end
        return v:ToString()
    end)
    if ok and type(lang) == "string" and lang ~= "" then return lang end
    return "en"
end

-- The string for key k in t: the key as given, else one that differs only in case (tags are case-insensitive:
-- "zh-hans" matches the game's "zh-Hans").
local function get(t, k)
    local v = t[k]
    if type(v) == "string" then return v, k end
    local lk = k:lower()
    for key, s in pairs(t) do
        if type(key) == "string" and type(s) == "string" and key:lower() == lk then return s, key end
    end
    return nil
end

-- The string for lang from a per-language table: the exact tag, then its prefix before "-", then en; tags are
-- matched without regard to case.
function S.pick(t, lang)
    lang = lang or S.language()
    local v, k = get(t, lang)
    if v then return v, k end
    local prefix = lang:match("^([^-]+)%-")
    if prefix then
        v, k = get(t, prefix)
        if v then return v, k end
    end
    return t.en, "en"
end

-- Core's own string for key, in the current language.
function S.core(key, lang)
    lang = lang or S.language()
    local byLang = {}
    for l, t in pairs(S.CORE) do byLang[l] = t[key] end
    return (S.pick(byLang, lang))
end

-- The language-tag rules a per-language table shares (labels, tooltips): at most 16 languages, each key a tag of
-- letters and "-" of at most 16 characters. what is "label" or "tooltip".
local function checkLangs(t, pre, what, n, k)
    if n > S.MAX_LANGS then
        local total = 0
        for _ in pairs(t) do total = total + 1 end
        C.fail("%s: %s has %d languages, at most %d", pre, what, total, S.MAX_LANGS)
    end
    if type(k) ~= "string" or #k == 0 or #k > S.MAX_TAG or not k:match("^[A-Za-z%-]+$") then
        C.fail("%s: %s key %s is not a language tag (letters and -, at most %d characters)", pre, what, C.describe(k), S.MAX_TAG)
    end
end

-- Validates a dependent's per-language label table and returns a copy. fn is e.g. "menu.entry".
function S.validateLabel(label, fn)
    local pre = C.UI .. "." .. fn
    if type(label) ~= "table" then
        C.fail("%s: label must be a table of strings by language, like { en = \"MANAGE MODS\" }, got %s", pre, C.describe(label))
    end
    local n = 0
    local out = {}
    for k, v in pairs(label) do
        n = n + 1
        checkLangs(label, pre, "label", n, k)
        if type(v) ~= "string" or #v < 1 or #v > S.MAX_BYTES then
            C.fail("%s: label.%s must be a string of 1 to %d bytes, got %s", pre, k, S.MAX_BYTES, C.describe(v))
        end
        out[k] = v
    end
    if out.en == nil then C.fail("%s: label needs an en string (the fallback)", pre) end
    if out.en:upper() ~= out.en then
        C.fail("%s: label.en must be upper case like the menu's own labels, got %s", pre, C.describe(out.en))
    end
    return out
end

-- Story 24 (core 0.8.0): a tooltip is a string or a per-language table (en required, the language tag rules above),
-- each string 1 to 512 bytes of plain text: no byte below 0x20 but newline. No upper-case rule (a tooltip is a
-- sentence, not one of the menu's labels). Returns a per-language copy ({ en = s } for a string), or nil for nil.
-- pre is the error prefix, e.g. "nucleus.ui.button.create".
S.MAX_TIP = 512
local function tipString(v, pre, what)
    if type(v) ~= "string" or #v < 1 or #v > S.MAX_TIP then
        local got = type(v) == "string" and string.format("%d bytes", #v) or C.describe(v)
        C.fail("%s: %s must be a string of 1 to %d bytes, got %s", pre, what, S.MAX_TIP, got)
    end
    local bad = v:find("[\0-\9\11-\31]")
    if bad then
        C.fail("%s: %s has the control byte 0x%02X at byte %d (plain text only; newline is the one byte below 0x20 allowed)", pre, what, v:byte(bad), bad)
    end
    return v
end
-- Core story 33 (0.15.0): what names the value in the errors ("tooltip" when nil; "help" for a game-style row's "?").
function S.validateTooltip(tip, pre, what)
    what = what or "tooltip"
    if tip == nil then return nil end
    if type(tip) == "string" then return { en = tipString(tip, pre, what) } end
    if type(tip) ~= "table" then
        C.fail("%s: %s must be a string or a table of strings by language, like { en = \"...\" }, got %s", pre, what, C.describe(tip))
    end
    local n, out = 0, {}
    for k, v in pairs(tip) do
        n = n + 1
        checkLangs(tip, pre, what, n, k)
        out[k] = tipString(v, pre, what .. "." .. k)
    end
    if out.en == nil then C.fail("%s: %s needs an en string (the fallback)", pre, what) end
    return out
end

-- Core story 33 (0.15.0): a game-style row's help (the "?"'s tooltip, in the game's own tooltip widget): a tooltip as
-- above, of at most 8 lines per string.
S.MAX_HELP_LINES = 8
function S.validateHelp(help, pre)
    local out = S.validateTooltip(help, pre, "help")
    if out == nil then return nil end
    local keys = {}
    for k in pairs(out) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local _, nl = out[k]:gsub("\n", "")
        if nl + 1 > S.MAX_HELP_LINES then
            C.fail("%s: %s has %d lines, at most %d", pre, type(help) == "string" and "help" or ("help." .. k), nl + 1, S.MAX_HELP_LINES)
        end
    end
    return out
end

-- Core story 33 (0.15.0): a game-style row's label: a string or a per-language table (en required, the language tag
-- rules above), each string 1 to 64 bytes of plain text on one line (no byte below 0x20). No upper-case rule: the
-- create-server screen's own row labels are in mixed case. Returns a per-language copy ({ en = s } for a string).
local function labelString(v, pre, what)
    if type(v) ~= "string" or #v < 1 or #v > S.MAX_BYTES then
        local got = type(v) == "string" and string.format("%d bytes", #v) or C.describe(v)
        C.fail("%s: %s must be a string of 1 to %d bytes, got %s", pre, what, S.MAX_BYTES, got)
    end
    local bad = v:find("[\0-\31]")
    if bad then C.fail("%s: %s has the control byte 0x%02X at byte %d (plain text on one line)", pre, what, v:byte(bad), bad) end
    return v
end
function S.validateRowLabel(label, pre)
    if type(label) == "string" then return { en = labelString(label, pre, "label") } end
    if type(label) ~= "table" then
        C.fail("%s: label must be a string or a table of strings by language, like { en = \"Enemy Damage\" }, got %s", pre, C.describe(label))
    end
    local n, out = 0, {}
    for k, v in pairs(label) do
        n = n + 1
        checkLangs(label, pre, "label", n, k)
        out[k] = labelString(v, pre, "label." .. k)
    end
    if out.en == nil then C.fail("%s: label needs an en string (the fallback)", pre) end
    return out
end

return S
