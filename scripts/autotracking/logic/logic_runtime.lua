-- Hand-ported logic runtime, mirroring worlds/mm_2ship/LogicRuntime.py.
-- This is the one piece NOT machine-transpiled (see tools/genlogic_lua/) --
-- ports the region-graph BFS + time-slice fixpoint + event fixpoint, and the
-- ~60 primitive methods every generated rule calls as `s:method(...)`.
--
-- Requires LOGIC_HELPERS (logic_helpers_gen.lua), LOGIC_REGIONS/LOGIC_START_REGION
-- (region_data.lua), LOGIC_OPTIONS_TABLE (option_data.lua) to already be loaded.
--
-- KNOWN GAP vs the Python original: `disabled_check_vanilla` self-granting
-- (options-disabled checks like unshuffled shops/frogs handing out their
-- vanilla item during the solve) is not yet ported. Every other piece of
-- Solver.solve() is a faithful line-for-line port.

local TIME_SLICE_COUNT = 45
local TIME_ALL_SLICES = (1 << TIME_SLICE_COUNT) - 1

local RO_CLOCK_SHUFFLE_RANDOM = 0
local RO_CLOCK_SHUFFLE_ASCENDING = 1
local RO_CLOCK_SHUFFLE_DESCENDING = 2
local RO_DUNGEON_ITEM_START_WITH = 2
local STRAY_FAIRY_SCATTERED_TOTAL = 15
local RO_ACCESS_DUNGEONS_FORM_AND_SONG = 0
local RO_ACCESS_DUNGEONS_FORM_OR_SONG = 1
local RO_ACCESS_DUNGEONS_FORM_ONLY = 2
local RO_ACCESS_DUNGEONS_SONG_ONLY = 3
local RO_ACCESS_DUNGEONS_OPEN = 4

