-- scripts/FarmersMarketRandom.lua
-- Randomly sells ALL stored products from this productionPoint's storage
-- at the current economy price each in-game hour.
--
-- Features:
--  * 3 presets (conservative / balanced / aggressive) with min/max % and opening hours
--    loaded from:
--      - Global:   modSettings/FarmMarketRandom/FarmMarketSettings.xml (auto-created)
--      - Per-save: savegame<index>/FarmMarketSettings.xml (optional, NOT auto-created)
--  * Presets can be cycled at the infoTrigger ("Change market sale rate")
--  * Market open / closed based on configured hours
--  * Sales are logged per savegame to FarmMarketSalesLog.csv in the savegame directory

FarmersMarketRandom = {}
local FarmersMarketRandom_mt = Class(FarmersMarketRandom, ProductionPoint)

----------------------------------------------------------------------
-- Activatable wrapper for the "press E" interaction
----------------------------------------------------------------------

FarmersMarketRandomConfigActivatable = {}
local FarmersMarketRandomConfigActivatable_mt = Class(FarmersMarketRandomConfigActivatable)

function FarmersMarketRandomConfigActivatable.new(farmersMarket)
    local self = setmetatable({}, FarmersMarketRandomConfigActivatable_mt)
    self.fm = farmersMarket
    self.activateText = g_i18n:getText("action_fmAdjustRates") or "Change market sale rate"
    self.priority = 1
    return self
end

function FarmersMarketRandomConfigActivatable:getIsActivatable()
    return self.fm ~= nil and self.fm.isPlayerInTrigger
end

function FarmersMarketRandomConfigActivatable:activate()
    if self.fm ~= nil then
        self.fm:cycleRandomSellPreset()
    end
end

function FarmersMarketRandomConfigActivatable:deactivate()
end

function FarmersMarketRandomConfigActivatable:drawActivate()
end

----------------------------------------------------------------------
-- FarmersMarketRandom main class
----------------------------------------------------------------------

function FarmersMarketRandom.new(isServer, isClient, customMt)
    local self = ProductionPoint.new(isServer, isClient, customMt or FarmersMarketRandom_mt)

    self.lastHour = nil
    self.randomMinPercent = 0.0   -- 0.0 .. 1.0
    self.randomMaxPercent = 0.3   -- 0.0 .. 1.0

    -- presets will be filled from config XML
    self.presets = {
        [1] = { id = 1, nameKey = "fmRandomSell_preset_conservative", minPercent = 2,  maxPercent = 8  },
        [2] = { id = 2, nameKey = "fmRandomSell_preset_balanced",     minPercent = 5,  maxPercent = 16 },
        [3] = { id = 3, nameKey = "fmRandomSell_preset_aggressive",   minPercent = 10, maxPercent = 25 }
    }
    self.currentPresetIndex = 2    -- start at Balanced

    -- opening hours (in-game, 0–23)
    self.openHour = 0
    self.closeHour = 24

    -- settings paths
    self.globalSettingsFilePath = nil
    self.savegameSettingsFilePath = nil

    -- sales log path (per savegame)
    self.salesLogFilePath = nil

    -- info trigger & activatable
    self.infoTriggerNode = nil
    self.isPlayerInTrigger = false
    self.activatable = nil

    return self
end

function FarmersMarketRandom:load(components, xmlFile, key, customEnvironment, i3dMappings)
    if not FarmersMarketRandom:superClass().load(self, components, xmlFile, key, customEnvironment, i3dMappings) then
        return false
    end

    -- 1) Load settings (global + optional per-save override)
    self:loadSettings()

    -- Apply preset 2 (Balanced) as starting point (values now from config)
    self:applyPreset(self.currentPresetIndex, false)

    -- 2) Compute sales log file path (per savegame)
    self.salesLogFilePath = self:getSalesLogFilePath()
    self:ensureSalesLogHeader()

    -- 3) Hook infoTrigger so we can cycle presets using E at the info marker
    if i3dMappings ~= nil and i3dMappings["infoTrigger"] ~= nil then
        self.infoTriggerNode = i3dMappings["infoTrigger"].node
    end

    if self.infoTriggerNode ~= nil then
        addTrigger(self.infoTriggerNode, "infoTriggerCallback", self)

        self.activatable = FarmersMarketRandomConfigActivatable.new(self)
        g_currentMission.activatableObjectsSystem:addActivatableObject(self.activatable)
    else
        Logging.warning("FarmersMarketRandom: infoTrigger node not found, configuration menu will not be available.")
    end

    if self.isServer then
        math.randomseed(g_time or os.time())
    end

    return true
