---@diagnostic disable: lowercase-global
ScriptHost:LoadScript("scripts/autotracking/hints_mapping.lua")
ScriptHost:LoadScript("scripts/autotracking/item_mapping.lua")
ScriptHost:LoadScript("scripts/autotracking/location_mapping.lua")
ScriptHost:LoadScript("scripts/autotracking/location_mapping_new.lua")
ScriptHost:LoadScript("scripts/autotracking/location_mapping_bridge.lua")
ScriptHost:LoadScript("scripts/autotracking/tables.lua")
-- Real logic solver (region graph + time-slice reachability), ported from
-- the apworld's own LogicRuntime.py. Load order matters: helpers/regions/
-- options before the runtime that consumes them.
ScriptHost:LoadScript("scripts/autotracking/logic/logic_helpers_gen.lua")
ScriptHost:LoadScript("scripts/autotracking/logic/region_data.lua")
ScriptHost:LoadScript("scripts/autotracking/logic/option_data.lua")
ScriptHost:LoadScript("scripts/autotracking/logic/logic_runtime.lua")
ScriptHost:LoadScript("scripts/autotracking/logic/name_to_code.lua")

CUR_INDEX = -1
SLOT_DATA = nil
LOCAL_ITEMS = {}
GLOBAL_ITEMS = {}

-- Real-logic plumbing. LOGIC_COUNTS mirrors the AP-received inventory keyed
-- by item display name (exactly what onItem's item_name parameter already
-- gives us, no lookup needed -- see counts.get(name,0) in LogicRuntime.py's
-- LogicContext). LOGIC_SOLVER is instantiated once slot_data/options are
-- known (onClear). LOGIC_RESULT is the most recent solve() output, read by
-- every location's access_rules via the LOGIC_REACHABLE function below.
LOGIC_COUNTS = {}
LOGIC_SOLVER = nil
LOGIC_RESULT = nil

-- LOGIC_REACHABLE is called once per location's access_rules, and PopTracker
-- re-evaluates every wired access_rule (thousands of them, across the full
-- Checks tab and every map pin) in one synchronous pass whenever a single
-- tracked item changes. Rebuilding the ~700-entry live counts table and
-- resolving the solver on every one of those calls -- instead of once per
-- actual change -- is what was blowing PopTracker's script execution limit
-- and showing up as a long stall followed by everything reading as
-- unreachable. AddWatchForCode("*") fires once per real item-state change
-- (covers manual UI toggles, which never call onItem), so LOGIC_DIRTY turns
-- that "once per rule call" cost into "once per actual change".
LOGIC_DIRTY = true
-- True whenever the most recent solve attempt hit PopTracker's rule
-- execution limit and LOGIC_RESULT is therefore left over from an earlier,
-- possibly outdated inventory -- see updateLogicResult()/LOGIC_REACHABLE()
-- below, and "override_rule_exec_limit" in PopTracker's own settings.
-- Surfaced as AccessibilityLevel.Inspect rather than silently trusting the
-- stale data, since items received after the failed solve may or may not
-- actually change any given location's true accessibility and there is no
-- way to tell which without a successful solve.
LOGIC_STALE = false
ScriptHost:AddWatchForCode("logic_reachability_dirty", "*", function(code)
    LOGIC_DIRTY = true
end)

