-- Core story 44: the Controls page pass of core's input service, in core's own Lua state. The game builds the page
-- itself: SettingsMenu_C makes one ActionMappingLabelButton_C row per row of the player key profile, in the VerticalBox
-- of its DisplayCategory (General, Movement, Inventory, Vehicle, Imposter; child 0 of each is the box's header), any
-- other category at the end of ControlsMenu. A core row is a row whose KeyMap.MappingName is the mapping name of an
-- active control ("<mod id>:<control id>"). On each Settings overlay the shared poll sees (ui/game.lua, host
-- "settings"; never a hook on the screen's class, story 34), and again on a poll tick after the registry changed:
--   - every row whose mapping name holds ":" and isn't an active control is collapsed (a saved row of a mod that isn't
--     loaded: the game would show it unlabeled at the bottom; the .sav keeps it);
--   - each core row goes directly after its near row in its box (several after one row keep their declaration order),
--     or to the end of the box (General) when near names no game row; box panels only append, so from the first child
--     out of order every child is taken out and added back in order (the rows have the default slot: the game adds
--     them with AddChild and sets nothing on the slot);
--   - both key selectors of a core row allow gamepad keys (game rows keep theirs off).
-- Holds no UObject: the screen is passed in by the poll's callback and everything is read from it there.
local BASE = (...):gsub("%.input%.screen$", "")
local P = require(BASE .. ".ui.place")

local SC = {}
SC.ROW_SHORT = "ActionMappingLabelButton_C"
SC.CATS = { "General", "Movement", "Inventory", "Vehicle", "Imposter" }
SC.SELECTORS = { "InputKeySelector_128", "InputKeySelector" } -- slot 0, slot 1
local COLLAPSED = 1

local function try(f, ...) local ok, v = pcall(f, ...) if ok then return v end return nil end
local function valid(o)
    if type(o) ~= "userdata" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function classOf(o) return try(function() return o:GetClass():GetFName():ToString() end) or "?" end
local function mappingOf(row) return try(function() return row.KeyMap.MappingName:ToString() end) end

-- plan(children, info) -> want, first (pure). children: the box's children in order, each { name = <mapping name or
-- "">, core = <true for an active core row> }; info(name) -> { order = n, near = s|nil, nearFound = bool } for a core
-- row. want: the children's indices in the wanted order; first: the first position that differs from now (nil: the
-- order is right). Every child that isn't a core row is a game child (dead rows and the header included).
function SC.plan(children, info)
    local gameNames, gameIdx, cores = {}, {}, {}
    for i, c in ipairs(children) do
        if c.core then cores[#cores + 1] = i
        else gameNames[#gameNames + 1] = c.name or ""; gameIdx[#gameIdx + 1] = i end
    end
    if #cores == 0 then return nil, nil end
    table.sort(cores, function(a, b)
        local ia, ib = info(children[a].name), info(children[b].name)
        if ia.order ~= ib.order then return ia.order < ib.order end
        return a < b
    end)
    local items = {}
    for k, i in ipairs(cores) do
        local inf = info(children[i].name)
        items[k] = (inf.nearFound and inf.near) and { after = inf.near } or { at = "end" }
    end
    local order = P.insertOrder(gameNames, items)
    local want = {}
    for _, o in ipairs(order) do
        want[#want + 1] = o.game and gameIdx[o.game] or cores[o.item]
    end
    for k = 1, #want do
        if want[k] ~= k then return want, k end
    end
    return want, nil
end

-- pass(screen, reg) -> stats. screen: the live SettingsMenu_draggable_C (valid only in this callback); reg(name) -> the
-- info plan takes for an active control's mapping name, else nil. stats: { rows, core, hidden, moved, gamepad, boxes }.
function SC.pass(screen, reg)
    local st = { rows = 0, core = 0, hidden = 0, moved = 0, gamepad = 0, boxes = 0 }
    local m = try(function() return screen.SettingsMenu end)
    if not valid(m) then return nil, "the Settings overlay has no SettingsMenu" end
    local boxes = {}
    for _, cat in ipairs(SC.CATS) do
        local b = try(function() return m[cat] end)
        if valid(b) then boxes[#boxes + 1] = { name = cat, box = b } end
    end
    local cm = try(function() return m.ControlsMenu end)
    if valid(cm) then boxes[#boxes + 1] = { name = "ControlsMenu", box = cm } end
    for _, bx in ipairs(boxes) do
        local box = bx.box
        local n = try(function() return box:GetChildrenCount() end) or 0
        local kids, children, any = {}, {}, false
        for i = 0, n - 1 do
            local c = try(function() return box:GetChildAt(i) end)
            if valid(c) then
                local name = classOf(c) == SC.ROW_SHORT and mappingOf(c) or nil
                local isCore = false
                if name then
                    st.rows = st.rows + 1
                    if name:find(":", 1, true) then
                        if reg(name) then isCore = true
                        elseif try(function() return c:GetVisibility() end) ~= COLLAPSED then
                            if pcall(function() c:SetVisibility(COLLAPSED) end) then st.hidden = st.hidden + 1 end
                        end
                    end
                end
                kids[#kids + 1] = c
                children[#children + 1] = { name = name or "", core = isCore }
                if isCore then
                    any = true
                    st.core = st.core + 1
                    for _, sn in ipairs(SC.SELECTORS) do
                        local s = try(function() return c[sn] end)
                        if valid(s) and try(function() return s.bAllowGamepadKeys end) ~= true then
                            if pcall(function() s:SetAllowGamepadKeys(true) end) then st.gamepad = st.gamepad + 1 end
                        end
                    end
                end
            end
        end
        if any and bx.name ~= "ControlsMenu" then
            local want, first = SC.plan(children, reg)
            if first then
                st.boxes = st.boxes + 1
                for k = first, #kids do
                    local c = kids[k]
                    pcall(function() box:RemoveChild(c) end)
                end
                for k = first, #want do
                    local c = kids[want[k]]
                    if pcall(function() box:AddChild(c) end) then st.moved = st.moved + 1 end
                end
            end
        end
    end
    return st
end

return SC