end

function FarmersMarketRandom:delete()
    if self.infoTriggerNode ~= nil then
        removeTrigger(self.infoTriggerNode)
        self.infoTriggerNode = nil
    end

    if self.activatable ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatableObject(self.activatable)
        self.activatable = nil
    end

    FarmersMarketRandom:superClass().delete(self)
end

----------------------------------------------------------------------
-- Config file paths: global + per-save
----------------------------------------------------------------------

function FarmersMarketRandom:getBaseSettingsDir()
    local baseDir = g_modSettingsDirectory or (getUserProfileAppPath() .. "modSettings/")
    local dir = baseDir .. "FarmersMarketRandom/"
    createFolder(dir)
    return dir
end

function FarmersMarketRandom:getGlobalSettingsFilePath()
    return self:getBaseSettingsDir() .. "FarmersMarketSettings.xml"
end

function FarmersMarketRandom:getSavegameSettingsFilePath()
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        local index = g_currentMission.missionInfo.savegameIndex or 1
        local saveDir = string.format("%ssavegame%d/", getUserProfileAppPath(), index)
        return saveDir .. "FarmersMarketSettings.xml"
    end
    return nil
end

function FarmersMarketRandom:getSalesLogFilePath()
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        local index = g_currentMission.missionInfo.savegameIndex or 1
        local saveDir = string.format("%ssavegame%d/", getUserProfileAppPath(), index)
        return saveDir .. "FarmersMarketSalesLog.csv"
    end
    return nil
end

----------------------------------------------------------------------
-- Load settings: global (create if missing) + per-save (if exists)
----------------------------------------------------------------------

function FarmersMarketRandom:loadSettings()
    self.globalSettingsFilePath   = self:getGlobalSettingsFilePath()
    self.savegameSettingsFilePath = self:getSavegameSettingsFilePath()

    -- 1) Global (auto-create)
    if fileExists(self.globalSettingsFilePath) then
        self:loadSettingsFromFile(self.globalSettingsFilePath, false)
    else
        self:saveDefaultSettings(self.globalSettingsFilePath)
    end

    -- 2) Per-save override (only if file exists)
    if self.savegameSettingsFilePath ~= nil and fileExists(self.savegameSettingsFilePath) then
        self:loadSettingsFromFile(self.savegameSettingsFilePath, true)
        Logging.info("FarmersMarketRandom: Loaded per-save override '%s'", self.savegameSettingsFilePath)
    end
end