-- Builds RO_KEY -> int from slot_data using LOGIC_OPTIONS_TABLE's ap_name
-- mapping (every RO_OPTIONS value is emitted into slot_data keyed by its own
-- ap_name -- see fill_slot_data() in the apworld's __init__.py).
local function buildLogicOptions(slot_data)
    local opts = {}
    for ro_key, pair in pairs(LOGIC_OPTIONS_TABLE) do
        local ap_name, default = pair[1], pair[2]
        local v = slot_data[ap_name]
        opts[ro_key] = (v ~= nil) and v or default
    end
    return opts
end

-- Builds the logic inventory fresh from the tracker's CURRENT UI state for
-- every item whose pop-tracker code uniquely identifies it (NAME_TO_CODE),
-- merged with LOGIC_COUNTS (the network-accumulated counts, kept only for
-- COLLISION_ITEM_NAMES -- items that share one pop-tracker widget with other
-- distinct AP items, e.g. 6 named clock items used to all collapse into one
-- generic counter, so the tracker's own state can't tell them apart; see
-- name_to_code.lua). Reading live state instead of relying solely on
-- accumulated network events means manually toggling an item in the UI
-- affects logic the same way receiving it over the wire does.
local function widgetCount(code, kind)
    local obj = Tracker:FindObjectForCode(code)
    if not obj then
        return nil
    end
    if kind == "toggle" then
        return obj.Active and 1 or 0
    elseif kind == "progressive" then
        return obj.CurrentStage
    elseif kind == "consumable" then
        return obj.AcquiredCount
    end
    return nil
end

local function buildLogicCounts()
    local counts = {}
    for name, entry in pairs(NAME_TO_CODE) do
        local v = widgetCount(entry[1], entry[2])
        if v ~= nil then
            counts[name] = v
        end
    end
    -- OR-only collision groups (bombbag, magic): logic only ever checks for
    -- ANY of these being held, so the shared widget's live state can stand
    -- in for every name in the group -- see name_to_code.lua.
    for code, group in pairs(OR_GROUP_CODES) do
        local v = widgetCount(code, group.type)
        if v ~= nil and v ~= 0 then
            for _, name in ipairs(group.names) do
                counts[name] = 1
            end
        end
    end
    -- Goron's Lullaby widget: shares its "goronlullaby" code across 3 AP
    -- items (Progressive Goron Lullaby x2 = full song, or either of
    -- "Goron Lullaby Intro"/"Goron Lullaby" as one-shot direct grants), but
    -- the pack's own widget (items/equipment.jsonc) only actually HAS 2
    -- stages -- off and "learned" -- there's no separate UI state for
    -- intro-only. So toggling it on is read as the full song (count 2),
    -- which also satisfies the weaker intro-only threshold (needs count 1).
    do
        local v = widgetCount("goronlullaby", "progressive")
        if v ~= nil and v ~= 0 then
            counts["Progressive Goron Lullaby"] = 2
        end
    end
    -- Wallet Upgrades widget: one progressive item (stages 0-3: none, Adult's,
    -- Giant's, Tycoon's) sharing its codes with the collision group behind
    -- upg_value(UPG_WALLET) in logic_runtime.lua, which takes the higher of
    -- a "Progressive Wallet" counter and any directly-granted named tier.
    -- The widget's CurrentStage (0-3) already equals the desired tier, so
    -- reading it as the "Progressive Wallet" counter satisfies both paths
    -- at once -- same live-read treatment as Goron's Lullaby above.
    do
        local v = widgetCount("childswallet", "progressive")
        if v ~= nil and v ~= 0 then
            counts["Progressive Wallet"] = v
        end
    end
    -- Sword widget: stages 0-2 are Kokiri/Razor/Gilded (there's no "no sword"
    -- stage -- vanilla always starts with Kokiri), matching tiers 1-3 of
    -- equip_value(EQUIP_TYPE_SWORD)'s count(progressive_sword) path in
    -- logic_runtime.lua, hence the +1. Same live-read reasoning as Wallet.
    do
        local v = widgetCount("sword", "progressive")
        if v ~= nil then
            counts["Progressive Sword"] = v + 1
        end
    end
    -- Shield widget: stage 0 is Hero's Shield, stage 1 is Mirror Shield --
    -- equip_value(EQUIP_TYPE_SHIELD) checks those two names directly rather
    -- than a count, so map the stage straight to whichever name it implies.
    do
        local v = widgetCount("shield", "progressive")
        if v == 0 then
            counts["Hero's Shield"] = 1
        elseif v == 1 then
            counts["Mirror Shield"] = 1
        end
    end
    for name, count in pairs(LOGIC_COUNTS) do
        counts[name] = count
    end
    return counts
end

-- Re-runs the solver against the current tracker state and stores the
-- result. Only does real work when LOGIC_DIRTY is set (see the
-- AddWatchForCode hook above) -- otherwise every one of the thousands of
-- access_rules calls per refresh would redo the full live-counts rebuild
-- and solve from scratch, which is what caused the reported multi-second
-- stalls and everything briefly reading as unreachable.
function updateLogicResult()
    if not LOGIC_SOLVER then
        return
    end
    if not LOGIC_DIRTY and LOGIC_RESULT ~= nil then
        return
    end
    local result = LOGIC_SOLVER:solve_from_inventory(buildLogicCounts())
    LOGIC_DIRTY = false
    if result == nil then
        -- This exact inventory signature hit PopTracker's rule execution
        -- limit (raise "override_rule_exec_limit" in PopTracker's settings
        -- if this happens regularly -- Solver:solve has already memoized
        -- the failure either way, so retrying it here is cheap, not free).
        -- LOGIC_RESULT is left as whatever it was, but LOGIC_STALE now tells
        -- LOGIC_REACHABLE not to trust it -- items received since the last
        -- successful solve may have changed what's actually reachable, and
        -- there is no way to tell which locations are affected without a
        -- successful solve.
        LOGIC_STALE = true
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
            print("updateLogicResult: solve hit the rule execution limit for this signature -- marking stale")
        end
        return
    end
    LOGIC_STALE = false
    LOGIC_RESULT = result
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
        local nregions, nchecks = 0, 0
        for _ in pairs(LOGIC_RESULT.regions) do nregions = nregions + 1 end
        for _ in pairs(LOGIC_RESULT.checks) do nchecks = nchecks + 1 end
        print(string.format("updateLogicResult: %d regions, %d checks reachable", nregions, nchecks))
    end
end

-- Called directly from a location section's access_rules as
-- `"^$LOGIC_REACHABLE|RC_SOME_CHECK_NAME"` (the `^` tells PopTracker to
-- treat the return value as an AccessibilityLevel rather than a plain
-- boolean). Same pattern the Ship of Harkinian AP tracker pack uses for
-- OoT's equally non-declarative logic.
function LOGIC_REACHABLE(rc_name)
    -- Cheap unless LOGIC_DIRTY: PopTracker's native rule engine re-invokes
    -- $-rule functions on ANY tracked item change, including a manual UI
    -- toggle, which never goes through onItem at all -- but it re-invokes
    -- them for every wired location at once, not just the one that
    -- changed, so updateLogicResult() only doing real work on the first
    -- call of a batch is what keeps this affordable.
    updateLogicResult()
    if LOGIC_STALE then
        -- Don't confidently show a color that might be wrong: Inspect signals
        -- "the solver couldn't determine this for the current inventory" --
        -- distinct from both Normal (reachable) and None (not reachable).
        return AccessibilityLevel.Inspect
    end
    if LOGIC_RESULT and LOGIC_RESULT.checks[rc_name] then
        return AccessibilityLevel.Normal
    end
    return AccessibilityLevel.None
end

function onClear(slot_data)
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
        print(string.format("called onClear, slot_data:\n%s", dump_table(slot_data)))
    end
    SLOT_DATA = slot_data
    CUR_INDEX = -1
    -- reset locations
    for _, location_array in pairs(LOCATION_MAPPING) do
        for _, location in pairs(location_array) do
            if location then
                local obj = Tracker:FindObjectForCode(location)
                if obj then
                    if location:sub(1, 1) == "@" then
                        obj.AvailableChestCount = obj.ChestCount
                    else
                        obj.Active = false
                    end
                end
            end
        end
    end
    -- reset locations (2S2H checks list, phase 2)
    for _, code in pairs(LOCATION_MAPPING_NEW) do
        local obj = Tracker:FindObjectForCode(code)
        if obj then
            obj.Active = false
        end
    end
    -- reset locations (old-pack map pins bridged to new AP ids, high-confidence subset only)
    for _, location in pairs(LOCATION_MAPPING_BRIDGE) do
        local obj = Tracker:FindObjectForCode(location)
        if obj then
            if location:sub(1, 1) == "@" then
                obj.AvailableChestCount = obj.ChestCount
            else
                obj.Active = false
            end
        end
    end
    -- reset items
    for _, v in pairs(ITEM_MAPPING) do
        if v[1] and v[2] then
            if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
                print(string.format("onClear: clearing item %s of type %s", v[1], v[2]))
            end
            local obj = Tracker:FindObjectForCode(v[1])
            if obj then
                if v[2] == "toggle" then
                    obj.Active = false
                elseif v[2] == "progressive" then
                    obj.CurrentStage = 0
                    obj.Active = false
                elseif v[2] == "consumable" then
                    obj.AcquiredCount = 0
                elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
                    print(string.format("onClear: unknown item type %s for code %s", v[2], v[1]))
                end
            elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
                print(string.format("onClear: could not find object for code %s", v[1]))
            end
        end
    end

    --Tracker:FindObjectForCode("bottle_1").Active = false
    --Tracker:FindObjectForCode("bottle_2").Active = false
    --Tracker:FindObjectForCode("bottle_3").Active = false

	PLAYER_NUMBER = Archipelago.PlayerNumber or -1
	TEAM_NUMBER = Archipelago.TeamNumber or 0

    LOCAL_ITEMS = {}
    GLOBAL_ITEMS = {}


    if Archipelago.PlayerNumber > -1 then
        HINTS_ID = "_read_hints_"..TEAM_NUMBER.."_"..PLAYER_NUMBER
        Archipelago:SetNotify({HINTS_ID})
        Archipelago:Get({HINTS_ID})
    end

    -- read YAML options
    local function setFromSlotData(slot_data_key, item_code)
        local v = slot_data[slot_data_key]
        if not v then
            print(string.format("Could not find key '%s' in slot data", slot_data_key))
            return nil
        end

        local obj = Tracker:FindObjectForCode(item_code)
        if not obj then
            print(string.format("Could not find item for code '%s'", item_code))
            return nil
        end

        if obj.Type == 'toggle' then
            local active = v ~= 0
            obj.Active = active
            return v
        elseif obj.Type == 'progressive' then
            obj.CurrentStage = v
            return v
        elseif obj.Type == 'consumable' then
            obj.AcquiredCount = v
            return v
        else
            print(string.format("Unsupported item type '%s' for item '%s'", tostring(obj.Type), item_code))
            return nil
        end
    end

    setFromSlotData("logic_difficulty","logic_difficulty")
    setFromSlotData("majora_remains_required","majora_remains_required")
    setFromSlotData("moon_remains_required","moon_remains_required")
    setFromSlotData("remains_allow_boss_warps","remains_allow_boss_warps")
    setFromSlotData("camc","camc")
    setFromSlotData("swordless","swordless")
    setFromSlotData("shieldless","shieldless")
    setFromSlotData("start_with_soaring","start_with_soaring")
    setFromSlotData("starting_hearts","starting_hearts")
    setFromSlotData("starting_hearts_are_containers_or_pieces","starting_hearts_are_containers_or_pieces")
    setFromSlotData("shuffle_tingle_shops","shuffle_tingle_shops")
    setFromSlotData("shuffle_boss_remains","shuffle_boss_remains")
    setFromSlotData("shuffle_spiderhouse_reward","shuffle_spiderhouse_reward")
    setFromSlotData("shuffle_gold_skulltulas","skullsanity")
    setFromSlotData("shuffle_shops","shopsanity")
    setFromSlotData("shuffle_cows","cowsanity")
    setFromSlotData("shuffle_owl_statues","shuffle_owl_statues")
    setFromSlotData("shuffle_grass_drops","shuffle_grass_drops")
    setFromSlotData("shuffle_pot_drops","shuffle_pot_drops")
    setFromSlotData("shuffle_tree_drops","shuffle_tree_drops")
    setFromSlotData("shuffle_crate_drops","shuffle_crate_drops")
    setFromSlotData("exclude_termina_field_grass","exclude_termina_field_grass")
    setFromSlotData("exclude_cow_grotto_grass","exclude_cow_grotto_grass")
    setFromSlotData("shuffle_great_fairy_rewards","shuffle_great_fairy_rewards")

    -- Derived visibility toggles: some grass checks get dropped from the AP
    -- location pool entirely under certain settings combos (see
    -- LocationFilter.py), so "shuffle_grass_drops alone" isn't enough to
    -- decide whether a given grass pin represents a real check this seed.
    -- visibility_rules has no negation syntax, so compute the combined
    -- boolean here and gate on this instead for the affected pins.
    local grass_on = slot_data["shuffle_grass_drops"]
    local exclude_termina_field = slot_data["exclude_termina_field_grass"]
    local exclude_cow_grotto = slot_data["exclude_cow_grotto_grass"]
    local termina_field_obj = Tracker:FindObjectForCode("grass_termina_field_active")
    if termina_field_obj then
        termina_field_obj.Active = (grass_on and grass_on ~= 0) and not (exclude_termina_field and exclude_termina_field ~= 0)
    end
    local cow_grotto_obj = Tracker:FindObjectForCode("grass_cow_grotto_active")
    if cow_grotto_obj then
        cow_grotto_obj.Active = (grass_on and grass_on ~= 0) and not (exclude_cow_grotto and exclude_cow_grotto ~= 0)
    end
    -- scrubsanity/fairysanity removed: no such options exist in the current
    -- apworld (scrubs and stray fairies appear to always be shuffled now,
    -- no on/off toggle to read) -- these were dead reads printing "could not
    -- find key" every connect for no benefit.
    setFromSlotData("start_with_consumables","start_with_consumables")
    setFromSlotData("permanent_chateau_romani","permanent_chateau_romani")
    setFromSlotData("start_with_inverted_time","start_with_inverted_time")
    setFromSlotData("receive_filled_wallets","receive_filled_wallets")
    setFromSlotData("damage_multiplier","damage_multiplier")
    setFromSlotData("death_behavior","death_behavior")
    setFromSlotData("death_link","death_link")

    -- Real logic solver: fresh instance per connect (options are per-seed).
    -- shop_prices comes straight from slot_data (fill_slot_data() puts the
    -- real RC_* -> price table there directly -- no separate port needed).
    LOGIC_COUNTS = {}
    local logic_opts = buildLogicOptions(slot_data)
    local shop_prices = slot_data["shop_prices"] or {}
    LOGIC_SOLVER = LOGIC_RUNTIME.Solver.new(logic_opts, shop_prices)
    -- Force a real solve below even if nothing has changed since the last
    -- connection's LOGIC_DIRTY got cleared -- LOGIC_SOLVER is a fresh
    -- instance now, so any cached LOGIC_RESULT is stale regardless.
    LOGIC_DIRTY = true
    updateLogicResult()
end

-- called when an item gets collected
function onItem(index, item_id, item_name, player_number)
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
        print(string.format("called onItem: %s, %s, %s, %s, %s", index, item_id, item_name, player_number, CUR_INDEX))
    end
    if not AUTOTRACKER_ENABLE_ITEM_TRACKING then
        return
    end
    if index <= CUR_INDEX then
        return
    end
    local is_local = player_number == Archipelago.PlayerNumber
    CUR_INDEX = index;

    -- Real logic solver inventory: keyed by AP item display name, exactly
    -- what item_name already is here. Only accumulated here for items whose
    -- pop-tracker widget can't be read back unambiguously (COLLISION_ITEM_NAMES,
    -- e.g. items sharing one progressive counter) or that have no UI
    -- representation at all -- everything else is read fresh from live
    -- tracker state in buildLogicCounts() instead, so a manual UI toggle
    -- affects logic the same way a real network item does. See
    -- name_to_code.lua.
    if COLLISION_ITEM_NAMES[item_name] or not NAME_TO_CODE[item_name] then
        LOGIC_COUNTS[item_name] = (LOGIC_COUNTS[item_name] or 0) + 1
        -- This item has no widget (or an ambiguous one), so no
        -- AddWatchForCode callback will fire for it -- mark dirty by hand.
        LOGIC_DIRTY = true
    end
    updateLogicResult()

    local v = ITEM_MAPPING[item_id]
    if not v then
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
            print(string.format("onItem: could not find item mapping for id %s", item_id))
        end
        return
    end
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
        print(string.format("onItem: code: %s, type %s", v[1], v[2]))
    end
    if not v[1] then
        return
    end
    local obj = Tracker:FindObjectForCode(v[1])
    if obj then
        if v[2] == "toggle" then
            obj.Active = true
        elseif v[2] == "progressive" then
            if obj.Active then
                obj.CurrentStage = obj.CurrentStage + 1
            else
                obj.Active = true
            end
        elseif v[2] == "consumable" then
            obj.AcquiredCount = obj.AcquiredCount + obj.Increment
        elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
            print(string.format("onItem: unknown item type %s for code %s", v[2], v[1]))
        end
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
        print(string.format("onItem: could not find object for code %s", v[1]))
    end
