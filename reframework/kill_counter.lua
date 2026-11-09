--
-- kill_counter.lua v1.0.0 — total monster kills per player (lobby / party)
--
-- The Hunter Profile shows kills per monster but no SUM. This mod shows it:
--   Hunted total   = sum of HuntingNum over the BossReport entries
--   Captured total = sum of CaptureNum (a second line)
-- plus a per-monster list (name, hunted, captured), sorted by kills.
--
-- Proven by reframework/kill_probe.lua v1-v12 on this build:
--   app.cHunterProfile -> ProfileEnemyReport -> BossReport[i]
--     (app.cHunterProfile_BossReport: FixedId / HuntingNum / CaptureNum)
--   Fixed -> display name via
--     _EnemyCountData:getDataByFixedId(Fixed) -> get_EnemyId()
--     -> app.EnemyDef.EnemyName(ID) -> via.gui.message.get(guid)
-- Anchors: HuntingNum is exactly the number the profile UI shows per monster
--   (Arkveld 628); all names were verified against that UI. Note that
--   EnemyName(Fixed) is NOT valid - the Fixed ids are table keys, not ids.
--   (BossReport[0] is Rathian; its Fixed value 26 is Ajarakan's *id*.)
--
-- How it works (important):
--   A cHunterProfile object only lives while its profile screen is open -
--   captured pointers go dead as soon as the screen closes (probe v4: 2 of
--   4 captures dead). So a read-only hook on app.cHunterProfile.ctor marks
--   each new profile, and the next frames copy the totals into plain Lua
--   numbers. After that the row is permanent, even though the game object
--   is gone. Remote players therefore need "open their profile once".
--   Hunter objects carry no record data (probe v1), so there is no other
--   source for other players.
--
-- Load: reframework\autorun\ (appears in "Script Generated UI"); reload with
--   REFramework menu -> Script -> Reset scripts (or restart the game).
-- Footprint: one ctor hook (capture only) + one on_frame (only while a
--   profile is being copied) + UI callbacks. Read-only: this script NEVER
--   writes a field, never touches other players' state, no config file.
--
-- Lineage: overall shape (autorun layout, imgui, safe() wrappers, logging,
--   sdk.to_managed_object(args[2]) capture) follows this repo's meal_probe
--   and Hunt Dumper by thieleju (MIT). No code from GPL/unlicensed sources.
--
-- Every SDK call is pcall-guarded: this script never throws into the game.
--

local re = re
local sdk = sdk
local log = log
local imgui = imgui

local VERSION = "1.0.0"

-- Re-running the script must not register a second set of callbacks/hooks.
local ALREADY_LOADED = _G.KILL_COUNTER_LOADED == true
_G.KILL_COUNTER_LOADED = true

-- Frames allowed for a fresh profile to finish populating before its values
-- are accepted as-is (~1.5 s at 60 fps; usually 1-3 frames is enough).
local SETTLE_FRAMES = 90
local MAX_PENDING = 6

local lastStatus = "open a Hunter Profile (yours or anyone's)"
local hook_ok = false

local pending = {}   -- { { ptr, wall, frames } } profiles being copied
local snaps = {}     -- plain-number snapshots: permanent, game object free
local show_window = false
local show_diag = false

-- ---------------------------------------------------------------------------
-- small helpers (same shapes the kill_probe series proves on this build)
-- ---------------------------------------------------------------------------

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function call_method(obj, name)
    if obj == nil then return nil end
    local v = safe(function() return obj:call(name) end)
    if v ~= nil then return v end
    local td = safe(function() return obj:get_type_definition() end)
    local m = td and safe(function() return td:get_method(name) end)
    if not m then return nil end
    return safe(function() return m:call(obj) end)
end

local function field_value(obj, fieldName)
    if obj == nil then return nil end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return nil end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if safe(function() return f:get_name() end) == fieldName then
            local is_static = safe(function() return f:is_static() end)
            return safe(function() return f:get_data(is_static and nil or obj) end)
        end
    end
    return nil
end

local function array_get(arr, i)
    local v = safe(function() return arr[i] end)
    if v == nil then
        local td = safe(function() return arr:get_type_definition() end)
        local m = td and safe(function() return td:get_method("get_Item(System.Int32)") end)
        if m then v = safe(function() return m:call(arr, i) end) end
    end
    return v
end

local function managed_array_len(arr)
    local n = safe(function() return arr:get_Count() end)
    if type(n) == "number" then return n end
    local td = safe(function() return arr:get_type_definition() end)
    local m = td and (safe(function() return td:get_method("get_Count") end)
        or safe(function() return td:get_method("get_Length") end))
    if m then
        local v = safe(function() return m:call(arr) end)
        if type(v) == "number" then return v end
    end
    return nil
end

local function is_live(obj)
    if obj == nil or obj == 0 then return false end
    if sdk.is_managed_object ~= nil then
        return safe(sdk.is_managed_object, obj) == true
    end
    return true
end

local function fmt_int(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local sign = ""
    if s:sub(1, 1) == "-" then sign, s = "-", s:sub(2) end
    local out = ""
    local count = 0
    for i = #s, 1, -1 do
        out = s:sub(i, i) .. out
        count = count + 1
        if count % 3 == 0 and i > 1 then out = "," .. out end
    end
    return sign .. out
end

local function clock()
    return os.date("%H:%M")
end

-- ---------------------------------------------------------------------------
-- monster names: Fixed -> getDataByFixedId -> get_EnemyId -> EnemyName
-- -> message text. Resolvers and names are cached (names never change).
-- ---------------------------------------------------------------------------

local resolvers = nil
local name_cache = {}

local function ensure_resolvers()
    if resolvers then return resolvers end
    local out = {}
    local vm = safe(sdk.get_managed_singleton, "app.VariousDataManager")
    local setting = vm and field_value(vm, "_Setting")
    local cd = setting and field_value(setting, "_EnemyCountData")
    out.cd = is_live(cd) and cd or nil
    local ctd = cd and safe(function() return cd:get_type_definition() end)
    out.byfixed = ctd and safe(function() return ctd:get_method("getDataByFixedId") end)
    local enemy_td = safe(sdk.find_type_definition, "app.EnemyDef")
    local msg_td = safe(sdk.find_type_definition, "via.gui.message")
    out.name = enemy_td and safe(function()
        return enemy_td:get_method("EnemyName(app.EnemyDef.ID)")
    end)
    out.msg = msg_td and safe(function()
        return msg_td:get_method("get(System.Guid)")
    end)
    -- Cache only once the whole chain resolved; a partially-ready game
    -- would otherwise pin every name to "unresolved" forever.
    if out.cd and out.byfixed and out.name and out.msg then
        resolvers = out
    end
    return out
end

local function monster_name(fixed)
    if type(fixed) ~= "number" then return nil end
    local cached = name_cache[fixed]
    if cached then return cached end
    local r = ensure_resolvers()
    if not (r.cd and r.byfixed and r.name and r.msg) then return nil end
    local data = safe(function() return r.byfixed:call(r.cd, fixed) end)
    if not is_live(data) then return nil end
    local id = call_method(data, "get_EnemyId")
    if type(id) ~= "number" then return nil end
    local guid = safe(function() return r.name:call(nil, id) end)
    if guid == nil then return nil end
    local text = safe(function() return r.msg:call(nil, guid) end)
    if type(text) ~= "string" or text == "" then return nil end
    name_cache[fixed] = text
    return text
end

-- ---------------------------------------------------------------------------
-- read a live profile into a plain-number snapshot
-- ---------------------------------------------------------------------------

local function read_profile(profile)
    local out = { hunted = 0, captured = 0, monsters = 0, list = {} }
    local report = field_value(profile, "ProfileEnemyReport")
    if not is_live(report) then out.fail = "no_enemy_report" return out end
    local arr = field_value(report, "BossReport")
    if not is_live(arr) then out.fail = "no_boss_report" return out end
    local len = managed_array_len(arr)
    if not len then out.fail = "no_boss_report_len" return out end

    for i = 0, len - 1 do
        local el = array_get(arr, i)
        if is_live(el) then
            local h = field_value(el, "HuntingNum")
            local c = field_value(el, "CaptureNum")
            if type(h) ~= "number" then h = 0 end
            if type(c) ~= "number" then c = 0 end
            out.hunted = out.hunted + h
            out.captured = out.captured + c
            if h ~= 0 or c ~= 0 then
                out.monsters = out.monsters + 1
                local fixed = field_value(el, "FixedId")
                out.list[#out.list + 1] = {
                    fixed = fixed,
                    name = monster_name(fixed),
                    hunt = h,
                    cap = c,
                }
            end
        end
    end

    table.sort(out.list, function(a, b)
        if a.hunt ~= b.hunt then return a.hunt > b.hunt end
        return a.cap > b.cap
    end)

    out.hr = field_value(profile, "HunterRank")
    out.otomo = field_value(profile, "OtomoName")
    out.ok = true
    return out
end

-- ---------------------------------------------------------------------------
-- snapshot store
-- ---------------------------------------------------------------------------

local function store_snapshot(t, wall)
    local key = tostring(t.hr) .. "|" .. tostring(t.otomo)
    local snap = {
        key = key,
        hr = t.hr,
        otomo = t.otomo,
        hunted = t.hunted,
        captured = t.captured,
        monsters = t.monsters,
        list = t.list,
        wall = wall,
    }
    for i, old in ipairs(snaps) do
        if old.key == key then
            snaps[i] = snap
            return snap
        end
    end
    snaps[#snaps + 1] = snap
    return snap
end

local function sort_snaps()
    table.sort(snaps, function(a, b)
        if a.hunted ~= b.hunted then return a.hunted > b.hunted end
        return a.captured > b.captured
    end)
end

-- Copy any pending profiles whose values are ready. Runs every frame, but
-- does nothing at all unless a profile was just constructed.
-- Outcome per entry: "stored" (done), "drop" (never usable), "retry".
local function pump_pending()
    if #pending == 0 then return end
    local still = {}
    for _, p in ipairs(pending) do
        local action = "retry"
        local ok, err = pcall(function()
            -- Profile screens are torn down when closed; the pointer dies
            -- with them, so nothing is left to read.
            if not is_live(p.ptr) then action = "drop" return end
            p.frames = (p.frames or 0) + 1
            local t = read_profile(p.ptr)
            if t.ok and t.hr == nil and t.otomo == nil then
                -- the auxiliary profile object built alongside the real one
                action = "drop"
                return
            end
            -- Wait for the game to fill the record; an honestly empty
            -- profile is accepted once the settle budget runs out.
            if t.ok and ((t.hunted + t.captured) > 0 or p.frames >= SETTLE_FRAMES) then
                local snap = store_snapshot(t, p.wall)
                lastStatus = string.format("read HR %s: %s hunted",
                    tostring(snap.hr), fmt_int(snap.hunted))
                log.info("[KillCounter] " .. lastStatus)
                action = "stored"
                return
            end
            if p.frames >= SETTLE_FRAMES then action = "drop" end
        end)
        if not ok then
            action = "retry"
            log.warn("[KillCounter] pump: " .. tostring(err))
        end
        if action == "retry" then
            still[#still + 1] = p
        end
    end
    pending = still
    sort_snaps()
end

-- ---------------------------------------------------------------------------
-- hook: mark every profile the game builds (own or someone else's)
-- ---------------------------------------------------------------------------

local function register_hooks()
    local ok = false
    safe(function()
        local t = sdk.find_type_definition("app.cHunterProfile")
        if not t then return end
        for _, m in ipairs(safe(function() return t:get_methods() end) or {}) do
            if safe(function() return m:get_name() end) == ".ctor" then
                safe(function()
                    sdk.hook(m, function(args)
                        safe(function()
                            local obj = sdk.to_managed_object(args[2])
                            if not is_live(obj) then return end
                            pending[#pending + 1] = {
                                ptr = obj,
                                wall = clock(),
                                frames = 0,
                            }
                            while #pending > MAX_PENDING do
                                table.remove(pending, 1)
                            end
                            ok = true
                        end)
                    end, nil)
                end)
            end
        end
    end)
    hook_ok = ok
    if hook_ok then
        log.info("[KillCounter] hook: app.cHunterProfile ctor")
    else
        log.warn("[KillCounter] hook FAILED (app.cHunterProfile ctor missing)")
        lastStatus = "hook failed - profile capture unavailable"
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function draw_row_body(r)
    imgui.text(string.format("Hunted: %s  (%d monsters)",
        fmt_int(r.hunted), r.monsters))
    imgui.text(string.format("Captured: %s", fmt_int(r.captured)))
    imgui.separator()
    if #r.list == 0 then
        imgui.text("No monster records.")
    else
        for _, m in ipairs(r.list) do
            imgui.text(string.format("%s: %d / %d",
                m.name or ("Monster #" .. tostring(m.fixed)),
                m.hunt, m.cap))
        end
        imgui.text("(hunted / captured)")
    end
end

local function draw_panel()
    if not imgui.tree_node("Kill Counter v" .. VERSION) then return end

    if imgui.button("Clear all") then
        snaps = {}
        pending = {}
        lastStatus = "(cleared) open a Hunter Profile to collect again"
    end
    imgui.same_line()
    local changed, value = imgui.checkbox("Always-on window", show_window)
    if changed then show_window = value end
    imgui.same_line()
    local c2, v2 = imgui.checkbox("Diagnostics", show_diag)
    if c2 then show_diag = v2 end

    if show_diag then
        imgui.text(string.format("hook: %s   pending: %d   rows: %d",
            hook_ok and "ready" or "FAILED", #pending, #snaps))
        if #pending > 0 then
            for _, p in ipairs(pending) do
                imgui.text(string.format("  pending %s: %s (%d frames)",
                    tostring(p.wall), is_live(p.ptr) and "live" or "dead",
                    p.frames or 0))
            end
        end
    end

    imgui.separator()
    if #snaps == 0 then
        imgui.text("Nothing collected yet.")
        imgui.text("Open YOUR Hunter Profile - or anyone's in the")
        imgui.text("lobby / link party - and the totals appear here.")
        imgui.text("You can close the profile straight after.")
    else
        for _, r in ipairs(snaps) do
            local label = string.format("HR %s (Palico: %s) - %s hunted##%s",
                tostring(r.hr), tostring(r.otomo), fmt_int(r.hunted), r.key)
            if imgui.tree_node(label) then
                draw_row_body(r)
                imgui.tree_pop()
            end
        end
    end

    imgui.separator()
    imgui.text("status: " .. tostring(lastStatus))
    imgui.tree_pop()
end

-- Separate always-on window (same pattern Better Hunter Highlights uses for
-- its awards table): compact totals over the game, no menu diving.
local function draw_float_window()
    if not show_window then return end
    local flag = { true }
    local open = imgui.begin_window("Kill Counter##killcounter_float", flag, 64)
    if open then
        if #snaps == 0 then
            imgui.text("Open a Hunter Profile to fill this in.")
        else
            for _, r in ipairs(snaps) do
                imgui.text(string.format("HR %s  %s hunted",
                    tostring(r.hr), fmt_int(r.hunted)))
                imgui.text(string.format("  Palico %s - %s captured",
                    tostring(r.otomo), fmt_int(r.captured)))
            end
        end
    end
    imgui.end_window()
    if flag[1] == false then show_window = false end
end

-- ---------------------------------------------------------------------------

if not ALREADY_LOADED then
    re.on_frame(function()
        local ok, err = pcall(pump_pending)
        if not ok then log.warn("[KillCounter] pump_pending: " .. tostring(err)) end
    end)
    re.on_draw_ui(function()
        local ok, err = pcall(function()
            draw_panel()
            draw_float_window()
        end)
        if not ok then log.warn("[KillCounter] draw_ui: " .. tostring(err)) end
    end)
    register_hooks()
    log.info("[KillCounter] loaded v" .. VERSION)
else
    log.info("[KillCounter] duplicate load ignored (callbacks already registered)")
end
