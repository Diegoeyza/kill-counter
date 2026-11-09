--
-- kill_probe.lua v4 — dev probe for a "sum monster kills per player" mod
--
-- v3 findings (2026-11-09):
--   * BossReport element = app.cHunterProfile_BossReport:
--     FixedId / EnemyState / HuntingNum / CaptureNum / MinSize / MaxSize.
--   * Two live profiles: HR907/Michurris (local), HR999/Latka (remote).
--   * cPlayerNetMemberInfo has NO name (Guid + indices only) — names dropped;
--     v1 labels = HR + OtomoName (+ "you" for local).
--   * LOCAL path: SaveDataManager._UserSaveData (cUserSaveData)._Data[3]
--     = app.savedata.cUserSaveParam[] which has _EnemyReport
--     (cEnemyReportParam) + _HunterProfile (cHunterProfileParam) +
--     HunterId/HunterShortId/PlayTime.
--
-- v4 goals (read-only): full sums over all 100 BossReport entries per
--   captured profile (hunt total, capture total, nonzero count, top-5 with
--   FixedIds for UI cross-check), plus the same sums via the LOCAL save
--   path to prove save == profile data (local total with no UI open).
--

local re = re
local sdk = sdk
local json = json
local log = log
local imgui = imgui

local PROBE_VERSION = 4
local OUT_TYPES = "kill_probe4_types.json"
local OUT_SAVE = "kill_probe4_save.json"
local OUT_LOBBY = "kill_probe4_lobby.json"
local OUT_PROFILE = "kill_probe4_profile.json"
local OUT_NAMES = "kill_probe5_names.json"
local OUT_FIXED = "kill_probe6_fixed.json"
local OUT_NAMES7 = "kill_probe7_names.json"
local OUT_ENEMYDATA = "kill_probe8_enemydata.json"
local OUT_TABLES = "kill_probe9_tables.json"
local OUT_BOSS = "kill_probe10_bossdata.json"
local OUT_MAP = "kill_probe11_map.json"
local OUT_IDS = "kill_probe12_enemyids.json"

local ALREADY_LOADED = _G.KILL_PROBE_LOADED == true
_G.KILL_PROBE_LOADED = true

local lastStatus = "(idle)"
local hook_armed = true
local captured = {}   -- { { ptr=..., wall=... } }, newest last, max 8