end

-- called when a location gets cleared
function onLocation(location_id, location_name)
    local found = false

    local location_array = LOCATION_MAPPING[location_id]
    if location_array and location_array[1] then
        found = true
        for _, location in pairs(location_array) do
            local obj = Tracker:FindObjectForCode(location)
            -- print(location, obj)
            if obj then
                if location:sub(1, 1) == "@" then
                    obj.AvailableChestCount = obj.AvailableChestCount - 1
                else
                    obj.Active = true
                end
            else
                print(string.format("onLocation: could not find object for code %s", location))
            end
        end
    end

    -- 2S2H checks list (phase 2)
    local new_code = LOCATION_MAPPING_NEW[location_id]
    if new_code then
        found = true
        local obj = Tracker:FindObjectForCode(new_code)
        if obj then
            obj.Active = true
        else
            print(string.format("onLocation: could not find object for code %s", new_code))
        end
    end

    -- old-pack map pins bridged to new AP ids (high-confidence subset only)
    local bridge_ref = LOCATION_MAPPING_BRIDGE[location_id]
    if bridge_ref then
        found = true
        local obj = Tracker:FindObjectForCode(bridge_ref)
        if obj then
            if bridge_ref:sub(1, 1) == "@" then
                obj.AvailableChestCount = obj.AvailableChestCount - 1
            else
                obj.Active = true
            end
        else
            print(string.format("onLocation: could not find object for code %s", bridge_ref))
        end
    end

    if not found then
        print(string.format("onLocation: could not find location mapping for id %s", location_id))
    end