-- loadSettingsFromFile(path, isOverride)
-- isOverride = false -> base load (global)
-- isOverride = true  -> override values on top of whatever is already present
function FarmersMarketRandom:loadSettingsFromFile(path, isOverride)
    local xmlFile = loadXMLFile("farmersMarketSettings", path)

    if xmlFile == nil then
        Logging.warning("FarmersMarketRandom: Could not load settings file '%s'", path)
        return
    end

    -- Load presets
    local i = 0
    while true do
        local key = string.format("farmersMarketSettings.presets.preset(%d)", i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local id = getXMLInt(xmlFile, key .. "#id") or (i + 1)
        local minPercent = getXMLFloat(xmlFile, key .. "#minPercent")
        local maxPercent = getXMLFloat(xmlFile, key .. "#maxPercent")

        if self.presets[id] ~= nil then
            if minPercent ~= nil then
                self.presets[id].minPercent = minPercent
            elseif not isOverride then
                self.presets[id].minPercent = self.presets[id].minPercent or 5
            end

            if maxPercent ~= nil then
                self.presets[id].maxPercent = maxPercent
            elseif not isOverride then
                self.presets[id].maxPercent = self.presets[id].maxPercent or 16
            end
        end

        i = i + 1
    end

    -- Load opening hours
    local ohKey = "farmersMarketSettings.openingHours"
    local openHour  = getXMLInt(xmlFile, ohKey .. "#openHour")
    local closeHour = getXMLInt(xmlFile, ohKey .. "#closeHour")

    if openHour ~= nil then
        self.openHour = openHour
    elseif not isOverride then
        self.openHour = self.openHour or 8
    end

    if closeHour ~= nil then
        self.closeHour = closeHour
    elseif not isOverride then
        self.closeHour = self.closeHour or 20
    end

    delete(xmlFile)
end

-- Create a default GLOBAL settings file (not per-save)
function FarmersMarketRandom:saveDefaultSettings(path)
    -- default opening hours and presets already set in constructor
    self.openHour  = 8
    self.closeHour = 20

    local xmlFile = createXMLFile("farmersMarketSettings", path, "farmersMarketSettings")

    -- Presets
    for idx, preset in ipairs(self.presets) do
        local key = string.format("farmersMarketSettings.presets.preset(%d)", idx - 1)
        setXMLInt(xmlFile,   key .. "#id",         preset.id)
        setXMLString(xmlFile,key .. "#name",       preset.nameKey or ("preset" .. preset.id))
        setXMLFloat(xmlFile, key .. "#minPercent", preset.minPercent)
        setXMLFloat(xmlFile, key .. "#maxPercent", preset.maxPercent)
    end

    -- Opening hours
    setXMLInt(xmlFile, "farmersMarketSettings.openingHours#openHour",  self.openHour)
    setXMLInt(xmlFile, "farmersMarketSettings.openingHours#closeHour", self.closeHour)

    saveXMLFile(xmlFile)
    delete(xmlFile)

    Logging.info("FarmersMarketRandom: Created default global settings at '%s'", path)
end

----------------------------------------------------------------------
-- Sales log helpers
----------------------------------------------------------------------

function FarmersMarketRandom:ensureSalesLogHeader()
    if self.salesLogFilePath == nil then
        return
    end

    if not fileExists(self.salesLogFilePath) then
        local file = io.open(self.salesLogFilePath, "w")
        if file ~= nil then
            -- day;hour;presetName;fillTypeName;litersSold;pricePerLiter;totalMoney;percentOfStock
            file:write("day;hour;preset;presetIndex;fillType;litersSold;pricePerLiter;totalMoney;percentOfStock\n")
            file:close()
        end
    end
end

function FarmersMarketRandom:logSale(day, hour, presetIndex, presetName, fillTypeName, liters, pricePerLiter, money, percentOfStock)
    if self.salesLogFilePath == nil then
        return
    end

    local file = io.open(self.salesLogFilePath, "a")
    if file ~= nil then
        local line = string.format(
            "%d;%02d;%s;%d;%s;%.3f;%.4f;%.2f;%.2f",
            day or 0,
            hour or 0,
            presetName or "",
            presetIndex or 0,
            fillTypeName or "",
            liters or 0,
            pricePerLiter or 0,
            money or 0,
            percentOfStock or 0
        )
        file:write(line .. "\n")
        file:close()
    end
end

----------------------------------------------------------------------
-- Info trigger callback: track when player enters/leaves trigger
----------------------------------------------------------------------

function FarmersMarketRandom:infoTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay, otherShapeId)
    if otherId == g_currentMission.player.rootNode then
        if onEnter then
            self.isPlayerInTrigger = true
        elseif onLeave then
            self.isPlayerInTrigger = false
        end
    end
end

----------------------------------------------------------------------
-- Preset logic
----------------------------------------------------------------------

function FarmersMarketRandom:getCurrentPreset()
    return self.presets[self.currentPresetIndex]
end

function FarmersMarketRandom:applyPreset(presetIndex, showMessage)
    local preset = self.presets[presetIndex]
    if preset == nil then
        return
    end

    self.currentPresetIndex = presetIndex

    self.randomMinPercent = math.max(0, preset.minPercent) / 100.0
    self.randomMaxPercent = math.max(self.randomMinPercent, preset.maxPercent / 100.0)

    if showMessage then
        local name = g_i18n:getText(preset.nameKey) or ("Preset " .. presetIndex)
        local msg = string.format(
            "%s: %.1f%% - %.1f%% of stock sold each in-game hour\nOpen: %02d:00 - %02d:00",
            name,
            preset.minPercent,
            preset.maxPercent,
            self.openHour or 0,
            self.closeHour or 24
        )
        g_currentMission:showBlinkingWarning(msg, 5000)
    end
