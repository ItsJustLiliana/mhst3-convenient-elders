local logMsgStart = "[Convenient Elders] "

local initialized = false
local config_path = "convenient_elders_config.json"

local defaults = {
  modEnabled = false,
  elderBaseSpawnChance = 10,
  elderDespawnBattleCount = 5
}

local config = {
  modEnabled = false,           -- Whether mod (features) should be enabled (disabled by default)
  elderBaseSpawnChance = 10,    -- The base appearance rate of a calamitous elder dragon as percentage (0 - 100, default: 10)
  elderDespawnBattleCount = 5   -- How many battles until calamitous elder goes away (default: 5)
}

--- Valid stage IDs for where calamitous elders can spawn;
--- Could probably also check with `app.cSaveDataHelper_Field.isOpenMap(app.StageDef.StageID_Fixed)`
local validStageIDs = {
  1769129856,  -- Azuria
  884165440,   -- Canalta Timberland
  1834912896,  -- Tarkuan
  1491992832   -- Serathis
}

local stageIDNone = 4117922480  -- If no elders, set it to this value (app.StageDef.StageID_Fixed.None / -177044816 if properly converted to int32)

-- Preferred Catavan destination for each elder area.
-- Values come from the game's NekoTaxiTable user data.
local elderAreaCatavan = {
  [1769129856] = { -- Azuria
    name = "Mirror Lake",
    nekoTaxiId = 260838448
  },
  [884165440] = { -- Canalta Timberland
    name = "Mt. Canalta",
    nekoTaxiId = 1880851584
  },
  [1834912896] = { -- Tarkuan
    name = "Camp: Colossal Dragon's Remains",
    nekoTaxiId = 2004
  },
  [1491992832] = { -- Serathis
    name = "Glacial Caps: Coastline",
    nekoTaxiId = 1498
  }
}

local stageManager = nil
local fieldElderController = nil
local fieldElderUserData = nil
local setPopElderStageIdMethod = nil
local lastKnownElderStageId = stageIDNone
local lastManualSpawnError = nil
local lastManualSpawnMessage = nil
local lastManualSpawnMessageUntil = 0
local originalBasePopRate = nil
local originalElderEndBattleCount = nil

---Loads config while keeping defaults for missing/invalid fields.
local function load_config()
  local saved = json.load_file(config_path)
  if type(saved) ~= "table" then
    return
  end

  if type(saved.modEnabled) == "boolean" then
    config.modEnabled = saved.modEnabled
  end

  if type(saved.elderBaseSpawnChance) == "number" then
    config.elderBaseSpawnChance = math.max(0, math.min(100, math.floor(saved.elderBaseSpawnChance)))
  end

  if type(saved.elderDespawnBattleCount) == "number" then
    config.elderDespawnBattleCount = math.max(1, math.min(10, math.floor(saved.elderDespawnBattleCount)))
  end
end

---Saves current config
local function save_config()
  json.dump_file(config_path, config)
end

---Applies the configured natural elder spawn rate to the game.
---The manual spawn button no longer changes this value.
local function apply_spawn_rate()
  if fieldElderUserData then
    fieldElderUserData:set_field("BasePopRate", config.elderBaseSpawnChance)
  end
end

---Applies or restores the elder field settings for the mod toggle.
---@param enabled boolean
local function handle_mod_enable_toggle(enabled)
  if not fieldElderUserData then
    log.error(logMsgStart .. "'app.StageManager._FieldElderCtrl._FieldElderParamUserData' is null; cannot set field values")
    return
  end

  if enabled then
    apply_spawn_rate()
    fieldElderUserData:set_field("ElderEndBattleCount", config.elderDespawnBattleCount)
  else
    if originalBasePopRate ~= nil then
      fieldElderUserData:set_field("BasePopRate", originalBasePopRate)
    end

    if originalElderEndBattleCount ~= nil then
      fieldElderUserData:set_field("ElderEndBattleCount", originalElderEndBattleCount)
    end
  end
end

---Checks a table if specified value exists
---@param t table
---@param val string|number
local function has_value(t, val)
  for index, value in ipairs(t) do
    if value == val then
      return true
    end
  end

  return false
end


---Returns the current valid elder area stage ID.
---If the player is in a temporary sub-area (for example an egg nest),
---fall back to the previous stage, matching the existing override behavior.
---@return number|nil
local function get_current_elder_area_stage_id()
  if not stageManager then
    return nil
  end

  local stage = stageManager:call("get_CurrentStageData()")
  local stageId = stage and stage:call("get_ID()") or nil

  if not stageId or not has_value(validStageIDs, stageId) then
    stage = stageManager:call("get_PrevStageData()")
    stageId = stage and stage:call("get_ID()") or nil
  end

  if stageId and has_value(validStageIDs, stageId) then
    return stageId
  end

  return nil