end


function onNotify(key, value, old_value)

    if value ~= old_value and key == HINTS_ID then
        for _, hint in ipairs(value) do
            if hint.finding_player == Archipelago.PlayerNumber then
                if not hint.found then
                    updateHints(hint.location)
                else if hint.found then
                    updateHints(hint.location)
                    end
                end
            end
        end
    end
end

function onNotifyLaunch(key, value)
    if key == HINTS_ID then
        for _, hint in ipairs(value) do
            if hint.finding_player == Archipelago.PlayerNumber then
                if not hint.found then
                    updateHints(hint.location)
                elseif hint.found then
                    updateHints(hint.location)
                end
            end
        end
    end
end

 
function updateHints(locationID)
    local item_codes = HINTS_MAPPING[locationID]

    for _, item_code in ipairs(item_codes) do
        local obj = Tracker:FindObjectForCode(item_code)
        if obj then
            obj.Active = true
        else
            print(string.format("No object found for code: %s", item_code))
        end
    end
end
 
function updateHintsClear(locationID)
    local item_codes = HINTS_MAPPING[locationID]

    for _, item_code in ipairs(item_codes) do
        local obj = Tracker:FindObjectForCode(item_code)
        if obj then
            obj.Active = false
        else
            print(string.format("No object found for code: %s", item_code))
        end
    end
end

-- called when a locations is scouted
function onScout(location_id, location_name, item_id, item_name, item_player)
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
        print(string.format("called onScout: %s, %s, %s, %s, %s", location_id, location_name, item_id, item_name,
            item_player))
    end
    -- not implemented yet :(
end

-- called when a bounce message is received 
function onBounce(json)
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING_AP then
        print(string.format("called onBounce: %s", dump_table(json)))
    end
    -- your code goes here
end

Archipelago:AddClearHandler("clear handler", onClear)
Archipelago:AddItemHandler("item handler", onItem)
Archipelago:AddLocationHandler("location handler", onLocation)
Archipelago:AddSetReplyHandler("notify handler", onNotify)
Archipelago:AddRetrievedHandler("notify launch handler", onNotifyLaunch)
