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
    en = { close = "CLOSE" },
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
        if n > S.MAX_LANGS then
            local total = 0
            for _ in pairs(label) do total = total + 1 end
            C.fail("%s: label has %d languages, at most %d", pre, total, S.MAX_LANGS)
        end
        if type(k) ~= "string" or #k == 0 or #k > S.MAX_TAG or not k:match("^[A-Za-z%-]+$") then
            C.fail("%s: label key %s is not a language tag (letters and -, at most %d characters)", pre, C.describe(k), S.MAX_TAG)
        end
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

return S