-- Per-dungeon access requirements for CanAccessDungeon (hand port; mirrors
-- LogicRuntime.py's _DUNGEON_ACCESS).
local DUNGEON_ACCESS = {
  DUNGEON_SCENE_INDEX_WOODFALL_TEMPLE  = { "SONATA", "ITEM_MASK_DEKU" },
  DUNGEON_SCENE_INDEX_SNOWHEAD_TEMPLE  = { "LULLABY", "ITEM_MASK_GORON" },
  DUNGEON_SCENE_INDEX_GREAT_BAY_TEMPLE = { "BOSSA_NOVA", "ITEM_MASK_ZORA" },
}

local OCARINA_BUTTON_FLAGS = {
  "RANDO_INF_OBTAINED_OCARINA_BUTTON_A",
  "RANDO_INF_OBTAINED_OCARINA_BUTTON_C_DOWN",
  "RANDO_INF_OBTAINED_OCARINA_BUTTON_C_RIGHT",
  "RANDO_INF_OBTAINED_OCARINA_BUTTON_C_LEFT",
  "RANDO_INF_OBTAINED_OCARINA_BUTTON_C_UP",
}

-- Item RI-key -> AP display name, resolved once here for the handful of
-- items Solver/LogicContext reference by identity (mirrors `_item(key)` in
-- the Python original). Source: ItemData.py (regenerate this block if the
-- apworld renames any of these).
local ITEM_NAME = {
  PROGRESSIVE_SWORD = "Progressive Sword",
  PROGRESSIVE_WALLET = "Progressive Wallet",
  TIME_PROGRESSIVE = "Progressive Time",
  SKELETON_KEY = "Skeleton Key",
  HEART_CONTAINER = "Heart Container",
  HEART_PIECE = "Heart Piece",
  SINGLE_MAGIC = "Power of Magic",
  DOUBLE_MAGIC = "Magic Upgrade",
  PROGRESSIVE_MAGIC = "Progressive Magic",
  SWORD_KOKIRI = "Kokiri Sword",
  SWORD_RAZOR = "Razor Sword",
  SWORD_GILDED = "Gilded Sword",
  WALLET_ADULT = "Adult's Wallet",
  WALLET_GIANT = "Giant's Wallet",
  WALLET_TYCOON = "Tycoon's Wallet",
  TIME_DAY_1 = "Time (Day 1)",
  TIME_NIGHT_1 = "Time (Night 1)",
  TIME_DAY_2 = "Time (Day 2)",
  TIME_NIGHT_2 = "Time (Night 2)",
  TIME_DAY_3 = "Time (Day 3)",
  TIME_NIGHT_3 = "Time (Night 3)",
  PROGRESSIVE_LULLABY = "Progressive Goron Lullaby",
  ABILITY_SWIM = "Ability to Swim",
  SONG_DOUBLE_TIME = "Song of Double Time",
  SONG_INVERTED_TIME = "Inverted Song of Time",
  SONG_TIME = "Song of Time",
  SHIELD_HERO = "Hero's Shield",
  OCARINA = "Ocarina of Time",
  MASK_BUNNY = "Bunny Hood",
  DEKU_STICK = "Deku Stick",
  DEKU_NUT = "Deku Nut",
  GREAT_BAY_COMPASS = "Great Bay Compass",
  GREAT_BAY_MAP = "Great Bay Map",
  SNOWHEAD_COMPASS = "Snowhead Compass",
  SNOWHEAD_MAP = "Snowhead Map",
  STONE_TOWER_COMPASS = "Stone Tower Compass",
  STONE_TOWER_MAP = "Stone Tower Map",
  TINGLE_MAP_CLOCK_TOWN = "Tingle's Clock Town Map",
  TINGLE_MAP_GREAT_BAY = "Tingle's Great Bay Map",
  TINGLE_MAP_ROMANI_RANCH = "Tingle's Romani Ranch Map",
  TINGLE_MAP_SNOWHEAD = "Tingle's Snowhead Map",
  TINGLE_MAP_STONE_TOWER = "Tingle's Stone Tower Map",
  TINGLE_MAP_WOODFALL = "Tingle's Woodfall Map",
  WOODFALL_COMPASS = "Woodfall Compass",
  WOODFALL_MAP = "Woodfall Map",
  WOODFALL_SMALL_KEY = "Woodfall Small Key",
  SNOWHEAD_SMALL_KEY = "Snowhead Small Key",
  GREAT_BAY_SMALL_KEY = "Great Bay Small Key",
  STONE_TOWER_SMALL_KEY = "Stone Tower Small Key",
  WOODFALL_BOSS_KEY = "Woodfall Boss Key",
  SNOWHEAD_BOSS_KEY = "Snowhead Boss Key",
  GREAT_BAY_BOSS_KEY = "Great Bay Boss Key",
  STONE_TOWER_BOSS_KEY = "Stone Tower Boss Key",
  WOODFALL_STRAY_FAIRY = "Woodfall Stray Fairy",
  SNOWHEAD_STRAY_FAIRY = "Snowhead Stray Fairy",
  GREAT_BAY_STRAY_FAIRY = "Great Bay Stray Fairy",
  STONE_TOWER_STRAY_FAIRY = "Stone Tower Stray Fairy",
}

-- ============================================================================
-- LogicContext: evaluation context passed to every rule as `s`.
-- ============================================================================

local LogicContext = {}
LogicContext.__index = LogicContext

function LogicContext.new(solver, counts)
  local self = setmetatable({}, LogicContext)
  self.solver = solver
  self.counts = counts
  self.time = 0
  self.events = {}
  self._owned_time = nil
  return self
end

function LogicContext:count(item_name)
  return self.counts[item_name] or 0
end

function LogicContext:_any(item_names)
  for _, name in ipairs(item_names) do
    if (self.counts[name] or 0) ~= 0 then
      return true
    end
  end
  return false
end

-- HAS_ITEM(ITEM_X): does the inventory slot for ITEM_X hold it?
function LogicContext:has_item(item_const)
  return self:_any(LOGIC_HELPERS.ITEM_TO_ITEMS[item_const] or {})
end

function LogicContext:has_magic()
  return self:_any(self.solver.magic_items)
end

function LogicContext:has_bottle()
  return self:_any(LOGIC_HELPERS.BOTTLE_ITEMS)
end

function LogicContext:bottle_item(item_const)
  error("HAS_BOTTLE_ITEM(" .. tostring(item_const) .. ") has no runtime implementation yet")
end

function LogicContext:is_form(form)
  -- Logic solves from a fresh save: Link is human.
  return form == "HUMAN"
end

function LogicContext:player_form()
  return 4 -- PLAYER_FORM_HUMAN
end

function LogicContext:equip_value(equip_type)
  if equip_type == "EQUIP_TYPE_SWORD" then
    local tier = math.min(3, self:count(self.solver.progressive_sword))
    for _, pair in ipairs(self.solver.direct_sword_tiers) do
      local name, direct_tier = pair[1], pair[2]
      if (self.counts[name] or 0) ~= 0 then
        tier = math.max(tier, direct_tier)
      end
    end
    return tier
  end
  if equip_type == "EQUIP_TYPE_SHIELD" then
    if self:_any(LOGIC_HELPERS.ITEM_TO_ITEMS["ITEM_SHIELD_MIRROR"] or {}) then
      return 2
    end
    if self:_any(LOGIC_HELPERS.ITEM_TO_ITEMS["ITEM_SHIELD_HERO"] or {}) then
      return 1
    end
    return 0
  end
  error("equip_value(" .. tostring(equip_type) .. ") not implemented")
end

function LogicContext:upg_value(upg)
  if upg == "UPG_WALLET" then
    local tier = math.min(3, self:count(self.solver.progressive_wallet))
    for _, pair in ipairs(self.solver.direct_wallet_tiers) do
      local name, direct_tier = pair[1], pair[2]
      if (self.counts[name] or 0) ~= 0 then
        tier = math.max(tier, direct_tier)
      end
    end
    return tier
  end
  error("upg_value(" .. tostring(upg) .. ") not implemented")
end

function LogicContext:max_hp(target)
  local capacity = self.solver.starting_health
    + self:count(self.solver.heart_container)
    + self:count(self.solver.heart_piece) // 4
  return capacity >= target
end

-- -- flags / events / options ------------------------------------------------

function LogicContext:rando_inf(flag)
  return self:_any(LOGIC_HELPERS.RANDO_INF_TO_ITEMS[flag] or {})
end

function LogicContext:weekeventreg(reg)
  return self:_any(LOGIC_HELPERS.WEEKEVENTREG_TO_ITEMS[reg] or {})
end

function LogicContext:event(re_name)
  return self.events[re_name] or 0
end

function LogicContext:can_access(access)
  return self.events["RE_ACCESS_" .. access] or 0
end

function LogicContext:opt(ro_name)
  return self.solver.options[ro_name] or 0
end

function LogicContext:ability(name)
  return self:rando_inf("RANDO_INF_OBTAINED_" .. name)
end

function LogicContext:have_enemy_soul(actor)
  local item = LOGIC_HELPERS.ACTOR_TO_SOUL_ITEM[actor]
  if item == nil then
    return true -- no soul exists for this enemy -> treated as obtained
  end
  return (self.counts[item] or 0) ~= 0
end

function LogicContext:owl_warp(owl)
  if not (self:opt("RO_SHUFFLE_OWL_STATUES") ~= 0) then
    return false
  end
  return self:_any(LOGIC_HELPERS.OWL_WARP_TO_ITEMS[owl] or {})
end

-- -- songs ---------------------------------------------------------------------

function LogicContext:quest_item(quest)
  if self:_any(LOGIC_HELPERS.QUEST_TO_ITEMS[quest] or {}) then
    return true
  end
  local prog = self.solver.progressive_quest_grants[quest]
  if prog ~= nil then
    local name, needed = prog[1], prog[2]
    return self:count(name) >= needed
  end
  return false
end

function LogicContext:found_ocarina_buttons()
  local n = 0
  for _, flag in ipairs(OCARINA_BUTTON_FLAGS) do
    if self:rando_inf(flag) then n = n + 1 end
  end
  return n
end

function LogicContext:can_play_notes(ocarina_song)
  local req = LOGIC_HELPERS.SONG_NOTE_REQS[ocarina_song]
  if req == nil then
    return true -- canPlaySong's default case
  end
  local kind, payload = req[1], req[2]
  if kind == "all" then
    for _, flag in ipairs(payload) do
      if not self:rando_inf(flag) then return false end
    end
    return true
  end
  if kind == "count" then
    return self:found_ocarina_buttons() >= payload
  end
  return true
end

function LogicContext:can_play_song(song)
  -- CAN_PLAY_SONG(song): ocarina + quest song + enough buttons.
  local quest = "QUEST_SONG_" .. song
  return self:has_item("ITEM_OCARINA_OF_TIME")
    and self:quest_item(quest)
    and self:can_play_notes(LOGIC_HELPERS.QUEST_TO_OCARINA[quest])
end

function LogicContext:can_use_magic_arrow(arrow)
  return self:has_item("ITEM_BOW")
    and self:has_item("ITEM_ARROW_" .. arrow)
    and self:has_magic()
end

-- -- dungeons ------------------------------------------------------------------

local function dungeon_key(dungeon_const)
  return (dungeon_const:gsub("^DUNGEON_SCENE_INDEX_", ""))
end

function LogicContext:key_count(dungeon)
  if (self.counts[self.solver.skeleton_key] or 0) ~= 0 then
    return 99 -- Skeleton Key grants max keys for every dungeon
  end
  local info = LOGIC_HELPERS.DUNGEON_ITEMS[dungeon_key(dungeon)]
  return self:count(info.small_key)
end

function LogicContext:dungeon_item(kind, dungeon_const)
  local info = LOGIC_HELPERS.DUNGEON_ITEMS[dungeon_key(dungeon_const)]
  if kind == "DUNGEON_BOSS_KEY" then
    return (self.counts[info.boss_key] or 0) ~= 0
  end
  error("dungeon_item(" .. tostring(kind) .. ") not implemented")
end

function LogicContext:enough_stray_fairies(dungeon_const)
  local info = LOGIC_HELPERS.DUNGEON_ITEMS[dungeon_key(dungeon_const)]
  return self:count(info.stray_fairy) >= self:opt("RO_STRAY_FAIRIES_REQUIRED")
end

function LogicContext:enough_skull_tokens(scene)
  local total = 0
  for _, n in ipairs(LOGIC_HELPERS.TOKEN_SCENE_TO_ITEMS[scene] or {}) do
    total = total + self:count(n)
  end
  return total >= self:opt("RO_SKULLTULA_TOKENS_REQUIRED")
end

function LogicContext:can_access_dungeon(dungeon_const)
  local access = DUNGEON_ACCESS[dungeon_const]
  local song, form_mask = nil, nil
  if access then song, form_mask = access[1], access[2] end
  local has_song = song and self:can_play_song(song) or false
  local has_form = form_mask and (self:has_item(form_mask) and self:has_item("ITEM_OCARINA_OF_TIME")) or false
  local mode = self:opt("RO_ACCESS_DUNGEONS")
  if mode == RO_ACCESS_DUNGEONS_FORM_OR_SONG then
    return has_song or has_form
  end
  if mode == RO_ACCESS_DUNGEONS_FORM_ONLY then
    return has_form
  end
  if mode == RO_ACCESS_DUNGEONS_SONG_ONLY then
    return has_song
  end
  if mode == RO_ACCESS_DUNGEONS_OPEN then
    return true
  end
  return has_song and has_form
end

-- -- shops -----------------------------------------------------------------------

function LogicContext:can_afford(rc_name)
  local key = rc_name
  if key:sub(1, 3) ~= "RC_" then
    key = "RC_" .. key
  end
  local price = self.solver.shop_prices[key] or 0
  if price < 100 then
    return true
  end
  local wallet = self:upg_value("UPG_WALLET")
  if price <= 200 then
    return wallet >= 1
  end
  return wallet >= 2
end

-- -- moon -------------------------------------------------------------------------

function LogicContext:moon_mask_count()
  local n = 0
  for _, name in ipairs(LOGIC_HELPERS.MOON_MASK_ITEMS) do
    if (self.counts[name] or 0) ~= 0 then n = n + 1 end
  end
  return n
end

function LogicContext:remains_count()
  local n = 0
  for _, name in ipairs(LOGIC_HELPERS.REMAINS_ITEMS) do
    if (self.counts[name] or 0) ~= 0 then n = n + 1 end
  end
  return n
end

-- -- clock / time ---------------------------------------------------------------------

function LogicContext:setting_clocks()
  return self:opt("RO_CLOCK_SHUFFLE") ~= 0
end

function LogicContext:clock_count()
  local total = 0
  for _, name in ipairs(self.solver.clock_items) do
    if (self.counts[name] or 0) ~= 0 then total = total + 1 end
  end
  total = total + self:count(self.solver.progressive_clock)
  return math.min(6, total)
end

-- Logic.h OwnsClockHalfDay: is this specific half-day's clock owned?
function LogicContext:owns_clock_half_day(half_day)
  if half_day < 0 or half_day > 5 then
    return false
  end
  return (self.counts[self.solver.clock_items[half_day + 1]] or 0) ~= 0
end

-- Logic.h OwnsHalfDayForMode.
function LogicContext:owns_half_day(half_day)
  if not self:setting_clocks() or half_day < 0 or half_day > 5 then
    return not self:setting_clocks()
  end
  local mode = self:opt("RO_CLOCK_SHUFFLE_PROGRESSIVE")
  if mode == RO_CLOCK_SHUFFLE_RANDOM then
    return self:owns_clock_half_day(half_day)
  end
  local total = self:clock_count()
  if mode == RO_CLOCK_SHUFFLE_ASCENDING then
    return total > half_day
  end
  if mode == RO_CLOCK_SHUFFLE_DESCENDING then
    return total > (5 - half_day)
  end
  return false
end

-- TimeLogic.cpp GetOwnedTimeSlices (mode-aware via owns_half_day).
function LogicContext:owned_time_slices()
  if self._owned_time ~= nil then
    return self._owned_time
  end
  local mask
  if not self:setting_clocks() then
    mask = TIME_ALL_SLICES
  else
    mask = 0
    for i, range in ipairs(LOGIC_HELPERS.HALF_DAY_TIME_RANGES) do
      if self:owns_half_day(i - 1) then
        for s = range[1], range[2] do
          mask = mask | (1 << s)
        end
      end
    end
    if mask == 0 then
      mask = 1 -- Day 1 6:00 AM
    end
  end
  self._owned_time = mask
  return mask
end

function LogicContext:is_time_slice_owned(s)
  if not self:setting_clocks() then
    return true
  end
  for i, range in ipairs(LOGIC_HELPERS.HALF_DAY_TIME_RANGES) do
    if range[1] <= s and s <= range[2] then
      return self:owns_half_day(i - 1)
    end
  end
  return false
end

function LogicContext:raw_at(s)
  return (self.time & (1 << s)) ~= 0
end

function LogicContext:raw_before(s)
  if s == 0 then
    return false
  end
  return (self.time & ((1 << s) - 1)) ~= 0
end

function LogicContext:raw_after(s)
  return (self.time & ~((1 << s) - 1) & TIME_ALL_SLICES) ~= 0
end

function LogicContext:raw_between(start, stop)
  local mask = ((1 << stop) - 1) & ~((1 << start) - 1)
  return (self.time & mask) ~= 0
end

-- AT/BEFORE/AFTER/BETWEEN macros: Raw* && ClockFilter() (generated helper).
function LogicContext:time_at(s)
  return self:raw_at(s) and LOGIC_HELPERS.ClockFilter(self)
end

function LogicContext:time_before(s)
  return self:raw_before(s) and LOGIC_HELPERS.ClockFilter(self)
end

function LogicContext:time_after(s)
  return self:raw_after(s) and LOGIC_HELPERS.ClockFilter(self)
end

function LogicContext:time_between(start, stop)
  return self:raw_between(start, stop) and LOGIC_HELPERS.ClockFilter(self)
end

-- ============================================================================
-- Solver: per-world reachability solver over LOGIC_REGIONS.
-- ============================================================================

local Solver = {}
Solver.__index = Solver

-- `options`: table RO_KEY -> int value (already resolved from slot_data by
-- the caller -- see logic_bridge.lua). `shop_prices`: table RC_* -> int
-- (straight from slot_data.shop_prices).
function Solver.new(options, shop_prices)
  local self = setmetatable({}, Solver)
  self.options = options
  self.shop_prices = shop_prices or {}
  self.starting_health = options["RO_STARTING_HEALTH"] or 3

  self.progressive_sword = ITEM_NAME.PROGRESSIVE_SWORD
  self.progressive_wallet = ITEM_NAME.PROGRESSIVE_WALLET
  self.progressive_clock = ITEM_NAME.TIME_PROGRESSIVE
  self.skeleton_key = ITEM_NAME.SKELETON_KEY
  self.heart_container = ITEM_NAME.HEART_CONTAINER
  self.heart_piece = ITEM_NAME.HEART_PIECE
  self.magic_items = { ITEM_NAME.SINGLE_MAGIC, ITEM_NAME.DOUBLE_MAGIC, ITEM_NAME.PROGRESSIVE_MAGIC }
  self.direct_sword_tiers = {
    { ITEM_NAME.SWORD_KOKIRI, 1 }, { ITEM_NAME.SWORD_RAZOR, 2 }, { ITEM_NAME.SWORD_GILDED, 3 },
  }
  self.direct_wallet_tiers = {
    { ITEM_NAME.WALLET_ADULT, 1 }, { ITEM_NAME.WALLET_GIANT, 2 }, { ITEM_NAME.WALLET_TYCOON, 3 },
  }
  self.clock_items = {
    ITEM_NAME.TIME_DAY_1, ITEM_NAME.TIME_NIGHT_1, ITEM_NAME.TIME_DAY_2,
    ITEM_NAME.TIME_NIGHT_2, ITEM_NAME.TIME_DAY_3, ITEM_NAME.TIME_NIGHT_3,
  }
  self.progressive_quest_grants = {
    QUEST_SONG_LULLABY = { ITEM_NAME.PROGRESSIVE_LULLABY, 2 },
    QUEST_SONG_LULLABY_INTRO = { ITEM_NAME.PROGRESSIVE_LULLABY, 1 },
  }

  self.starting_counts = self:_compute_starting_items()
  self._memo = {}
  return self
end

-- Port of GrantStartingItems (the IS_ARCHI branch of GetComputedStartingItems,
-- plus what GrantStartingItems adds on top). NOTE: does not yet include the
-- disabled_check_vanilla self-granting system (see file header).
function Solver:_compute_starting_items()
  local opts = self.options
  local start = {}
  local function give(name, n)
    n = n or 1
    start[name] = (start[name] or 0) + n
  end
  local function opt_on(key)
    return (opts[key] or 0) ~= 0
  end

  if opt_on("RO_STARTING_MAPS_AND_COMPASSES") then
    for _, key in ipairs({
      "GREAT_BAY_COMPASS", "GREAT_BAY_MAP", "SNOWHEAD_COMPASS", "SNOWHEAD_MAP",
      "STONE_TOWER_COMPASS", "STONE_TOWER_MAP", "TINGLE_MAP_CLOCK_TOWN",
      "TINGLE_MAP_GREAT_BAY", "TINGLE_MAP_ROMANI_RANCH", "TINGLE_MAP_SNOWHEAD",
      "TINGLE_MAP_STONE_TOWER", "TINGLE_MAP_WOODFALL", "WOODFALL_COMPASS", "WOODFALL_MAP",
    }) do
      give(ITEM_NAME[key])
    end
  end
  if opts["RO_PLACEMENT_SMALL_KEYS"] == RO_DUNGEON_ITEM_START_WITH then
    give(ITEM_NAME.WOODFALL_SMALL_KEY, 1)
    give(ITEM_NAME.SNOWHEAD_SMALL_KEY, 3)
    give(ITEM_NAME.GREAT_BAY_SMALL_KEY, 1)
    give(ITEM_NAME.STONE_TOWER_SMALL_KEY, 4)
  end
  if opts["RO_PLACEMENT_BOSS_KEYS"] == RO_DUNGEON_ITEM_START_WITH then
    for _, key in ipairs({ "WOODFALL_BOSS_KEY", "SNOWHEAD_BOSS_KEY", "GREAT_BAY_BOSS_KEY", "STONE_TOWER_BOSS_KEY" }) do
      give(ITEM_NAME[key])
    end
  end
  if opts["RO_PLACEMENT_STRAY_FAIRIES"] == RO_DUNGEON_ITEM_START_WITH then
    for _, key in ipairs({ "WOODFALL_STRAY_FAIRY", "SNOWHEAD_STRAY_FAIRY", "GREAT_BAY_STRAY_FAIRY", "STONE_TOWER_STRAY_FAIRY" }) do
      give(ITEM_NAME[key], STRAY_FAIRY_SCATTERED_TOTAL)
    end
  end
  if not opt_on("RO_SHUFFLE_SWIM") then give(ITEM_NAME.ABILITY_SWIM) end
  if not opt_on("RO_SHUFFLE_ENEMY_SOULS") then
    local seen = {}
    for _, name in pairs(LOGIC_HELPERS.ACTOR_TO_SOUL_ITEM) do
      if not seen[name] then
        seen[name] = true
        give(name)
      end
    end
  end
  if not opt_on("RO_SHUFFLE_OCARINA_BUTTONS") then
    for _, flag in ipairs(OCARINA_BUTTON_FLAGS) do
      for _, name in ipairs(LOGIC_HELPERS.RANDO_INF_TO_ITEMS[flag] or {}) do
        give(name)
      end
    end
  end
  if not opt_on("RO_SHUFFLE_SONG_DOUBLE_TIME") then give(ITEM_NAME.SONG_DOUBLE_TIME) end
  if not opt_on("RO_SHUFFLE_SONG_INVERTED_TIME") then give(ITEM_NAME.SONG_INVERTED_TIME) end
  if not opt_on("RO_SHUFFLE_SONG_TIME") then give(ITEM_NAME.SONG_TIME) end
  if not opt_on("RO_SHUFFLE_SWORD") then give(ITEM_NAME.PROGRESSIVE_SWORD) end
  if not opt_on("RO_SHUFFLE_SHIELD") then give(ITEM_NAME.SHIELD_HERO) end
  if not opt_on("RO_SHUFFLE_OCARINA") then give(ITEM_NAME.OCARINA) end
  if opt_on("RO_STARTING_BUNNY_HOOD") then give(ITEM_NAME.MASK_BUNNY) end
  if opt_on("RO_STARTING_CONSUMABLES") then
    give(ITEM_NAME.DEKU_STICK)
    give(ITEM_NAME.DEKU_NUT)
  end
  return start
end

-- -- time expansion (port of TimeLogic.cpp) ---------------------------------

local function forward_fill(mask)
  mask = mask | (mask << 1)
  mask = mask | (mask << 2)
  mask = mask | (mask << 4)
  mask = mask | (mask << 8)
  mask = mask | (mask << 16)
  mask = mask | (mask << 32)
  return mask & TIME_ALL_SLICES
end

function Solver:expand_time_forward(ctx, time_mask, spec)
  if (#spec.stays == 0) and not ctx:setting_clocks() then
    return forward_fill(time_mask)
  end

  local filtered = time_mask
  if ctx:setting_clocks() then
    filtered = filtered & ctx:owned_time_slices()
  end

  local stays = {}
  for _, entry in ipairs(spec.stays) do
    stays[entry.time_slice] = entry.rule
  end

  local expanded = filtered
  local can_wait = false
  for i = 0, TIME_SLICE_COUNT - 1 do
    local bit = 1 << i
    if (filtered & bit) ~= 0 then
      can_wait = true
      expanded = expanded | bit
    elseif can_wait then
      if ctx:setting_clocks() and not ctx:is_time_slice_owned(i) then
        can_wait = false
      else
        local rule = stays[i]
        if rule ~= nil then
          if rule(ctx) then
            expanded = expanded | bit
          else
            can_wait = false -- kicked out; expansion stops
          end
        else
          expanded = expanded | bit
        end
      end
    end
  end
  return expanded
end

-- -- main fixpoint (port of GlitchlessLogic.cpp reachability core) ----------

local function propagate(regions, can_stay, work, target, incoming)
  local existing = regions[target]
  if existing == nil then
    regions[target] = incoming
    can_stay[target] = LOGIC_REGIONS[target].can_stay
    work[#work + 1] = target
  elseif (existing | incoming) ~= existing then
    regions[target] = existing | incoming
    work[#work + 1] = target
  end
end

-- Sentinel memo value for a signature that has already hit PopTracker's
-- rule execution limit once (see Solver:solve below) -- distinct from any
-- real result table or from a plain `nil` (no memo entry yet).
local SOLVE_FAILED = {}

-- counts: table item_name -> count (already merged with starting_counts by
-- the caller -- see Solver:solve_from_inventory below for the usual entry
-- point). Returns { regions = {...}, events = {...}, checks = {[rc]=true} },
-- or nil if this exact inventory signature hit PopTracker's rule execution
-- limit (see the pcall below).
function Solver:solve(counts)
  -- memo key: sorted "name=count" pairs for every nonzero entry.
  local sig_parts = {}
  for k, v in pairs(counts) do
    if v ~= 0 then sig_parts[#sig_parts + 1] = k .. "=" .. tostring(v) end
  end
  table.sort(sig_parts)
  local sig = table.concat(sig_parts, "\1")
  local hit = self._memo[sig]
  if hit ~= nil then
    if hit == SOLVE_FAILED then
      return nil
    end
    return hit
  end

  -- PopTracker enforces a configurable per-call rule execution limit
  -- ("override_rule_exec_limit" in its settings); a solver this size can hit
  -- it under PopTracker's default budget (raising that setting is the real
  -- fix -- this pcall is a safety net, not a substitute for that). Hitting
  -- it surfaces as a normal, catchable Lua error ("Execution aborted. Limit
  -- reached." from this function) -- without this pcall, a signature that
  -- hits a too-low limit once would get retried (and fail again) on every
  -- subsequent $LOGIC_REACHABLE call for ANY location, since a failed call
  -- never reaches the line that would normally cache it, so nothing about
  -- the failure is ever remembered. Memoizing the failure itself turns
  -- "retried and re-aborted on every call" into "aborts once per distinct
  -- signature".
  local ok, result = pcall(self._solve_uncached, self, counts, sig)
  if not ok then
    self._memo[sig] = SOLVE_FAILED
    return nil
  end
  return result
end

function Solver:_solve_uncached(counts, sig)
  local ctx = LogicContext.new(self, counts)

  local regions = {}
  local can_stay = {}

  local start_mask
  if ctx:setting_clocks() then
    start_mask = ctx:owned_time_slices()
  else
    start_mask = 1 -- Day 1, 6:00 AM
  end
  regions[LOGIC_START_REGION] = start_mask
  can_stay[LOGIC_START_REGION] = false -- InitialTimeState / InitializeRegionTimeStates

  local fired_events = {} -- "region\1index" -> true
  local events_changed = true
  while events_changed do
    -- region/time fixpoint with the current event counters
    local work = {}
    for rid in pairs(regions) do work[#work + 1] = rid end
    while #work > 0 do
      local rid = table.remove(work)
      local spec = LOGIC_REGIONS[rid]
      local cur = regions[rid]
      if can_stay[rid] then
        local new_cur = self:expand_time_forward(ctx, cur, spec)
        if new_cur ~= cur then
          regions[rid] = new_cur
          cur = new_cur
        end
      end

      ctx.time = cur
      for _, edge in ipairs(spec.connections) do
        if edge.rule(ctx) then
          propagate(regions, can_stay, work, edge.key, cur)
        end
      end
      for _, edge in ipairs(spec.exits) do
        if edge.rule(ctx) then
          propagate(regions, can_stay, work, edge.key, cur)
        end
      end
    end

    -- event pass: each region's EVENT() instance increments its counter
    -- once, mirroring GlitchlessLogic's RANDO_EVENTS[event]++.
    events_changed = false
    for rid, mask in pairs(regions) do
      ctx.time = mask
      for idx, entry in ipairs(LOGIC_REGIONS[rid].events) do
        local key = rid .. "\1" .. idx
        if not fired_events[key] and entry.rule(ctx) then
          fired_events[key] = true
          ctx.events[entry.key] = (ctx.events[entry.key] or 0) + 1
          events_changed = true
        end
      end
    end
  end

  local checks = {}
  for rid, mask in pairs(regions) do
    ctx.time = mask
    for _, entry in ipairs(LOGIC_REGIONS[rid].checks) do
      if not checks[entry.key] and entry.rule(ctx) then
        checks[entry.key] = true
      end
    end
  end

  local result = { regions = regions, events = ctx.events, checks = checks }
  self._memo[sig] = result
  return result
end

-- Convenience entry point: merges starting_counts with the AP-received
-- inventory (item display name -> count) and solves.
function Solver:solve_from_inventory(received_counts)
  local merged = {}
  for k, v in pairs(self.starting_counts) do merged[k] = v end
  for k, v in pairs(received_counts) do
    merged[k] = (merged[k] or 0) + v
  end
  return self:solve(merged)
end

LOGIC_RUNTIME = {
  LogicContext = LogicContext,
  Solver = Solver,
}