-- ---------------------------------------------------------------------------
-- small helpers (same shapes meal_probe proves on this build)
-- ---------------------------------------------------------------------------

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function safe_str(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    return tostring(v)
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

-- Static field read (Field:get_data(nil)). Declared up here so every
-- snapshot/scan function below binds the local, not a nil global.
local function static_field(typeName, fieldName)
    local td = safe(sdk.find_type_definition, typeName)
    if not td then return nil end
    local f = safe(function() return td:get_field(fieldName) end)
    if not f then return nil end
    return safe(function() return f:get_data(nil) end)
end

-- Boxed-primitive unbox: primitive arrays read back as userdata in this
-- binding; Type:ToString() yields the number text. Same placement rule.
local function unbox_int(v)
    if type(v) == "number" then return v end
    if not is_live(v) then return nil end
    local s = call_method(v, "ToString")
    if type(s) == "string" then return tonumber(s) end
    return nil
end

-- Enemy ID -> localized display name (EnemyName guid + message table).
-- Top-level so every scan below binds it.
local function top_resolve(id)
    local enemy_td = safe(sdk.find_type_definition, "app.EnemyDef")
    local msg_td = safe(sdk.find_type_definition, "via.gui.message")
    local m_name = enemy_td and safe(function()
        return enemy_td:get_method("EnemyName(app.EnemyDef.ID)")
    end)
    local m_msg = msg_td and safe(function()
        return msg_td:get_method("get(System.Guid)")
    end)
    if m_name == nil or m_msg == nil or type(id) ~= "number" then
        return nil
    end
    local guid = safe(function() return m_name:call(nil, id) end)
    if guid == nil then return nil end
    return safe(function() return m_msg:call(nil, guid) end)
end

-- Unbox a whole primitive array (cap entries). Returns list + full length.
local function unbox_all(arr, cap)
    local out = {}
    local len = arr and managed_array_len(arr)
    if not len then return out end
    local upto = len > cap and cap or len
    for i = 0, upto - 1 do
        out[#out + 1] = unbox_int(array_get(arr, i))
    end
    return out, len
end

-- ---------------------------------------------------------------------------
-- type dumps
-- ---------------------------------------------------------------------------

local PRIMITIVE = {
    Boolean = true, Single = true, Double = true, Int32 = true, UInt32 = true,
    Int16 = true, UInt16 = true, Byte = true, SByte = true, Int64 = true,
    UInt64 = true, String = true,
}

local function describe_field(f)
    return {
        name = safe(function() return f:get_name() end),
        type = safe(function() return f:get_type():get_name() end),
        static = safe(function() return f:is_static() end),
    }
end

local function describe_method(m)
    local params = {}
    local n = safe(function() return m:get_num_params() end) or 0
    local pts = safe(function() return m:get_param_types() end) or {}
    for i = 1, n do
        local t = pts[i]
        params[#params + 1] = safe_str(safe(function() return t:get_name() end)) or "?"
    end
    return {
        name = safe(function() return m:get_name() end),
        ret = safe(function() return m:get_return_type():get_name() end),
        nparams = n,
        params = params,
    }
end

local function dump_type(typeName)
    local td = safe(sdk.find_type_definition, typeName)
    local entry = { name = typeName, exists = td ~= nil }
    if not td then return entry end
    entry.full_name = safe(function() return td:get_full_name() end)
    local fields = safe(function() return td:get_fields() end)
    if fields then
        entry.fields = {}
        for _, f in ipairs(fields) do
            entry.fields[#entry.fields + 1] = describe_field(f)
        end
    end
    local methods = safe(function() return td:get_methods() end)
    if methods then
        entry.methods = {}
        for _, m in ipairs(methods) do
            entry.methods[#entry.methods + 1] = describe_method(m)
        end
    end
    return entry
end

local RECORD_TYPES_V2 = {
    "app.PlayerManager", "app.cPlayerManageInfo",
    "app.HunterCharacter", "app.cHunterStatus",
    "app.cHunterInfoHolder",
    "app.SaveDataManager",
    "app.cHunterProfile",
    "app.EnemyDef",
    -- save-param naming variants (profile ctor takes cUserSaveParam;
    -- SaveDataManager._UserSaveData is cUserSaveData)
    "app.cUserSaveParam", "app.CUserSaveParam", "app.UserSaveParam",
    "app.cUserSaveData", "app.CUserSaveData", "app.UserSaveData",
    "app.savedata.cUserSaveParam", "app.savedata.cUserSaveData",
    "app.cSaveParam", "app.SaveParam",
    -- holder / context / net member (name hunt)
    "app.HunterCharacter.cHunterInfoHolder",
    "app.cPlayerContextHolder", "app.PlayerContextHolder",
    "app.cPlayerNetMemberInfo", "app.PlayerNetMemberInfo",
    -- boss report element guesses (verified against live instance in
    -- Snapshot captured v3; misses recorded as exists=false)
    "app.savedata.cBossReport", "app.cBossReport",
    "app.savedata.cEnemyReport", "app.cEnemyReport",
    "app.savedata.cEnemyReportWork", "app.cEnemyReportWork",
    -- gui manager candidates (profile screen has to live somewhere)
    "app.GuiManager", "app.cGuiManager", "app.UIManager", "app.cUIManager",
    "app.GuiMain", "app.cGuiMain",
}

-- Nested profile blocks: field types showed as short names like
-- cHunterProfile_Top, so try app-prefixed, dot-nested, and bare forms.
local NESTED_VARIANTS = {}
do
    local blocks = { "Top", "Equip", "QuestClear", "Medal", "EnemyReport", "Animal", "Arena" }
    for _, b in ipairs(blocks) do
        NESTED_VARIANTS[#NESTED_VARIANTS + 1] = "app.cHunterProfile_" .. b
        NESTED_VARIANTS[#NESTED_VARIANTS + 1] = "app.cHunterProfile." .. b
        NESTED_VARIANTS[#NESTED_VARIANTS + 1] = "app.HunterProfile_" .. b
        NESTED_VARIANTS[#NESTED_VARIANTS + 1] = "cHunterProfile_" .. b
    end
end

local function dump_types()
    local out = { probe_version = PROBE_VERSION, kinds = {}, nested = {} }
    for _, name in ipairs(RECORD_TYPES_V2) do
        out.kinds[#out.kinds + 1] = dump_type(name)
    end
    for _, name in ipairs(NESTED_VARIANTS) do
        local e = dump_type(name)
        if e.exists then out.nested[#out.nested + 1] = e end
    end
    out.nested_tried = #NESTED_VARIANTS
    json.dump_file(OUT_TYPES, out)
    local n = 0
    for _, e in ipairs(out.kinds) do
        if e.exists then n = n + 1 end
    end
    lastStatus = string.format("types: %d/%d exist, %d nested hit -> %s",
        n, #RECORD_TYPES_V2, #out.nested, OUT_TYPES)
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- player enumeration (ALL humans, not just local)
-- ---------------------------------------------------------------------------

local function instanced_array(pm)
    local list = field_value(pm, "_InstancedPlayerList")
        or field_value(pm, "<InstancedPlayerList>k__BackingField")
        or field_value(pm, "_PlayerList")
    if not list then return nil end
    return field_value(list, "_Array")
        or field_value(list, "<Array>k__BackingField")
        or field_value(list, "_Items")
        or list
end

local function character_of(inst, pi)
    for _, name in ipairs({ "get_Character", "get_Hunter", "get_Player" }) do
        local v = pi and call_method(pi, name)
        if v ~= nil and v ~= 0 then return v end
    end
    for _, name in ipairs({ "get_Hunter", "get_Character" }) do
        local v = call_method(inst, name)
        if v ~= nil and v ~= 0 then return v end
    end
    return field_value(inst, "<Character>k__BackingField")
        or field_value(inst, "_Character")
end

local function object_primitive_map(obj, max_fields)
    local map = {}
    if obj == nil then return map end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return map end
    local n = 0
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        if max_fields and n >= max_fields then break end
        local fname = safe(function() return f:get_name() end)
        local ftype = safe_str(safe(function() return f:get_type():get_name() end))
        if fname and PRIMITIVE[ftype] then
            map[fname] = safe_str(safe(function()
                local is_static = safe(function() return f:is_static() end)
                return f:get_data(is_static and nil or obj)
            end))
            n = n + 1
        end
    end
    return map
end

-- All method names of an object (names only, nothing called): for the
-- name hunt on holder/context objects where keyword filtering may miss.
local function all_method_names(obj, max_n)
    local names = {}
    if not is_live(obj) then return names end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then return names end
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        names[#names + 1] = safe(function() return m:get_name() end)
        if max_n and #names >= max_n then break end
    end
    return names
end

-- Name hunt v2: HunterInfoHolder + wider method/field sweep.
local function try_name(pi, ch, st)
    local holder = ch and call_method(ch, "get_HunterInfoHolder")
    local objs = { holder, pi, ch, st }
    for _, obj in ipairs(objs) do
        if obj ~= nil and obj ~= 0 then
            for _, m in ipairs({ "get_Name", "getPlayerName", "get_PlayerName",
                                 "getHunterName", "get_HunterName" }) do
                local v = call_method(obj, m)
                if type(v) == "string" and v ~= "" then return v, "method:" .. m end
            end
            for _, f in ipairs({ "_Name", "_PlayerName", "_HunterName",
                                 "<Name>k__BackingField" }) do
                local v = field_value(obj, f)
                if type(v) == "string" and v ~= "" then return v, "field:" .. f end
            end
        end
    end
    return nil, nil
end

local KEYWORDS = {
    "kill", "slay", "hunt", "capture", "record", "profile",
    "guild", "card", "monster", "enemy", "clear", "troph",
    "medal", "achieve", "slain", "defeat", "report",
}

local function name_hits(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    for _, k in ipairs(KEYWORDS) do
        if lower:find(k, 1, true) then return true end
    end
    return false
end

local function scan_object(obj, label)
    local out = { label = label }
    if not is_live(obj) then
        out.fail = "nil"
        return out
    end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then
        out.fail = "no_typedef"
        return out
    end
    out.type = safe_str(safe(function() return td:get_full_name() end))
    out.primitive = object_primitive_map(obj, 60)
    out.record_fields = {}
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        if fname and name_hits(fname) then
            local ftype = safe_str(safe(function() return f:get_type():get_name() end))
            local entry = { name = fname, type = ftype }
            if PRIMITIVE[ftype] then
                entry.value = safe_str(safe(function()
                    local is_static = safe(function() return f:is_static() end)
                    return f:get_data(is_static and nil or obj)
                end))
            else
                local nested = safe(function()
                    local is_static = safe(function() return f:is_static() end)
                    return f:get_data(is_static and nil or obj)
                end)
                if is_live(nested) then
                    local ntd = safe(function() return nested:get_type_definition() end)
                    entry.nested_type = safe_str(safe(function()
                        return ntd and ntd:get_full_name()
                    end))
                    entry.nested_primitive = object_primitive_map(nested, 40)
                    local len = managed_array_len(nested)
                    if len ~= nil then
                        entry.array_len = len
                        entry.items = {}
                        local upto = len > 12 and 12 or len
                        for i = 0, upto - 1 do
                            entry.items[#entry.items + 1] = safe_str(array_get(nested, i))
                        end
                    end
                else
                    entry.nested = "nil_or_zero"
                end
            end
            out.record_fields[#out.record_fields + 1] = entry
        end
    end
    out.record_methods = {}
    for _, m in ipairs(safe(function() return td:get_methods() end) or {}) do
        local mname = safe(function() return m:get_name() end) or ""
        if name_hits(mname) then
            local nparams = safe(function() return m:get_num_params() end) or 0
            local ret = safe_str(safe(function() return m:get_return_type():get_name() end))
            local entry = { name = mname, params = nparams, ret = ret }
            if nparams == 0 and ret and PRIMITIVE[ret] then
                entry.value = safe_str(safe(function() return m:call(obj) end))
            end
            out.record_methods[#out.record_methods + 1] = entry
            if #out.record_methods >= 60 then break end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- deep dump of a captured profile: every sub-block, int arrays with sums
-- ---------------------------------------------------------------------------

local function dump_int_array(arr, max_items)
    local len = managed_array_len(arr)
    if len == nil then return nil end
    local items, sum, numeric = {}, 0, 0
    local upto = len > max_items and max_items or len
    for i = 0, upto - 1 do
        local v = array_get(arr, i)
        items[#items + 1] = safe_str(v)
        if type(v) == "number" then
            sum = sum + v
            numeric = numeric + 1
        end
    end
    return { len = len, shown = upto, numeric = numeric, sum_shown = sum, items = items }
end

-- Sum a managed int array WITHOUT keeping items (full length).
local function sum_int_array(arr)
    local len = managed_array_len(arr)
    if len == nil or len <= 0 then return nil end
    local sum, numeric = 0, 0
    for i = 0, len - 1 do
        local v = array_get(arr, i)
        if type(v) == "number" then
            sum = sum + v
            numeric = numeric + 1
        end
    end
    return { len = len, numeric = numeric, sum = sum }
end

local function deep_dump(obj, label, depth)
    local out = { label = label }
    if not is_live(obj) then
        out.fail = "nil"
        return out
    end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then
        out.fail = "no_typedef"
        return out
    end
    out.type = safe_str(safe(function() return td:get_full_name() end))
    out.primitive = object_primitive_map(obj, 80)
    if depth <= 0 then return out end
    out.children = {}
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        local ftype = safe_str(safe(function() return f:get_type():get_name() end))
        if fname and not PRIMITIVE[ftype] then
            local nested = safe(function()
                local is_static = safe(function() return f:is_static() end)
                return f:get_data(is_static and nil or obj)
            end)
            if is_live(nested) then
                local arr = dump_int_array(nested, 40)
                if arr then
                    out.children[fname] = {
                        kind = "array",
                        type = safe_str(safe(function()
                            local ntd = nested:get_type_definition()
                            return ntd and ntd:get_full_name()
                        end)),
                        full_sum = sum_int_array(nested),
                        head = arr,
                    }
                else
                    out.children[fname] = {
                        kind = "object",
                        deep = deep_dump(nested, fname, depth - 1),
                    }
                end
            end
            if #out.children >= 40 then break end
        end
    end
    return out
end

-- Generic hunt-array summer: any managed array whose elements carry
-- HuntingNum/CaptureNum/FixedId primitives (BossReport, save-path report
-- arrays, ...). Full-length sums + nonzero count + top-5 for UI cross-check.
local function sum_hunt_array(arr)
    local out = {}
    local len = managed_array_len(arr)
    out.len = len
    if not len or len <= 0 then return out end
    local hunt, cap, nonzero = 0, 0, 0
    local top = {}
    for i = 0, len - 1 do
        local el = array_get(arr, i)
        if is_live(el) then
            local h = field_value(el, "HuntingNum")
            local c = field_value(el, "CaptureNum")
            local f = field_value(el, "FixedId")
            if type(h) ~= "number" then h = 0 end
            if type(c) ~= "number" then c = 0 end
            hunt = hunt + h
            cap = cap + c
            if h ~= 0 or c ~= 0 then
                nonzero = nonzero + 1
                top[#top + 1] = { index = i, fixed = f, hunt = h, cap = c }
            end
        end
    end
    out.hunt_sum = hunt
    out.capture_sum = cap
    out.nonzero = nonzero
    table.sort(top, function(a, b) return (a.hunt + a.cap) > (b.hunt + b.cap) end)
    out.top = {}
    for i = 1, 5 do
        if top[i] then out.top[#out.top + 1] = top[i] end
    end
    return out
end

-- Walk an object one level: every array field whose first live element has
-- a HuntingNum primitive gets summed. Finds save-path report arrays.
local function scan_hunt_arrays(obj, label)
    local out = { label = label, hits = {} }
    if not is_live(obj) then
        out.fail = "nil"
        return out
    end
    local td = safe(function() return obj:get_type_definition() end)
    if not td then
        out.fail = "no_typedef"
        return out
    end
    for _, f in ipairs(safe(function() return td:get_fields() end) or {}) do
        local fname = safe(function() return f:get_name() end)
        local ftype = safe_str(safe(function() return f:get_type():get_name() end))
        if fname and not PRIMITIVE[ftype] then
            local nested = safe(function()
                local is_static = safe(function() return f:is_static() end)
                return f:get_data(is_static and nil or obj)
            end)
            if is_live(nested) and managed_array_len(nested) then
                local first = nil
                local len = managed_array_len(nested)
                for i = 0, math.min(len - 1, 8) do
                    local el = array_get(nested, i)
                    if is_live(el) then
                        first = el
                        break
                    end
                end
                if first and type(field_value(first, "HuntingNum")) == "number" then
                    out.hits[#out.hits + 1] = {
                        field = fname,
                        type = safe_str(safe(function()
                            local ntd = nested:get_type_definition()
                            return ntd and ntd:get_full_name()
                        end)),
                        totals = sum_hunt_array(nested),
                    }
                end
            end
            if #out.hits >= 10 then break end
        end
    end
    return out
end

-- BossReport element introspection: element typedef (FULL field list),
-- first elements' primitive values, and a nonzero-element census, so the
-- enemy-ID field and the hunt/kill/capture count fields show up by shape.
local function boss_detail(profile)
    local out = {}
    local report = field_value(profile, "ProfileEnemyReport")
    if not is_live(report) then
        out.fail = "no_enemy_report"
        return out
    end
    local arr = field_value(report, "BossReport")
    if not is_live(arr) then
        out.fail = "no_boss_report"
        return out
    end
    local len = managed_array_len(arr)
    out.len = len
    out.array_type = safe_str(safe(function()
        local t = arr:get_type_definition()
        return t and t:get_full_name()
    end))
    if not len or len <= 0 then return out end
    -- element typedef from first live element
    local first = nil
    for i = 0, len - 1 do
        local el = array_get(arr, i)
        if is_live(el) then
            first = el
            out.first_live_index = i
            break
        end
    end
    if not first then
        out.fail = "no_live_elements"
        return out
    end
    local etd = safe(function() return first:get_type_definition() end)
    out.element_type = safe_str(safe(function() return etd and etd:get_full_name() end))
    out.element_fields = {}
    if etd then
        for _, f in ipairs(safe(function() return etd:get_fields() end) or {}) do
            out.element_fields[#out.element_fields + 1] = describe_field(f)
        end
    end
    -- first 8 elements' full primitive maps
    out.head = {}
    local upto = len > 8 and 8 or len
    for i = 0, upto - 1 do
        local el = array_get(arr, i)
        if is_live(el) then
            out.head[#out.head + 1] = {
                index = i,
                primitive = object_primitive_map(el, 80),
            }
        else
            out.head[#out.head + 1] = { index = i, dead = true }
        end
    end
    -- census: which int fields are nonzero anywhere (kill counts are sparse)
    out.nonzero = {}
    local seen = {}
    for i = 0, len - 1 do
        local el = array_get(arr, i)
        if is_live(el) then
            local map = object_primitive_map(el, 80)
            for k, v in pairs(map) do
                if type(v) == "number" and v ~= 0 and not seen[k] then
                    seen[k] = true
                    out.nonzero[#out.nonzero + 1] = { field = k, first_at = i, value = v }
                    if #out.nonzero >= 40 then break end
                end
            end
            if #out.nonzero >= 40 then break end
        end
    end
    -- full totals + top-5 (the numbers the mod will show)
    out.totals = sum_hunt_array(arr)
    return out
end

-- Enemy-ID scan (v12): _EnemyCountData:getDataByFixedId(BossReport Fixed)
-- -> cData -> get_EnemyId() -> roster name. The runtime chain for the
-- mod's monster list (3 calls per monster, cached; read-only).
local function scan_ids()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        profiles = {},
    }
    local vm = safe(sdk.get_managed_singleton, "app.VariousDataManager")
    local setting = vm and field_value(vm, "_Setting")
    local cd = setting and field_value(setting, "_EnemyCountData")
    out.countdata_live = is_live(cd)
    local ctd = cd and safe(function() return cd:get_type_definition() end)
    local m_byfixed = ctd and safe(function()
        return ctd:get_method("getDataByFixedId")
    end)
    out.byfixed_method = m_byfixed ~= nil
    if not (is_live(cd) and m_byfixed) then
        json.dump_file(OUT_IDS, out)
        lastStatus = "ids: no countdata path -> " .. OUT_IDS
        return out
    end
    for _, c in ipairs(captured) do
        if is_live(c.ptr) then
            local pe = { hr = field_value(c.ptr, "HunterRank"), entries = {} }
            local report = field_value(c.ptr, "ProfileEnemyReport")
            local arr = report and field_value(report, "BossReport")
            local len = arr and managed_array_len(arr)
            if len then
                for i = 0, len - 1 do
                    local el = array_get(arr, i)
                    if is_live(el) then
                        local h = field_value(el, "HuntingNum")
                        if type(h) == "number" and h ~= 0 then
                            local fixed = field_value(el, "FixedId")
                            local e = { index = i, fixed = fixed, hunt = h,
                                cap = field_value(el, "CaptureNum") }
                            if type(fixed) == "number" then
                                local r = safe(function()
                                    return m_byfixed:call(cd, fixed)
                                end)
                                if is_live(r) then
                                    e.enemyid = call_method(r, "get_EnemyId")
                                    e.name = top_resolve(e.enemyid)
                                else
                                    e.nodata = true
                                end
                            end
                            pe.entries[#pe.entries + 1] = e
                            if #pe.entries >= 40 then break end
                        end
                    end
                end
            end
            out.profiles[#out.profiles + 1] = pe
        end
    end
    json.dump_file(OUT_IDS, out)
    lastStatus = "ids -> " .. OUT_IDS
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- Full-map scan (v11): ID_BITFixedArray unboxed for all 212 IDs gives
-- Fixed per ID; invert to Fixed->ID and resolve every name live. The table
-- is build-constant (both profiles share FixedIds), so the mod embeds it
-- statically. Also tries _EnemyCountData:getDataByFixedId on known Fixeds.
local function scan_map()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local fixed_arr = static_field("app.EnemyDef", "ID_BITFixedArray")
    local vals, len = unbox_all(fixed_arr, 250)
    out.fixed_len = len
    out.fixed_table = {}
    for id = 0, (len or 0) - 1 do
        local fixed = vals[id + 1]
        if type(fixed) == "number" then
            local nm = top_resolve(id)
            if type(nm) == "string" and nm ~= "" then
                out.fixed_table[#out.fixed_table + 1] = {
                    id = id, fixed = fixed, name = nm,
                }
            end
        end
        if #out.fixed_table >= 220 then break end
    end
    out.fixed_named_n = #out.fixed_table
    -- the Arkveld anchor: roster ID 27 must map to Fixed 746996864
    out.anchor27 = vals and vals[28]

    -- _EnemyCountData:getDataByFixedId on known Fixeds
    out.countdata = {}
    do
        local vm = safe(sdk.get_managed_singleton, "app.VariousDataManager")
        local setting = vm and field_value(vm, "_Setting")
        local cd = setting and field_value(setting, "_EnemyCountData")
        if is_live(cd) then
            local ctd = safe(function() return cd:get_type_definition() end)
            local m_byfixed = ctd and safe(function()
                return ctd:get_method("getDataByFixedId")
            end)
            out.count_byfixed = m_byfixed ~= nil
            if m_byfixed then
                for _, fx in ipairs({ 746996864, 26, 1965232896 }) do
                    local r = safe(function() return m_byfixed:call(cd, fx) end)
                    local e = { fixed = fx, live = is_live(r) }
                    if is_live(r) then
                        e.type = safe_str(safe(function()
                            local t = r:get_type_definition()
                            return t and t:get_full_name()
                        end))
                        e.primitive = object_primitive_map(r, 40)
                        e.methods = all_method_names(r, 40)
                    end
                    out.countdata[#out.countdata + 1] = e
                end
            end
        end
    end

    json.dump_file(OUT_MAP, out)
    lastStatus = "map (" .. tostring(out.fixed_named_n) .. " named) -> " .. OUT_MAP
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- Boss-data scan (v10): drill _EnemyReportBossData for the per-boss table
-- (Fixed/ID fields?), dump _EnemyCountData/_EnemyData method names, and
-- build the Fixed->ID map from ID_BITFixedArray with the unbox trick.
local KNOWN_FIXED10 = {
    { fixed = 746996864, tag = "Arkveld?" },
    { fixed = 26, tag = "Ajarakan" },
    { fixed = 1965232896, tag = "137hunts" },
    { fixed = 1411933184, tag = "10hunts" },
    { fixed = -535078400, tag = "89hunts" },
}

local function scan_bossdata()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local vm = safe(sdk.get_managed_singleton, "app.VariousDataManager")
    local setting = vm and field_value(vm, "_Setting")
    if not is_live(setting) then
        out.fail = "no_setting"
        json.dump_file(OUT_BOSS, out)
        lastStatus = "bossdata: no _Setting -> " .. OUT_BOSS
        return out
    end

    -- 1) _EnemyReportBossData drill
    local rep = field_value(setting, "_EnemyReportSetting")
    local boss = rep and field_value(rep, "_EnemyReportBossData")
    out.boss_live = is_live(boss)
    if is_live(boss) then
        local btd = safe(function() return boss:get_type_definition() end)
        out.boss_type = safe_str(safe(function()
            return btd and btd:get_full_name()
        end))
        out.boss_fields = {}
        if btd then
            for _, f in ipairs(safe(function() return btd:get_fields() end) or {}) do
                out.boss_fields[#out.boss_fields + 1] = describe_field(f)
            end
        end
        for _, aname in ipairs({ "_Values", "_Data", "_Map", "Values", "Data" }) do
            local arr = field_value(boss, aname)
            local alen = arr and managed_array_len(arr)
            if alen and alen > 0 then
                local be = { accessor = aname, len = alen }
                local first = nil
                for i = 0, math.min(alen - 1, 3) do
                    local el = array_get(arr, i)
                    if is_live(el) then
                        first = el
                        break
                    end
                end
                if first then
                    local etd = safe(function() return first:get_type_definition() end)
                    be.element_type = safe_str(safe(function()
                        return etd and etd:get_full_name()
                    end))
                    be.element_fields = {}
                    if etd then
                        for _, ef in ipairs(safe(function() return etd:get_fields() end) or {}) do
                            be.element_fields[#be.element_fields + 1] = describe_field(ef)
                        end
                    end
                    be.sample = {}
                    for i = 0, math.min(alen - 1, 2) do
                        local el = array_get(arr, i)
                        if is_live(el) then
                            be.sample[#be.sample + 1] = {
                                index = i,
                                primitive = object_primitive_map(el, 40),
                            }
                        end
                    end
                end
                out.boss_array = be
                break
            end
        end
    end

    -- 2) method names of the opaque count/data tables
    out.countdata_methods = {}
    out.enemydata_methods = {}
    do
        local cd = field_value(setting, "_EnemyCountData")
        if is_live(cd) then
            out.countdata_methods = all_method_names(cd, 80)
        end
        local ed = field_value(setting, "_EnemyData")
        if is_live(ed) then
            out.enemydata_methods = all_method_names(ed, 80)
        end
    end

    -- 3) Fixed->ID map via ID_BIT arrays (unboxed)
    local fixed_arr = static_field("app.EnemyDef", "ID_BITFixedArray")
    local value_arr = static_field("app.EnemyDef", "ID_BITValueArray")
    local fixed_vals, fixed_len = unbox_all(fixed_arr, 300)
    local value_vals, value_len = unbox_all(value_arr, 300)
    out.fixed_len = fixed_len
    out.value_len = value_len
    out.fixed_head = {}
    for i = 1, 8 do
        out.fixed_head[#out.fixed_head + 1] = fixed_vals[i]
    end
    local f2i = {}
    for i, v in ipairs(fixed_vals) do
        if type(v) == "number" and f2i[v] == nil then
            f2i[v] = i - 1
        end
    end
    out.known = {}
    for _, k in ipairs(KNOWN_FIXED10) do
        local idx = f2i[k.fixed]
        local e = { fixed = k.fixed, tag = k.tag, map_index = idx }
        if idx ~= nil then
            e.mapped_id = value_vals[idx + 1]
            e.text = top_resolve(e.mapped_id)
        end
        out.known[#out.known + 1] = e
    end

    json.dump_file(OUT_BOSS, out)
    lastStatus = "bossdata -> " .. OUT_BOSS
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- Table deep-dump (v9): full field lists of the enemy data tables found
-- in v8 (_EnemyCountData, _EnemyData, report setting, ...). Finds the
-- entry accessor pattern (not _Values on these). unbox_int now lives with
-- the top helpers (used by v10 too).
local function scan_tables()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        tables = {},
    }
    local vm = safe(sdk.get_managed_singleton, "app.VariousDataManager")
    local setting = vm and field_value(vm, "_Setting")
    if not is_live(setting) then
        out.fail = "no_setting"
        json.dump_file(OUT_TABLES, out)
        lastStatus = "tables: no _Setting -> " .. OUT_TABLES
        return out
    end
    local targets = {
        "_EnemyCountData", "_EnemyData", "_EnemyReportSetting",
        "_EnemyQuestData", "_EnemySpeciesData",
        "EnemyReportDataIndex", "EnemyCountDataIndex", "EnemyDataIndex",
    }
    for _, fname in ipairs(targets) do
        local obj = field_value(setting, fname)
        local entry = { field = fname, live = is_live(obj) }
        if is_live(obj) then
            local otd = safe(function() return obj:get_type_definition() end)
            entry.type = safe_str(safe(function()
                return otd and otd:get_full_name()
            end))
            entry.fields = {}
            entry.primitive = object_primitive_map(obj, 40)
            local len = managed_array_len(obj)
            entry.self_len = len
            if len and len > 0 then
                -- the object IS an array (Index tables): unbox first 8
                entry.unboxed = {}
                for i = 0, math.min(len - 1, 7) do
                    entry.unboxed[#entry.unboxed + 1] = unbox_int(array_get(obj, i))
                end
            else
                for _, f in ipairs(safe(function() return otd and otd:get_fields() end) or {}) do
                    local fn2 = safe(function() return f:get_name() end)
                    local ft2 = safe_str(safe(function() return f:get_type():get_name() end))
                    if fn2 then
                        entry.fields[#entry.fields + 1] = { name = fn2, type = ft2 }
                    end
                    if #entry.fields >= 60 then break end
                end
            end
        end
        out.tables[#out.tables + 1] = entry
    end
    json.dump_file(OUT_TABLES, out)
    lastStatus = "tables -> " .. OUT_TABLES
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- Enemy-data scan (v8): VariousDataManager._Setting data tables may carry
-- per-enemy entries with BOTH the Fixed value and ID/name. Enumerate
-- _Setting fields matching enemy/browser/report/record, dump element
-- typedefs, and check numeric fields against known BossReport FixedIds.
local KNOWN_FIXED = {
    746996864, 26, 1965232896, 1411933184, -535078400, 402056736,
    1049705664, -1440201088, 2129596800, -1363370496, -758250816, 32634,
}

local function scan_enemydata()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        tables = {},
    }
    local vm = safe(sdk.get_managed_singleton, "app.VariousDataManager")
    out.manager_live = is_live(vm)
    if not is_live(vm) then
        json.dump_file(OUT_ENEMYDATA, out)
        lastStatus = "enemydata: no VariousDataManager -> " .. OUT_ENEMYDATA
        return out
    end
    local setting = field_value(vm, "_Setting")
    out.setting_type = safe_str(safe(function()
        local t = setting and setting:get_type_definition()
        return t and t:get_full_name()
    end))
    if not is_live(setting) then
        json.dump_file(OUT_ENEMYDATA, out)
        lastStatus = "enemydata: no _Setting -> " .. OUT_ENEMYDATA
        return out
    end
    local std = safe(function() return setting:get_type_definition() end)
    local all_fields = {}
    for _, f in ipairs(safe(function() return std and std:get_fields() end) or {}) do
        all_fields[#all_fields + 1] = safe(function() return f:get_name() end)
    end
    out.setting_field_count = #all_fields
    for _, fname in ipairs(all_fields) do
        if fname and name_hits(fname) then
            local obj = field_value(setting, fname)
            local entry = { field = fname, live = is_live(obj) }
            if is_live(obj) then
                entry.type = safe_str(safe(function()
                    local t = obj:get_type_definition()
                    return t and t:get_full_name()
                end))
                -- data tables expose _Values arrays
                local vals = field_value(obj, "_Values")
                local vlen = vals and managed_array_len(vals)
                entry.values_len = vlen
                if vlen and vlen > 0 then
                    local first = nil
                    for i = 0, math.min(vlen - 1, 2) do
                        local el = array_get(vals, i)
                        if is_live(el) then
                            first = el
                            break
                        end
                    end
                    if first then
                        local etd = safe(function() return first:get_type_definition() end)
                        entry.element_type = safe_str(safe(function()
                            return etd and etd:get_full_name()
                        end))
                        entry.element_fields = {}
                        if etd then
                            for _, ef in ipairs(safe(function() return etd:get_fields() end) or {}) do
                                entry.element_fields[#entry.element_fields + 1] = describe_field(ef)
                            end
                        end
                        -- check numerics of first 3 elements vs known FixedIds
                        entry.sample = {}
                        for i = 0, math.min(vlen - 1, 2) do
                            local el = array_get(vals, i)
                            if is_live(el) then
                                local map = object_primitive_map(el, 40)
                                local sm = { index = i }
                                for k, v in pairs(map) do
                                    if type(v) == "number" then
                                        for _, kf in ipairs(KNOWN_FIXED) do
                                            if v == kf then
                                                sm.fixed_match = { field = k, value = v }
                                            end
                                        end
                                    end
                                end
                                sm.primitive = map
                                entry.sample[#entry.sample + 1] = sm
                            end
                        end
                    end
                end
            end
            out.tables[#out.tables + 1] = entry
            if #out.tables >= 30 then break end
        end
    end
    json.dump_file(OUT_ENEMYDATA, out)
    lastStatus = "enemydata: " .. tostring(#out.tables) .. " table(s) -> " .. OUT_ENEMYDATA
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- Name scan v7: brute-force ID roster (MaxID=150) + FixedId low-byte /
-- low-word hypotheses + raw FixedArray read diagnosis (GetValue fallback).
local function scan_names7()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local enemy_td = safe(sdk.find_type_definition, "app.EnemyDef")
    local msg_td = safe(sdk.find_type_definition, "via.gui.message")
    local m_name = enemy_td and safe(function()
        return enemy_td:get_method("EnemyName(app.EnemyDef.ID)")
    end)
    local m_msg = msg_td and safe(function()
        return msg_td:get_method("get(System.Guid)")
    end)
    out.name_method = m_name ~= nil
    out.msg_method = m_msg ~= nil

    local function resolve_text(id)
        if m_name == nil or m_msg == nil or type(id) ~= "number" then
            return nil
        end
        local guid = safe(function() return m_name:call(nil, id) end)
        if guid == nil then return nil end
        return safe(function() return m_msg:call(nil, guid) end)
    end

    -- 1) full ID roster 0..160 (which IDs have names?)
    out.roster = {}
    for id = 0, 160 do
        local t = resolve_text(id)
        if type(t) == "string" and t ~= "" then
            out.roster[#out.roster + 1] = { id = id, name = t }
        end
    end
    out.roster_n = #out.roster

    -- 2) raw FixedArray read diagnosis
    local fixed_arr = static_field("app.EnemyDef", "ID_BITFixedArray")
    out.diag = { live = is_live(fixed_arr), len = fixed_arr and managed_array_len(fixed_arr) }
    if is_live(fixed_arr) then
        out.diag.items = {}
        for i = 0, 7 do
            local v = array_get(fixed_arr, i)
            out.diag.items[#out.diag.items + 1] = {
                i = i, luatype = type(v), str = safe_str(v),
            }
        end
        -- GetValue(System.Int32) fallback (System.Array API)
        local td = safe(function() return fixed_arr:get_type_definition() end)
        local m_getvalue = td and safe(function()
            return td:get_method("GetValue(System.Int32)")
        end)
        out.diag.getvalue_method = m_getvalue ~= nil
        if m_getvalue then
            out.diag.getvalue_items = {}
            for i = 0, 7 do
                local v = safe(function() return m_getvalue:call(fixed_arr, i) end)
                out.diag.getvalue_items[#out.diag.getvalue_items + 1] = {
                    i = i, luatype = type(v), str = safe_str(v),
                }
            end
        end
    end

    -- 3) per-entry hypotheses
    out.profiles = {}
    for _, c in ipairs(captured) do
        if is_live(c.ptr) then
            local pe = { hr = field_value(c.ptr, "HunterRank"), entries = {} }
            local report = field_value(c.ptr, "ProfileEnemyReport")
            local arr = report and field_value(report, "BossReport")
            local len = arr and managed_array_len(arr)
            if len then
                for i = 0, len - 1 do
                    local el = array_get(arr, i)
                    if is_live(el) then
                        local h = field_value(el, "HuntingNum")
                        if type(h) == "number" and h ~= 0 then
                            local fixed = field_value(el, "FixedId")
                            local e = { index = i, fixed = fixed, hunt = h,
                                cap = field_value(el, "CaptureNum") }
                            if type(fixed) == "number" then
                                e.lowbyte = fixed % 256
                                -- lua % on negatives: normalize to 0..255
                                e.lowbyte = ((fixed % 256) + 256) % 256
                                e.text_lowbyte = resolve_text(e.lowbyte)
                                local lowword = ((fixed % 65536) + 65536) % 65536
                                e.lowword = lowword
                                e.text_lowword = resolve_text(lowword)
                                e.text_direct = resolve_text(fixed)
                            end
                            pe.entries[#pe.entries + 1] = e
                            if #pe.entries >= 12 then break end
                        end
                    end
                end
            end
            out.profiles[#out.profiles + 1] = pe
        end
    end

    json.dump_file(OUT_NAMES7, out)
    lastStatus = "names v7 (roster " .. tostring(out.roster_n) .. ") -> " .. OUT_NAMES7
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- Fixed-map scan (v6): EnemyDef.ID_BITFixedArray / ID_BITValueArray are
-- the static Fixed<->ID tables. Search our FixedIds, resolve via the value
-- array, then EnemyName + message text. Also lists BossReport element
-- methods (a getID-like helper may live on the element itself).
local function scan_fixed()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local enemy_td = safe(sdk.find_type_definition, "app.EnemyDef")
    local msg_td = safe(sdk.find_type_definition, "via.gui.message")
    local m_name = enemy_td and safe(function()
        return enemy_td:get_method("EnemyName(app.EnemyDef.ID)")
    end)
    local m_msg = msg_td and safe(function()
        return msg_td:get_method("get(System.Guid)")
    end)
    out.name_method = m_name ~= nil
    out.msg_method = m_msg ~= nil

    local fixed_arr = static_field("app.EnemyDef", "ID_BITFixedArray")
    local value_arr = static_field("app.EnemyDef", "ID_BITValueArray")
    out.fixed_len = fixed_arr and managed_array_len(fixed_arr)
    out.value_len = value_arr and managed_array_len(value_arr)
    out.fixed_type = safe_str(safe(function()
        local t = fixed_arr and fixed_arr:get_type_definition()
        return t and t:get_full_name()
    end))
    out.value_type = safe_str(safe(function()
        local t = value_arr and value_arr:get_type_definition()
        return t and t:get_full_name()
    end))
    out.max_id = safe_str(static_field("app.EnemyDef", "MaxID"))

    local function resolve_text(id)
        if m_name == nil or m_msg == nil or type(id) ~= "number" then
            return nil
        end
        local guid = safe(function() return m_name:call(nil, id) end)
        if guid == nil then return nil end
        return safe(function() return m_msg:call(nil, guid) end)
    end

    -- build fixed->index map from the static array (cap 512)
    local fixed_to_index = {}
    if fixed_arr and out.fixed_len then
        local upto = out.fixed_len > 512 and 512 or out.fixed_len
        for i = 0, upto - 1 do
            local v = array_get(fixed_arr, i)
            if type(v) == "number" and fixed_to_index[v] == nil then
                fixed_to_index[v] = i
            end
        end
    end
    out.map_size = 0
    for _ in pairs(fixed_to_index) do out.map_size = out.map_size + 1 end

    out.profiles = {}
    for _, c in ipairs(captured) do
        if is_live(c.ptr) then
            local pe = { hr = field_value(c.ptr, "HunterRank"), entries = {} }
            local report = field_value(c.ptr, "ProfileEnemyReport")
            local arr = report and field_value(report, "BossReport")
            local len = arr and managed_array_len(arr)
            if len then
                for i = 0, len - 1 do
                    local el = array_get(arr, i)
                    if is_live(el) then
                        local h = field_value(el, "HuntingNum")
                        if type(h) == "number" and h ~= 0 then
                            local fixed = field_value(el, "FixedId")
                            local e = { index = i, fixed = fixed, hunt = h,
                                cap = field_value(el, "CaptureNum") }
                            local idx = fixed_to_index[fixed]
                            e.map_index = idx
                            if idx ~= nil and value_arr then
                                e.mapped_id = array_get(value_arr, idx)
                                e.text_via_map = resolve_text(e.mapped_id)
                            end
                            -- direct: index itself as ID?
                            e.text_via_index = resolve_text(idx)
                            pe.entries[#pe.entries + 1] = e
                            if #pe.entries >= 12 then break end
                        end
                    end
                end
            end
            out.profiles[#out.profiles + 1] = pe
        end
    end

    -- BossReport element methods (getID-like helper?)
    out.element_methods = {}
    do
        local report = nil
        for _, c in ipairs(captured) do
            if is_live(c.ptr) then
                report = field_value(c.ptr, "ProfileEnemyReport")
                if report then break end
            end
        end
        local arr = report and field_value(report, "BossReport")
        local len = arr and managed_array_len(arr)
        if len then
            for i = 0, math.min(len - 1, 4) do
                local el = array_get(arr, i)
                if is_live(el) then
                    local etd = safe(function() return el:get_type_definition() end)
                    if etd then
                        for _, m in ipairs(safe(function() return etd:get_methods() end) or {}) do
                            out.element_methods[#out.element_methods + 1] =
                                safe(function() return m:get_name() end)
                        end
                    end
                    break
                end
            end
        end
    end

    json.dump_file(OUT_FIXED, out)
    lastStatus = "fixed map -> " .. OUT_FIXED
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- Name-chain test (v5): FixedId -> bitindex -> EnemyName guid ->
-- localized text, for the nonzero BossReport entries of each live captured
-- profile. Proves the per-monster name list for the mod.
local function test_names()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        profiles = {},
    }
    local enemy_td = safe(sdk.find_type_definition, "app.EnemyDef")
    local msg_td = safe(sdk.find_type_definition, "via.gui.message")
    out.enemy_def_found = enemy_td ~= nil
    out.msg_found = msg_td ~= nil
    local m_bit = enemy_td and safe(function()
        return enemy_td:get_method("getID_BITIndexFromFixed")
    end)
    local m_name = enemy_td and safe(function()
        return enemy_td:get_method("EnemyName(app.EnemyDef.ID)")
    end)
    local m_msg = msg_td and safe(function()
        return msg_td:get_method("get(System.Guid)")
    end)
    out.bit_method = m_bit ~= nil
    out.name_method = m_name ~= nil
    out.msg_method = m_msg ~= nil
    for _, c in ipairs(captured) do
        if is_live(c.ptr) then
            local pe = { hr = field_value(c.ptr, "HunterRank"), entries = {} }
            local report = field_value(c.ptr, "ProfileEnemyReport")
            local arr = report and field_value(report, "BossReport")
            local len = arr and managed_array_len(arr)
            if len then
                for i = 0, len - 1 do
                    local el = array_get(arr, i)
                    if is_live(el) then
                        local h = field_value(el, "HuntingNum")
                        if type(h) == "number" and h ~= 0 then
                            local fixed = field_value(el, "FixedId")
                            local e = { index = i, fixed = fixed, hunt = h,
                                cap = field_value(el, "CaptureNum") }
                            if m_bit and type(fixed) == "number" then
                                e.bitindex = safe(function()
                                    return m_bit:call(nil, fixed)
                                end)
                            end
                            if m_name and type(e.bitindex) == "number" then
                                e.guid = safe(function()
                                    return m_name:call(nil, e.bitindex)
                                end)
                            end
                            -- direct attempt too (small FixedIds may be raw IDs)
                            if m_name and type(fixed) == "number" then
                                e.guid_direct = safe(function()
                                    return m_name:call(nil, fixed)
                                end)
                            end
                            if m_msg and e.guid ~= nil then
                                e.text = safe(function()
                                    return m_msg:call(nil, e.guid)
                                end)
                            end
                            if m_msg and e.guid_direct ~= nil then
                                e.text_direct = safe(function()
                                    return m_msg:call(nil, e.guid_direct)
                                end)
                            end
                            e.guid = safe_str(e.guid)
                            e.guid_direct = safe_str(e.guid_direct)
                            pe.entries[#pe.entries + 1] = e
                            if #pe.entries >= 12 then break end
                        end
                    end
                end
            end
            out.profiles[#out.profiles + 1] = pe
        end
    end
    json.dump_file(OUT_NAMES, out)
    lastStatus = "name chain -> " .. OUT_NAMES
    log.info("[KillProbe] " .. lastStatus)
    return out
end

local function snapshot_captured()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        hook_armed = hook_armed,
        profiles = {},
    }
    for i, c in ipairs(captured) do
        local e = { index = i, wall = c.wall, live = is_live(c.ptr) }
        if e.live then
            e.dump = deep_dump(c.ptr, "profile#" .. i, 2)
            e.boss_detail = boss_detail(c.ptr)
        end
        out.profiles[#out.profiles + 1] = e
    end
    json.dump_file(OUT_PROFILE, out)
    local live_n = 0
    for _, e in ipairs(out.profiles) do
        if e.live then live_n = live_n + 1 end
    end
    lastStatus = string.format("captured: %d/%d live -> %s",
        live_n, #out.profiles, OUT_PROFILE)
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- save + lobby snapshots
-- ---------------------------------------------------------------------------

local function snapshot_save()
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        singletons = {},
    }
    for _, name in ipairs({ "app.SaveDataManager", "app.PlayerManager" }) do
        local obj = safe(sdk.get_managed_singleton, name)
        if is_live(obj) then
            out.singletons[name] = scan_object(obj, name)
        else
            out.singletons[name] = { missing = true }
        end
    end
    -- LOCAL save path: _UserSaveData field first (plain read, no call),
    -- then getCurrentUserSaveData() as fallback. Deep-dump whatever we get:
    -- if the profile blocks (EnemyReport etc.) are reachable here, the local
    -- total needs no profile UI at all.
    local sdm = safe(sdk.get_managed_singleton, "app.SaveDataManager")
    if is_live(sdm) then
        local usd = field_value(sdm, "_UserSaveData")
        out.user_save_field_type = safe_str(safe(function()
            local t = usd and usd:get_type_definition()
            return t and t:get_full_name()
        end))
        if not is_live(usd) then
            usd = call_method(sdm, "getCurrentUserSaveData")
            out.user_save_via = "getCurrentUserSaveData"
        else
            out.user_save_via = "_UserSaveData"
        end
        if is_live(usd) then
            out.user_save = scan_object(usd, "user_save")
            out.user_save_deep = deep_dump(usd, "user_save", 2)
            -- drill into _Data[i] (cUserSaveParam per save slot): hunt-scan
            -- _EnemyReport / _HunterProfile for report arrays. Proves the
            -- local total with no profile UI open.
            out.save_slots = {}
            local data = field_value(usd, "_Data")
            local dlen = data and managed_array_len(data)
            if dlen then
                for i = 0, dlen - 1 do
                    local el = array_get(data, i)
                    local se = { index = i, live = is_live(el) }
                    if se.live then
                        se.type = safe_str(safe(function()
                            local t = el:get_type_definition()
                            return t and t:get_full_name()
                        end))
                        se.hunter_id = safe_str(field_value(el, "HunterId"))
                        se.play_time = safe_str(field_value(el, "PlayTime"))
                        local er = field_value(el, "_EnemyReport")
                        if is_live(er) then
                            se.enemy_report = scan_hunt_arrays(er, "enemy_report")
                        end
                        local hp = field_value(el, "_HunterProfile")
                        if is_live(hp) then
                            se.hunter_profile = scan_hunt_arrays(hp, "hunter_profile")
                        end
                    end
                    out.save_slots[#out.save_slots + 1] = se
                end
            end
        else
            out.user_save = { missing = true }
        end
    end
    json.dump_file(OUT_SAVE, out)
    lastStatus = "save deep snapshot -> " .. OUT_SAVE
    log.info("[KillProbe] " .. lastStatus)
    return out
end

local function lobby_snapshot()
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    local out = {
        probe_version = PROBE_VERSION,
        wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        gui_note = "v1 proved Gui* profile singletons do not exist; see captured profiles instead",
    }
    if not pm then
        out.fail = "no_player_manager"
        json.dump_file(OUT_LOBBY, out)
        lastStatus = "lobby: no PlayerManager -> " .. OUT_LOBBY
        return out
    end
    out.members = {}
    local arr = instanced_array(pm)
    if not arr then
        out.fail = "no_instanced_list"
    else
        for i = 0, 15 do
            local inst = array_get(arr, i)
            if not is_live(inst) then break end
            local pi = call_method(inst, "get_PlayerInfo")
            local ch = character_of(inst, pi)
            local st = ch and call_method(ch, "get_HunterStatus")
            local nm, via = try_name(pi, ch, st)
            local m = {
                slot = i,
                name = nm,
                name_via = via,
                is_master = st and call_method(st, "get_IsMaster"),
                is_npc = st and call_method(st, "get_IsNpc"),
                is_user_control = st and call_method(st, "get_IsUserControl"),
            }
            if st then m.status = scan_object(st, "status") end
            if pi then m.player_info = scan_object(pi, "player_info") end
            if ch then
                m.character = scan_object(ch, "character")
                local holder = call_method(ch, "get_HunterInfoHolder")
                if is_live(holder) then
                    m.holder = scan_object(holder, "holder")
                    m.holder_all_methods = all_method_names(holder, 120)
                end
            end
            if pi then
                local ctx = call_method(pi, "get_ContextHolder")
                if is_live(ctx) then
                    m.context = scan_object(ctx, "context")
                    m.context_all_methods = all_method_names(ctx, 120)
                    m.context_primitive = object_primitive_map(ctx, 80)
                end
            end
            out.members[#out.members + 1] = m
        end
    end
    json.dump_file(OUT_LOBBY, out)
    lastStatus = string.format("lobby v2: %d member(s) -> %s", #out.members, OUT_LOBBY)
    log.info("[KillProbe] " .. lastStatus)
    return out
end

-- ---------------------------------------------------------------------------
-- ctor hook: capture every app.cHunterProfile built (profile screens,
-- guild-card views, ...). Capture only; reading happens on button press.
-- ---------------------------------------------------------------------------

local function register_hooks()
    local hooked = {}
    safe(function()
        local t = sdk.find_type_definition("app.cHunterProfile")
        if not t then
            log.warn("[KillProbe] app.cHunterProfile not found; capture unavailable")
            return
        end
        for _, m in ipairs(safe(function() return t:get_methods() end) or {}) do
            local mname = safe(function() return m:get_name() end)
            if mname == ".ctor" then
                local nparams = safe(function() return m:get_num_params() end) or 0
                safe(function()
                    sdk.hook(m, function(args)
                        if not hook_armed then return end
                        safe(function()
                            local obj = sdk.to_managed_object(args[2])
                            if is_live(obj) then
                                captured[#captured + 1] = {
                                    ptr = obj,
                                    wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                                }
                                while #captured > 8 do
                                    table.remove(captured, 1)
                                end
                                lastStatus = string.format(
                                    "captured profile #%d (open profiles, then Snapshot)",
                                    #captured)
                            end
                        end)
                    end, nil)
                    hooked[#hooked + 1] = ".ctor(" .. tostring(nparams) .. "p)"
                end)
            end
        end
    end)
    if #hooked == 0 then
        log.warn("[KillProbe] no cHunterProfile.ctor hooks registered")
    else
        log.info("[KillProbe] hooks: cHunterProfile " .. table.concat(hooked, ", "))
    end
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local function live_members()
    local res = {}
    local pm = safe(function() return sdk.get_managed_singleton("app.PlayerManager") end)
    if not pm then return res end
    local arr = instanced_array(pm)
    if not arr then return res end
    for i = 0, 15 do
        local inst = array_get(arr, i)
        if not is_live(inst) then break end
        local pi = call_method(inst, "get_PlayerInfo")
        local ch = character_of(inst, pi)
        local st = ch and call_method(ch, "get_HunterStatus")
        local nm = try_name(pi, ch, st)
        res[#res + 1] = {
            slot = i,
            name = nm or "(?)",
            user = st and call_method(st, "get_IsUserControl"),
            npc = st and call_method(st, "get_IsNpc"),
        }
    end
    return res
end

local function draw_ui()
    if not imgui.tree_node("KillProbe v4 (kill totals)") then return end
    imgui.text("Read-only. Hook captures profiles; buttons dump JSON.")
    imgui.text("status: " .. tostring(lastStatus))
    imgui.text(string.format("captured profiles: %d  hook: %s",
        #captured, hook_armed and "ARMED" or "off"))
    for _, m in ipairs(live_members()) do
        imgui.text(string.format("[%d] %s  user=%s npc=%s",
            m.slot, tostring(m.name),
            tostring(m.user), tostring(m.npc)))
    end
    if imgui.button("Dump types v4") then
        local ok, err = pcall(dump_types)
        if not ok then lastStatus = "dump_types error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Snapshot save deep") then
        local ok, err = pcall(snapshot_save)
        if not ok then lastStatus = "save error: " .. tostring(err) end
    end
    if imgui.button("Snapshot lobby v4") then
        local ok, err = pcall(lobby_snapshot)
        if not ok then lastStatus = "lobby error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Snapshot captured v4") then
        local ok, err = pcall(snapshot_captured)
        if not ok then lastStatus = "captured error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Test name chain") then
        local ok, err = pcall(test_names)
        if not ok then lastStatus = "names error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Scan fixed map") then
        local ok, err = pcall(scan_fixed)
        if not ok then lastStatus = "fixed error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Scan names v7") then
        local ok, err = pcall(scan_names7)
        if not ok then lastStatus = "names7 error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Scan enemy data") then
        local ok, err = pcall(scan_enemydata)
        if not ok then lastStatus = "enemydata error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Scan tables v9") then
        local ok, err = pcall(scan_tables)
        if not ok then lastStatus = "tables error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Scan boss data") then
        local ok, err = pcall(scan_bossdata)
        if not ok then lastStatus = "bossdata error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Scan full map") then
        local ok, err = pcall(scan_map)
        if not ok then lastStatus = "map error: " .. tostring(err) end
    end
    imgui.same_line()
    if imgui.button("Scan enemy IDs") then
        local ok, err = pcall(scan_ids)
        if not ok then lastStatus = "ids error: " .. tostring(err) end
    end
    if imgui.button("Hook: arm/disarm") then
        hook_armed = not hook_armed
        lastStatus = "hook " .. (hook_armed and "ARMED" or "off")
    end
    imgui.same_line()
    if imgui.button("Clear captured") then
        captured = {}
        lastStatus = "captured cleared"
    end
    imgui.text("1) Dump types v4 + Snapshot save deep + Snapshot lobby v4.")
    imgui.text("2) open YOUR profile, then someone else's profile.")
    imgui.text("3) Snapshot captured v4 -> kill_probe4_profile.json.")
    imgui.tree_pop()
end

-- ---------------------------------------------------------------------------

if not ALREADY_LOADED then
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then log.warn("[KillProbe] draw_ui: " .. tostring(err)) end
    end)
    register_hooks()
    log.info("[KillProbe] loaded v" .. tostring(PROBE_VERSION)
        .. " (dev probe, hook captures + buttons dump)")
else
    log.info("[KillProbe] duplicate load ignored (callbacks already registered)")
end