end

function FarmersMarketRandom:cycleRandomSellPreset()
    local nextIndex = self.currentPresetIndex + 1
    if nextIndex > #self.presets then
        nextIndex = 1
    end
    self:applyPreset(nextIndex, true)
end

----------------------------------------------------------------------
-- Market open / closed logic
----------------------------------------------------------------------

function FarmersMarketRandom:isMarketOpen(currentHour)
    -- currentHour is 0..23
    local openH  = self.openHour or 0
    local closeH = self.closeHour or 24

    if openH == closeH then
        -- degenerate: treat as always open
        return true
    end

    if openH < closeH then
        -- Normal: openH <= hour < closeH
        return currentHour >= openH and currentHour < closeH
    else
        -- Overnight window: e.g. open 20, close 4 => open [20..24) U [0..4)
        return currentHour >= openH or currentHour < closeH
    end
end

----------------------------------------------------------------------
-- Hourly selling logic
----------------------------------------------------------------------

function FarmersMarketRandom:update(dt)
    FarmersMarketRandom:superClass().update(self, dt)

    if not self.isServer then
        return
    end

    local env = g_currentMission.environment
    local currentHour = math.floor(env.dayTime / 3600000) -- ms -> in-game hour

    if self.lastHour == nil then
        self.lastHour = currentHour
        return
    end

    if currentHour ~= self.lastHour then
        self.lastHour = currentHour

        if self:isMarketOpen(currentHour) then
            self:performRandomSellAll(currentHour)
        else
            Logging.info("FarmersMarketRandom: Market closed at hour %d, no sales.", currentHour)
        end
    end
end

function FarmersMarketRandom:performRandomSellAll(currentHour)
    if self.storage == nil or self.farmId == nil then
        return
    end

    if self.randomMaxPercent <= 0 or self.randomMaxPercent < self.randomMinPercent then
        return
    end

    local econ = g_currentMission.economyManager
    local fillTypeManager = g_fillTypeManager
    local env = g_currentMission.environment
    local day = (env and (env.currentDay or env.day)) or 0

    local preset = self:getCurrentPreset()
    local presetName = preset and (g_i18n:getText(preset.nameKey) or preset.nameKey) or ("Preset " .. tostring(self.currentPresetIndex))

    for fillTypeIndex, fillType in pairs(fillTypeManager.fillTypes) do
        if fillType ~= nil and fillTypeIndex ~= FillType.UNKNOWN then
            local stored = self.storage:getFillLevel(fillTypeIndex)

            if stored > 0 then
                local pricePerLiter = econ:getPricePerLiter(fillTypeIndex, true) or 0
                if pricePerLiter > 0 then
                    local rnd = math.random()
                    local percentage = self.randomMinPercent + (self.randomMaxPercent - self.randomMinPercent) * rnd
                    local toSell = stored * percentage

                    if toSell > 0.1 then
                        local delta = -toSell
                        self.storage:addFillLevelFromTool(self.farmId, delta, fillTypeIndex, nil, nil)

                        local money = toSell * pricePerLiter
                        g_currentMission:addMoney(money, self.farmId, MoneyType.SOLD_PRODUCTS, true, true)

                        local ftName = fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or tostring(fillTypeIndex)
                        local percentOfStock = percentage * 100.0

                        Logging.info("FarmersMarketRandom: Sold %.1f L of %s (%.1f%% of stock) for %.0f $",
                            toSell,
                            ftName,
                            percentOfStock,
                            money
                        )

                        -- Log to CSV
                        self:logSale(
                            day,
                            currentHour,
                            self.currentPresetIndex,
                            presetName,
                            ftName,
                            toSell,
                            pricePerLiter,
                            money,
                            percentOfStock
                        )
                    end
                end
            end
        end
    end
end