end

---Attempts to perform a normal Catavan fast-travel using the game's
---native StageManager fast-travel state.
---@param destination table
---@return boolean, string|nil
local function try_catavan_teleport_night(destination)
  if not destination then
    return false, "No Catavan destination configured for this area."
  end

  stageManager = sdk.get_managed_singleton("app.StageManager")
  if not stageManager then
    return false, "StageManager is unavailable."
  end

  local stageType = sdk.find_type_definition("app.StageManager")
  if not stageType then
    return false, "Could not find app.StageManager."
  end

  local setFastTravel = stageType:get_method(
    "set_FastTravel(app.NekoTaxiID.ID_Fixed)"
  ) or stageType:get_method("set_FastTravel")

  local setFastTravelTimeZone = stageType:get_method(
    "set_FastTravelTimeZone(app.StageDef.TIME_ZONE_Fixed)"
  ) or stageType:get_method("set_FastTravelTimeZone")

  local startFastTravel = stageType:get_method("startFastTravel()")
    or stageType:get_method("startFastTravel")

  if not setFastTravel or not setFastTravelTimeZone or not startFastTravel then
    return false, "Required native Catavan fast-travel methods are unavailable."
  end

  -- Runtime-confirmed app.StageDef.TIME_ZONE_Fixed.NIGHT
  local TIME_ZONE_NIGHT = 16317

  local ok, err = pcall(function()
    setFastTravel:call(stageManager, destination.nekoTaxiId)
    setFastTravelTimeZone:call(stageManager, TIME_ZONE_NIGHT)
    startFastTravel:call(stageManager)
  end)

  if not ok then
    return false, tostring(err)
  end

  log.info(
    logMsgStart ..
    "Native Catavan fast travel requested to " .. destination.name ..
    " (NekoTaxiID " .. tostring(destination.nekoTaxiId) ..
    ", TIME_ZONE_NIGHT " .. tostring(TIME_ZONE_NIGHT) .. ")"
  )

  return true, nil
end


local function spawn_elder_in_current_area()
  lastManualSpawnError = nil
  lastManualSpawnMessage = nil

  if not config.modEnabled then
    lastManualSpawnError = "Manual spawning is disabled."
    return false
  end

  local stageId = get_current_elder_area_stage_id()
  if not stageId then
    lastManualSpawnError = "No Elder can spawn in this area."
    return false
  end

  -- Spam protection: if this area's elder is already active, do nothing.
  if lastKnownElderStageId == stageId then
    return false
  end

  if not setPopElderStageIdMethod then
    lastManualSpawnError = "Could not spawn Elder."
    return false
  end

  local ok, err = pcall(function()
    setPopElderStageIdMethod:call(nil, stageId)
  end)

  if not ok then
    lastManualSpawnError = "Could not spawn Elder."
    log.error(logMsgStart .. "manual elder spawn failed: " .. tostring(err))
    return false
  end

  -- The hook below also records this, but set it here as a defensive lock
  -- so repeated button presses cannot queue duplicate requests.
  lastKnownElderStageId = stageId

  local destination = elderAreaCatavan[stageId]
  local warped, warpErr = try_catavan_teleport_night(destination)

  if warped then
    lastManualSpawnError = nil
    lastManualSpawnMessage =
      "Elder spawned. Travelling to " .. destination.name .. " at Night."
  else
    lastManualSpawnMessage =
      "Elder spawned, but fast travel failed."

    if warpErr then
      lastManualSpawnError = "Fast travel failed."
      log.error(logMsgStart .. warpErr)
    end
  end

  lastManualSpawnMessageUntil = os.clock() + 5.0

  log.info(logMsgStart .. "manually set elder spawn area to StageID_Fixed: " .. tostring(stageId))
  return true
end

--- Initialize singletons, config values, etc.
local function init()
  if initialized then
    return
  end

  load_config()

  stageManager = sdk.get_managed_singleton("app.StageManager")
  if not stageManager then
    log.error(logMsgStart .. "could not find 'app.StageManager'")
    return
  end

  fieldElderController = stageManager:get_field("_FieldElderCtrl")
  if not fieldElderController then
    log.error(logMsgStart .. "could not find 'app.StageManager._FieldElderCtrl'")
    return
  end

  fieldElderUserData = fieldElderController:get_field("_FieldElderParamUserData")
  if not fieldElderUserData then
    log.error(logMsgStart .. "could not find 'app.StageManager._FieldElderCtrl._FieldElderParamUserData'")
    return
  end

  setPopElderStageIdMethod = sdk.find_type_definition("app.cSaveDataHelper_Field"):get_method("setPopElderStageId(app.StageDef.StageID_Fixed)")
  if not setPopElderStageIdMethod then
    log.error(logMsgStart .. "could not find 'app.cSaveDataHelper_Field.setPopElderStageId(app.StageDef.StageID_Fixed)'")
  end

  originalBasePopRate = fieldElderUserData:get_field("BasePopRate")
  originalElderEndBattleCount = fieldElderUserData:get_field("ElderEndBattleCount")

  handle_mod_enable_toggle(config.modEnabled)

  initialized = true
end

---Adds a convenient tooltip before the actual menu entry
---@param msg string
local function pre_tooltip(msg)
  if msg == nil then
    msg = "(no tooltip)"
  end

  imgui.text("(?)")
  ---@diagnostic disable-next-line: missing-parameter
  if imgui.is_item_hovered() then
    imgui.set_tooltip("\n" .. msg .. "\n ")
    -- imgui.set_tooltip(msg)
  end
  imgui.same_line()
end

-- Mod init hook
sdk.hook(
  sdk.find_type_definition("app.SaveDataManager"):get_method("getTitleText()"),
  function(args)
    init()
  end,
  function(retval)
    return retval
  end
)

-- Track the game's elder state so the manual spawn button cannot be spammed
-- while the current area's elder is already active.
local elderHelperType = sdk.find_type_definition("app.cSaveDataHelper_Field")
local elderStageSetterForHook = elderHelperType and elderHelperType:get_method(
  "setPopElderStageId(app.StageDef.StageID_Fixed)"
) or nil

if elderStageSetterForHook then
  setPopElderStageIdMethod = elderStageSetterForHook

  sdk.hook(
    elderStageSetterForHook,
    function(args)
      local requestedStageId = sdk.to_int64(args[3])
      log.debug(logMsgStart .. "setPopElderStageId: " .. tostring(requestedStageId))
      lastKnownElderStageId = requestedStageId
      return sdk.PreHookResult.CALL_ORIGINAL
    end,
    function(retval)
      return retval
    end
  )
else
  log.error(logMsgStart .. "could not hook 'app.cSaveDataHelper_Field.setPopElderStageId(app.StageDef.StageID_Fixed)'")
end


-- init if resetting scripts (i.e., during development)
if not initialized then
  init()
end

re.on_draw_ui(function()
  if imgui.tree_node("Convenient Elders") then
    local modEnabledChanged, newModEnabled = imgui.checkbox("Enable", config.modEnabled)
    if modEnabledChanged then
      config.modEnabled = newModEnabled
      handle_mod_enable_toggle(newModEnabled)
      save_config()
    end

    if config.modEnabled then
      pre_tooltip("Natural Elder spawn chance. Default: 10%")
      ---@diagnostic disable-next-line: missing-parameter
      local elderBasePopRateChanged, newElderBasePopRate = imgui.slider_int("Base spawn rate (n %)", config.elderBaseSpawnChance, 0, 100)
      if elderBasePopRateChanged then
        config.elderBaseSpawnChance = newElderBasePopRate
        apply_spawn_rate()
        save_config()
      end

      pre_tooltip("Battles before the Elder retreats. Default: 5")
      ---@diagnostic disable-next-line: missing-parameter
      local elderEndBattleCountChanged, newElderEndBattleCount = imgui.slider_int("Battle retreat count", config.elderDespawnBattleCount, 1, 10)
      if elderEndBattleCountChanged then
        config.elderDespawnBattleCount = newElderEndBattleCount
        if fieldElderUserData then
          fieldElderUserData:set_field("ElderEndBattleCount", config.elderDespawnBattleCount)
        end
        save_config()
      end

      local currentElderAreaStageId = get_current_elder_area_stage_id()
      local elderAlreadyInCurrentArea =
        currentElderAreaStageId ~= nil and
        lastKnownElderStageId == currentElderAreaStageId

      if not config.modEnabled then
        imgui.text("Status: Manual spawning disabled.")
      elseif currentElderAreaStageId == nil then
        imgui.text("Status: No Elder can spawn in this area.")
      elseif elderAlreadyInCurrentArea then
        imgui.text("Status: Elder already active in this area.")
      else
        imgui.text("Status: Elder can spawn in this area.")

        if imgui.button("Spawn Elder") then
          spawn_elder_in_current_area()
        end
      end

      if lastManualSpawnError then
        imgui.text(lastManualSpawnError)
      end

      if lastManualSpawnMessage then
        if os.clock() <= lastManualSpawnMessageUntil then
          imgui.text(lastManualSpawnMessage)
        else
          lastManualSpawnMessage = nil
        end
      end
    end

    imgui.tree_pop()
  end
end)
