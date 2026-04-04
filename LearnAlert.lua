--[[
    LearnAlert - Displays bouncing alerts for learnable mounts, toys, transmog items, follower curios, profession knowledge, battle pets, and housing decor
    Detects mounts, toys, transmog items, follower curios, profession knowledge, pets, and housing decor items in bags and bank that the character hasn't learned yet
    
    Uses floating bouncing text alerts with secure frames
]]

local addonName, addon = ...

-- Default settings
local defaults = {
    enabled = true,
    showAlert = true,
    alertX = 400,
    alertY = 100,
    verbose = false,
    autoConfirmBindWarning = false,
    autoConfirmRefundWarning = false,
    debugClicks = false,
    alertScale = 1.0,
    checkInterval = 2, -- Seconds between checks
    ignoredItems = {}, -- Table of itemID -> true for items suppressed from the alert
    -- Per-type detection toggles
    detectMounts = true,
    detectToys = true,
    detectTransmog = true,
    detectCurios = true,
    detectKnowledge = true,
    detectPets = true,
    detectDecor = true,
}

-- Return true when itemID should be suppressed from the alert.
local function IsItemIgnored(itemID)
    return LearnAlertDB
        and LearnAlertDB.ignoredItems
        and LearnAlertDB.ignoredItems[itemID] == true
end

local refreshIgnoredItemsSettingsUI

local function EnsureIgnoredItemsTable()
    if not LearnAlertDB.ignoredItems then
        LearnAlertDB.ignoredItems = {}
    end
end

local function AddIgnoredItem(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 or not LearnAlertDB then
        return false
    end

    EnsureIgnoredItemsTable()
    if LearnAlertDB.ignoredItems[itemID] then
        return false
    end

    LearnAlertDB.ignoredItems[itemID] = true
    if refreshIgnoredItemsSettingsUI then
        refreshIgnoredItemsSettingsUI()
    end

    return true
end

local function RemoveIgnoredItem(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 or not LearnAlertDB or not LearnAlertDB.ignoredItems then
        return false
    end

    if not LearnAlertDB.ignoredItems[itemID] then
        return false
    end

    LearnAlertDB.ignoredItems[itemID] = nil
    if refreshIgnoredItemsSettingsUI then
        refreshIgnoredItemsSettingsUI()
    end

    return true
end

local function GetSortedIgnoredItemIDs()
    local ids = {}
    if not LearnAlertDB or not LearnAlertDB.ignoredItems then
        return ids
    end

    for itemID in pairs(LearnAlertDB.ignoredItems) do
        table.insert(ids, itemID)
    end
    table.sort(ids)
    return ids
end

-- Bank bag constants
local BANK_CONTAINER_FIRST = 5
local BANK_CONTAINER_LAST = 12
-- Reagent bank is bag index -3 (may not be in Enum on all client versions)
local REAGENTBANK_CONTAINER = (Enum.BagIndex and Enum.BagIndex.Reagentbank) or (Enum.BagIndex and Enum.BagIndex.ReagentBank) or -3
-- Warbank tabs (account-wide bank) are bags 13-17
local ACCOUNTBANK_TAB_FIRST = (Enum.BagIndex and Enum.BagIndex.AccountBankTab_1) or 13
local ACCOUNTBANK_TAB_LAST = (Enum.BagIndex and Enum.BagIndex.AccountBankTab_5) or 17

-- Alert frame reference and button pool
local alertFrame
local buttonPool = {}
local MAX_BUTTONS = 10
local LEARNABLE_ITEM_ORDER = { "mounts", "toys", "transmog", "curios", "knowledge", "pets", "decor" }
local BATTLEPET_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Battlepet) or 17
local WEAPON_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local ARMOR_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local PET_CAGE_ITEM_ID = 82800
local PLAYER_HAS_DECOR_FN = rawget(_G, "PlayerHasDecor")
local isUpdateScheduled = false
local isBankOpen = false
local learnAlertSettingsCategory
local ScheduleAlertUpdate
local curioItemCacheByID = {}
local knowledgeItemCacheByID = {}
local knowledgeItemNegativeCacheExpiresAtByID = {}
local transmogItemCacheByLink = {}
local staticPopupHookRegistered = false
local learnAlertActionContextToken = 0
local learnAlertActionContextExpiresAt = 0
---@type GameTooltip
local petScanTooltip = CreateFrame("GameTooltip", "LearnAlertPetScanTooltip", UIParent, "GameTooltipTemplate")
---@type GameTooltip
local genericScanTooltip = CreateFrame("GameTooltip", "LearnAlertGenericScanTooltip", UIParent, "GameTooltipTemplate")
local clickDebugFrame
local clickDebugEditBox
local clickDebugLines = {}

local function ClearDetectionCaches()
    curioItemCacheByID = {}
    knowledgeItemCacheByID = {}
    knowledgeItemNegativeCacheExpiresAtByID = {}
    transmogItemCacheByLink = {}
end

local function ClearDetectionCachesForItem(itemID)
    itemID = tonumber(itemID)
    if not itemID then
        return
    end

    curioItemCacheByID[itemID] = nil
    knowledgeItemCacheByID[itemID] = nil
    knowledgeItemNegativeCacheExpiresAtByID[itemID] = nil

    local itemToken = "item:" .. itemID
    for cacheKey in pairs(transmogItemCacheByLink) do
        if type(cacheKey) == "string" and string.find(cacheKey, itemToken, 1, true) then
            transmogItemCacheByLink[cacheKey] = nil
        end
    end
end

-- Hidden tooltip owner for bag-item metadata parsing.
petScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
genericScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

-- Refresh cooldown overlays for all visible buttons.
local function RefreshButtonCooldowns()
    for _, button in ipairs(buttonPool) do
        if button:IsShown() and button.itemID and button.cooldown then
            local startTime, duration = GetItemCooldown(button.itemID)
            if startTime and duration and duration > 0 then
                button.cooldown:SetCooldown(startTime, duration)
            else
                button.cooldown:SetCooldown(0, 0)
            end
        end
    end
end

-- Print message with addon prefix
local function PrintMessage(msg)
    if LearnAlertDB and LearnAlertDB.verbose then
        print("|cff00a0ff[LearnAlert]|r " .. msg)
    end
end

local function OpenSettingsCategory(category)
    if not category then
        return false
    end

    if Settings and Settings.OpenToCategory then
        local categoryID = category.GetID and category:GetID() or category
        Settings.OpenToCategory(categoryID)
        return true
    end

    return false
end

local function ClearLearnAlertActionContext()
    learnAlertActionContextExpiresAt = 0
end

local function HasRecentLearnAlertActionContext()
    return learnAlertActionContextExpiresAt > GetTime()
end

local function MarkLearnAlertActionContext(itemID, bag, slot)
    learnAlertActionContextToken = learnAlertActionContextToken + 1
    learnAlertActionContextExpiresAt = GetTime() + 1.5

    local contextToken = learnAlertActionContextToken
    PrintMessage(string.format(
        "LearnAlert action context armed: itemID=%s bag=%s slot=%s",
        tostring(itemID),
        tostring(bag),
        tostring(slot)
    ))

    C_Timer.After(1.6, function()
        if learnAlertActionContextToken == contextToken then
            ClearLearnAlertActionContext()
        end
    end)
end

local function FindVisibleStaticPopup(which)
    if type(StaticPopup_Visible) == "function" then
        local _, frame = StaticPopup_Visible(which)
        if frame then
            return frame
        end
    end

    if type(StaticPopup_FindVisible) == "function" then
        local frame = StaticPopup_FindVisible(which)
        if frame then
            return frame
        end
    end

    local numDialogs = tonumber(rawget(_G, "STATICPOPUP_NUMDIALOGS")) or 4
    for i = 1, numDialogs do
        local frame = _G["StaticPopup" .. i]
        if frame and frame:IsShown() and frame.which == which then
            return frame
        end
    end

    return nil
end

local function GetStaticPopupText(frame)
    if not frame then
        return nil
    end

    local textRegion = frame.Text or frame.text
    if not textRegion and frame.GetTextFontString then
        textRegion = frame:GetTextFontString()
    end

    if textRegion and textRegion.GetText then
        return textRegion:GetText()
    end

    return nil
end

local function GetStaticPopupPrimaryButton(frame)
    if not frame then
        return nil
    end

    if frame.GetButton1 then
        return frame:GetButton1()
    end

    if frame.button1 then
        return frame.button1
    end

    local frameName = frame.GetName and frame:GetName() or nil
    if frameName then
        return _G[frameName .. "Button1"]
    end

    return nil
end

local function HideStaticPopup(which)
    if type(StaticPopup_Hide) == "function" then
        StaticPopup_Hide(which)
        return
    end

    local frame = FindVisibleStaticPopup(which)
    if frame then
        frame:Hide()
    end
end

local BIND_WARNING_POPUPS = {
    CONFIRM_BINDER = true,
    ACTION_WILL_BIND_ITEM = true,
    USE_BIND = true,
    EQUIP_BIND = true,
    EQUIP_BIND_TRADEABLE = true,
    BIND_SOCKET = true,
    BIND_ENCHANT = true,
    CONVERT_TO_BIND_TO_ACCOUNT_CONFIRM = true,
}

local REFUND_WARNING_POPUPS = {
    USE_NO_REFUND_CONFIRM = true,
    EQUIP_BIND_REFUNDABLE = true,
    CONFIRM_REFUND_ITEM = true,
    CONFIRM_REFUND_TOKEN = true,
    CONFIRM_MAIL_ITEM_UNREFUNDABLE = true,
    CONFIRM_PURCHASE_NONREFUNDABLE_ITEM = true,
}

local BIND_WARNING_EVENT_HANDLERS = {
    ACTION_WILL_BIND_ITEM = {
        popup = "ACTION_WILL_BIND_ITEM",
        canRun = function()
            return C_Item and C_Item.ActionBindsItem
        end,
        run = function()
            C_Item.ActionBindsItem()
        end,
    },
    USE_BIND_CONFIRM = {
        popup = "USE_BIND",
        canRun = function()
            return C_Item and C_Item.ConfirmBindOnUse
        end,
        run = function()
            C_Item.ConfirmBindOnUse()
        end,
    },
    EQUIP_BIND_CONFIRM = {
        popup = "EQUIP_BIND",
        canRun = function(slot)
            return type(EquipPendingItem) == "function" and slot ~= nil
        end,
        run = function(slot)
            EquipPendingItem(slot)
        end,
    },
    EQUIP_BIND_TRADEABLE_CONFIRM = {
        popup = "EQUIP_BIND_TRADEABLE",
        canRun = function(slot)
            return type(EquipPendingItem) == "function" and slot ~= nil
        end,
        run = function(slot)
            EquipPendingItem(slot)
        end,
    },
    BIND_ENCHANT = {
        popup = "BIND_ENCHANT",
        canRun = function()
            return C_Item and C_Item.BindEnchant
        end,
        run = function()
            C_Item.BindEnchant()
        end,
    },
    CONVERT_TO_BIND_TO_ACCOUNT_CONFIRM = {
        popup = "CONVERT_TO_BIND_TO_ACCOUNT_CONFIRM",
        canRun = function()
            return type(ConvertItemToBindToAccount) == "function"
        end,
        run = function()
            ConvertItemToBindToAccount()
        end,
    },
}

local REFUND_WARNING_EVENT_HANDLERS = {
    USE_NO_REFUND_CONFIRM = {
        popup = "USE_NO_REFUND_CONFIRM",
        canRun = function()
            return C_Item and C_Item.ConfirmNoRefundOnUse
        end,
        run = function()
            C_Item.ConfirmNoRefundOnUse()
        end,
    },
    EQUIP_BIND_REFUNDABLE_CONFIRM = {
        popup = "EQUIP_BIND_REFUNDABLE",
        canRun = function(slot)
            return type(EquipPendingItem) == "function" and slot ~= nil
        end,
        run = function(slot)
            EquipPendingItem(slot)
        end,
    },
}

local WARNING_CONFIRM_EVENTS = {
    "ACTION_WILL_BIND_ITEM",
    "USE_BIND_CONFIRM",
    "EQUIP_BIND_CONFIRM",
    "EQUIP_BIND_REFUNDABLE_CONFIRM",
    "EQUIP_BIND_TRADEABLE_CONFIRM",
    "USE_NO_REFUND_CONFIRM",
    "BIND_ENCHANT",
    "CONVERT_TO_BIND_TO_ACCOUNT_CONFIRM",
}

local function RunWarningEventHandler(settingKey, handlerMap, event, ...)
    if not LearnAlertDB or not LearnAlertDB[settingKey] then
        return false
    end

    if not HasRecentLearnAlertActionContext() then
        return false
    end

    local handler = handlerMap[event]
    if not handler then
        return false
    end

    if handler.canRun and not handler.canRun(...) then
        return false
    end

    handler.run(...)

    if handler.popup then
        C_Timer.After(0, function()
            HideStaticPopup(handler.popup)
        end)
    end

    ClearLearnAlertActionContext()

    return true
end

local function AcceptBindWarningEvent(event, ...)
    return RunWarningEventHandler("autoConfirmBindWarning", BIND_WARNING_EVENT_HANDLERS, event, ...)
end

local function AcceptRefundWarningEvent(event, ...)
    return RunWarningEventHandler("autoConfirmRefundWarning", REFUND_WARNING_EVENT_HANDLERS, event, ...)
end

local function IsBindWarningPopup(which)
    return BIND_WARNING_POPUPS[which] == true
end

local function IsRefundWarningPopup(which, popupText)
    if REFUND_WARNING_POPUPS[which] == true then
        return true
    end

    local noRefundGlobal = rawget(_G, "NO_REFUND")
    local noRefundText = type(noRefundGlobal) == "string" and noRefundGlobal or nil
    if noRefundText and noRefundText ~= "" and type(popupText) == "string" and popupText ~= "" then
        return string.find(string.lower(popupText), string.lower(noRefundText), 1, true) ~= nil
    end

    return false
end

local function TryAutoConfirmWarningPopup(which)
    if not LearnAlertDB then
        return
    end

    if not HasRecentLearnAlertActionContext() then
        return
    end

    local popupFrame = FindVisibleStaticPopup(which)
    if not popupFrame then
        return
    end

    local popupText = GetStaticPopupText(popupFrame)
    local shouldConfirm = false

    if LearnAlertDB.autoConfirmBindWarning and IsBindWarningPopup(which) then
        shouldConfirm = true
    elseif LearnAlertDB.autoConfirmRefundWarning and IsRefundWarningPopup(which, popupText) then
        shouldConfirm = true
    end

    if not shouldConfirm then
        return
    end

    if InCombatLockdown() then
        PrintMessage(string.format("Auto-confirm skipped in combat for popup '%s'.", tostring(which)))
        return
    end

    local confirmButton = GetStaticPopupPrimaryButton(popupFrame)
    if not confirmButton or not confirmButton:IsEnabled() then
        return
    end

    C_Timer.After(0, function()
        if popupFrame:IsShown() and popupFrame.which == which and confirmButton:IsShown() and confirmButton:IsEnabled() then
            confirmButton:Click()
            ClearLearnAlertActionContext()
            PrintMessage(string.format("Auto-confirmed warning popup '%s'.", tostring(which)))
        end
    end)
end

local function RegisterWarningAutoConfirmHook()
    if staticPopupHookRegistered then
        return
    end

    if not hooksecurefunc or not StaticPopup_Show then
        return
    end

    hooksecurefunc("StaticPopup_Show", function(which)
        if which then
            TryAutoConfirmWarningPopup(which)
        end
    end)

    staticPopupHookRegistered = true
end

local function EnsureClickDebugFrame()
    if clickDebugFrame then
        return clickDebugFrame
    end

    local frame = CreateFrame("Frame", "LearnAlertClickDebugFrame", UIParent, "BackdropTemplate")
    frame:SetSize(760, 440)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:Hide()

    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.95)

    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    titleBar:SetBackdropColor(0.25, 0.35, 0.7, 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)

    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 10, 0)
    title:SetText("LearnAlert Click Debug Output")
    title:SetTextColor(1, 1, 1)

    local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeBtn:SetPoint("RIGHT", -5, 0)
    closeBtn:SetSize(24, 24)
    closeBtn:SetScript("OnClick", function()
        frame:Hide()
    end)

    local scrollFrame = CreateFrame("ScrollFrame", "LearnAlertClickDebugScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 10)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetWidth(700)
    editBox:SetHeight(380)
    editBox:SetFontObject(GameFontWhite)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function()
        frame:Hide()
    end)
    scrollFrame:SetScrollChild(editBox)

    clickDebugFrame = frame
    clickDebugEditBox = editBox
    return frame
end

local function AppendClickDebugOutput(msg)
    table.insert(clickDebugLines, msg)
    local text = table.concat(clickDebugLines, "\n")

    local frame = EnsureClickDebugFrame()
    if clickDebugEditBox then
        clickDebugEditBox:SetText(text)
        clickDebugEditBox:SetCursorPosition(0)
    end
    frame:Show()
end

local function PrintDebugClick(msg)
    if LearnAlertDB and LearnAlertDB.debugClicks then
        print("|cff00a0ff[LearnAlert]|r [debugclick] " .. msg)
        AppendClickDebugOutput(msg)
    end
end

local function HideAlertUntilShown()
    if alertFrame then
        alertFrame:Hide()
    end

    if LearnAlertDB then
        LearnAlertDB.showAlert = false
    end

    print("|cff00a0ff[LearnAlert]|r Alert hidden. Use /la show to show it again.")
end

-- Extract species ID from a battlepet hyperlink string.
local function GetSpeciesIDFromLink(itemLink)
    if not itemLink then
        return nil
    end

    local speciesID = itemLink:match("battlepet:(%d+)")
    if speciesID then
        return tonumber(speciesID)
    end

    return nil
end

local petSpeciesByNameCache = {}
local hasBuiltFullSpeciesNameCache = false
local MAX_PET_SPECIES_SCAN_ID = 5000

local function AddSpeciesNameToCache(speciesID, speciesName)
    if not speciesID or not speciesName or speciesName == "" then
        return
    end

    local list = petSpeciesByNameCache[speciesName]
    if not list then
        list = {}
        petSpeciesByNameCache[speciesName] = list
    end

    for _, existingSpeciesID in ipairs(list) do
        if existingSpeciesID == speciesID then
            return
        end
    end

    table.insert(list, speciesID)
end

local function BuildPetSpeciesNameCache()
    if hasBuiltFullSpeciesNameCache then
        return
    end

    for speciesID = 1, MAX_PET_SPECIES_SCAN_ID do
        local speciesName = C_PetJournal.GetPetInfoBySpeciesID(speciesID)
        if speciesName then
            AddSpeciesNameToCache(speciesID, speciesName)
        end
    end

    hasBuiltFullSpeciesNameCache = true
end

local function GetSpeciesIDFromItemName(itemName)
    if not itemName or itemName == "" then
        return nil
    end

    BuildPetSpeciesNameCache()
    local speciesIDs = petSpeciesByNameCache[itemName]
    if not speciesIDs or #speciesIDs == 0 then
        return nil
    end

    -- Prefer a species that can still be collected.
    for _, speciesID in ipairs(speciesIDs) do
        local numOwned, limit = C_PetJournal.GetNumCollectedInfo(speciesID)
        numOwned = tonumber(numOwned) or 0
        limit = tonumber(limit) or 3
        if numOwned < limit then
            return speciesID
        end
    end

    return speciesIDs[1]
end

-- Resolve species ID for a pet item in a specific bag slot.
local function GetSpeciesIDFromBagSlot(bag, slot, itemID, itemLink, itemName)
    local bagLink = C_Container.GetContainerItemLink(bag, slot) or itemLink
    local speciesID = GetSpeciesIDFromLink(bagLink)
    if speciesID then
        return speciesID
    end

    local fallbackSpeciesID = C_PetJournal.GetPetInfoByItemID(itemID)
    speciesID = tonumber(fallbackSpeciesID)
    if speciesID then
        return speciesID
    end
    -- In WoW 12.x+, GetPetInfoByItemID returns the species name string instead of the species ID.
    -- Use that name to resolve the species ID from the name cache.
    if type(fallbackSpeciesID) == "string" and fallbackSpeciesID ~= "" then
        speciesID = GetSpeciesIDFromItemName(fallbackSpeciesID)
        if speciesID then
            return speciesID
        end
    end

    -- Some cage links do not expose species in item links; tooltip data can.
    if C_TooltipInfo and C_TooltipInfo.GetBagItem then
        local tooltipData = C_TooltipInfo.GetBagItem(bag, slot)
        if tooltipData then
            -- battlePet.speciesID is the documented path; rawget is a legacy fallback.
            local tooltipSpeciesID = (tooltipData.battlePet and tooltipData.battlePet.speciesID)
                or rawget(tooltipData, "battlePetSpeciesID")
            if tooltipSpeciesID then
                return tonumber(tooltipSpeciesID)
            end
        end
    end

    -- Final fallback: some pet data only appears through tooltip bag item state.
    petScanTooltip:ClearLines()
    petScanTooltip:SetBagItem(bag, slot)
    local _, tooltipLink = petScanTooltip:GetItem()
    speciesID = GetSpeciesIDFromLink(tooltipLink)
    if speciesID then
        return speciesID
    end

    -- Final fallback for pet cages that expose species only through item name.
    speciesID = GetSpeciesIDFromItemName(itemName)
    if speciesID then
        return speciesID
    end

    return nil
end

local function IsBattlePetClassItem(itemID)
    if itemID == PET_CAGE_ITEM_ID then
        return true
    end

    local _, _, itemSubType, _, _, classID = GetItemInfoInstant(itemID)
    if classID == BATTLEPET_CLASS_ID then
        return true
    end

    -- Fallback text checks for localized/client variant subtype labeling.
    if itemSubType == "Battle Pets" or itemSubType == "Companion Pets" then
        return true
    end

    return false
end

-- Determine whether an item is a toy using ToyBox APIs with metadata fallback.
local function IsToyItem(itemID, itemClass, itemSubClass)
    -- Primary check: ToyBox API recognition (most reliable)
    if C_ToyBox and C_ToyBox.GetToyInfo then
        local toyName, toyIcon = C_ToyBox.GetToyInfo(itemID)
        if toyName and toyIcon then
            return true
        end
    end

    -- Fallback: item class metadata (less reliable but covers edge cases)
    if itemClass == "Toy" or itemSubClass == "Toy" then
        return true
    end

    return false
end

local function GetToyKnownState(itemID)
    if PlayerHasToy then
        return PlayerHasToy(itemID)
    end

    if C_ToyBox and C_ToyBox.IsToyKnown then
        return C_ToyBox.IsToyKnown(itemID)
    end

    return nil
end

local function AddLowerTooltipTexts(textMap, tooltipData)
    if not tooltipData or not tooltipData.lines then
        return
    end

    for _, line in ipairs(tooltipData.lines) do
        if line.leftText and line.leftText ~= "" then
            textMap[string.lower(line.leftText)] = true
        end

        if line.rightText and line.rightText ~= "" then
            textMap[string.lower(line.rightText)] = true
        end

        if line.text and line.text ~= "" then
            textMap[string.lower(line.text)] = true
        end

        if line.args then
            for _, arg in ipairs(line.args) do
                if type(arg) == "table" then
                    for _, value in pairs(arg) do
                        if type(value) == "string" and value ~= "" then
                            textMap[string.lower(value)] = true
                        end
                    end
                elseif type(arg) == "string" and arg ~= "" then
                    textMap[string.lower(arg)] = true
                end
            end
        end
    end
end

local function AddLowerBagTooltipTexts(textMap, bag, slot)
    if not bag or not slot then
        return
    end

    genericScanTooltip:ClearLines()
    genericScanTooltip:SetBagItem(bag, slot)

    local tooltipName = genericScanTooltip:GetName()
    if not tooltipName then
        return
    end

    local numLines = genericScanTooltip:NumLines() or 0
    for i = 1, numLines do
        local leftRegion = _G[tooltipName .. "TextLeft" .. i]
        local rightRegion = _G[tooltipName .. "TextRight" .. i]

        if leftRegion and leftRegion.GetText then
            local leftText = leftRegion:GetText()
            if leftText and leftText ~= "" then
                textMap[string.lower(leftText)] = true
            end
        end

        if rightRegion and rightRegion.GetText then
            local rightText = rightRegion:GetText()
            if rightText and rightText ~= "" then
                textMap[string.lower(rightText)] = true
            end
        end
    end
end

local function IsProfessionKnowledgeTooltipText(textMap)
    local hasKnowledge = false
    local hasUseLine = false

    for text in pairs(textMap) do
        if string.find(text, "knowledge", 1, true) then
            hasKnowledge = true
        end

        if string.find(text, "use:", 1, true) or string.find(text, "use ", 1, true) then
            hasUseLine = true
        end

        if string.find(text, "study to increase your", 1, true)
            and string.find(text, "knowledge", 1, true) then
            return true
        end

        -- Fast path: a single line that says "increase your ... knowledge"
        if string.find(text, "increase your", 1, true)
            and string.find(text, "knowledge", 1, true) then
            return true
        end
    end

    return hasKnowledge and hasUseLine
end

local function IsFollowerCurioTooltipText(textMap)
    local hasCurio = false
    local hasFollower = false
    local hasUseLine = false

    for text in pairs(textMap) do
        if string.find(text, "curio", 1, true) then
            hasCurio = true
        end

        if string.find(text, "follower", 1, true) or string.find(text, "companion", 1, true) then
            hasFollower = true
        end

        if string.find(text, "use:", 1, true) or string.find(text, "use ", 1, true) then
            hasUseLine = true
        end

        if string.find(text, "follower curio", 1, true) then
            return true
        end
    end

    return hasCurio and hasFollower and hasUseLine
end

-- Determine whether an item is a follower curio.
local function IsFollowerCurioItem(itemContext)
    local cachedResult = curioItemCacheByID[itemContext.itemID]
    if cachedResult ~= nil then
        return cachedResult
    end

    local itemClassLower = itemContext.itemClass and string.lower(itemContext.itemClass) or ""
    local itemSubClassLower = itemContext.itemSubClass and string.lower(itemContext.itemSubClass) or ""
    local itemNameLower = itemContext.itemName and string.lower(itemContext.itemName) or ""

    -- If the game's own item subclass identifies it as a curio (e.g. "Utility Curio",
    -- "Combat Curio"), that is a definitive signal — no tooltip heuristics needed.
    if string.find(itemSubClassLower, "curio", 1, true) then
        curioItemCacheByID[itemContext.itemID] = true
        return true
    end

    local isLikelyContainerType =
        itemClassLower == "consumable"
        or itemClassLower == "trade goods"
        or itemClassLower == "miscellaneous"

    if not isLikelyContainerType
        and not string.find(itemNameLower, "curio", 1, true)
        and not string.find(itemNameLower, "follower", 1, true) then
        -- Do not persist a negative cache entry while metadata is still loading.
        if itemContext.itemName and itemContext.itemClass and itemContext.itemSubClass then
            curioItemCacheByID[itemContext.itemID] = false
        end
        return false
    end

    local tooltipTexts = {}
    if C_TooltipInfo then
        if C_TooltipInfo.GetBagItem and itemContext.bag and itemContext.slot then
            AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetBagItem(itemContext.bag, itemContext.slot))
        end

        if C_TooltipInfo.GetHyperlink then
            local link = itemContext.bagItemLink or itemContext.itemLink or ("item:" .. itemContext.itemID)
            AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetHyperlink(link))
        end
    end

    local isCurio = IsFollowerCurioTooltipText(tooltipTexts)
    if not isCurio
        and string.find(itemNameLower, "curio", 1, true)
        and (string.find(itemNameLower, "follower", 1, true) or string.find(itemNameLower, "brann", 1, true))
        and isLikelyContainerType then
        -- Name-based fallback for clients/tooltips that don't expose full use text yet.
        isCurio = true
    end

    curioItemCacheByID[itemContext.itemID] = isCurio
    return isCurio
end

-- Determine whether an item is a profession knowledge item.
local function IsProfessionKnowledgeItem(itemContext)
    local itemID = itemContext.itemID
    local cachedResult = knowledgeItemCacheByID[itemID]
    if cachedResult == true then
        return true
    elseif cachedResult == false then
        local expiresAt = knowledgeItemNegativeCacheExpiresAtByID[itemID]
        if expiresAt and expiresAt > GetTime() then
            return false
        end

        -- Negative cache expired; retry detection so late-loading tooltip data can flip to true.
        knowledgeItemCacheByID[itemID] = nil
        knowledgeItemNegativeCacheExpiresAtByID[itemID] = nil
    end

    local itemClassLower = itemContext.itemClass and string.lower(itemContext.itemClass) or ""
    local itemSubClassLower = itemContext.itemSubClass and string.lower(itemContext.itemSubClass) or ""
    local itemNameLower = itemContext.itemName and string.lower(itemContext.itemName) or ""

    local isLikelyContainerType =
        itemClassLower == "consumable"
        or itemClassLower == "trade goods"
        or itemClassLower == "miscellaneous"
        or itemSubClassLower == "finishing reagents"

    if not isLikelyContainerType and not string.find(itemNameLower, "knowledge", 1, true) then
        -- Do not persist a negative cache entry while metadata is still loading.
        if itemContext.itemName and itemContext.itemClass and itemContext.itemSubClass then
            knowledgeItemCacheByID[itemID] = false
            knowledgeItemNegativeCacheExpiresAtByID[itemID] = GetTime() + 8
        end
        return false
    end

    local tooltipTexts = {}
    if C_TooltipInfo then
        if C_TooltipInfo.GetBagItem and itemContext.bag and itemContext.slot then
            AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetBagItem(itemContext.bag, itemContext.slot))
        end

        if C_TooltipInfo.GetHyperlink then
            local link = itemContext.bagItemLink or itemContext.itemLink or ("item:" .. itemContext.itemID)
            AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetHyperlink(link))
        end
    end

    -- Fallback: the legacy GameTooltip path can expose use-text lines that are
    -- occasionally missing from C_TooltipInfo for newer profession items.
    if itemContext.bag and itemContext.slot then
        AddLowerBagTooltipTexts(tooltipTexts, itemContext.bag, itemContext.slot)
    end

    -- Exclude the item name from the textMap so that items whose names contain
    -- "knowledge" (e.g. "Untapped Forbidden Knowledge") don't get false-positives.
    if itemNameLower ~= "" then
        tooltipTexts[itemNameLower] = nil
    end

    local isKnowledge = IsProfessionKnowledgeTooltipText(tooltipTexts)

    knowledgeItemCacheByID[itemID] = isKnowledge
    if isKnowledge then
        knowledgeItemNegativeCacheExpiresAtByID[itemID] = nil
    else
        -- Short TTL avoids sticky false-negatives before tooltip text fully hydrates.
        knowledgeItemNegativeCacheExpiresAtByID[itemID] = GetTime() + 8
    end
    return isKnowledge
end

local function IsTooltipTokenPresent(textMap, token)
    if not token or token == "" then
        return false
    end

    return textMap[string.lower(token)] == true
end

local function IsAnyTooltipTokenPresent(textMap, tokenNames)
    for _, tokenName in ipairs(tokenNames) do
        local tokenValue = rawget(_G, tokenName)
        if IsTooltipTokenPresent(textMap, tokenValue) then
            return true
        end
    end

    return false
end

local function IsPotentialTransmogItem(itemContext)
    local itemNameLower = itemContext.itemName and string.lower(itemContext.itemName) or ""
    if string.find(itemNameLower, "ensemble:", 1, true)
        or string.find(itemNameLower, "arsenal:", 1, true) then
        return true
    end

    local _, _, _, _, _, classID = GetItemInfoInstant(itemContext.itemID)
    return classID == WEAPON_CLASS_ID or classID == ARMOR_CLASS_ID
end

local function IsTransmogTooltipText(textMap)
    local unknownTokens = {
        "TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN",
        "TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNUSABLE",
        "TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN_FAVORITE",
        "TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_KNOWN",
        "TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_KNOWN_FAVORITE",
        "TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_UNKNOWN",
        "TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_UNKNOWN_FAVORITE",
    }

    if IsAnyTooltipTokenPresent(textMap, unknownTokens) then
        return true
    end

    local knownTokens = {
        "TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN",
        "TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN_FAVORITE",
        "TRANSMOGRIFY_TOOLTIP_ITEM_KNOWN_APPEARANCE_KNOWN",
        "TRANSMOGRIFY_TOOLTIP_ITEM_KNOWN_APPEARANCE_KNOWN_FAVORITE",
    }

    if IsAnyTooltipTokenPresent(textMap, knownTokens) then
        return false
    end

    -- English fallback for clients where global tooltip constants are unavailable.
    local hasAppearanceText = false
    local hasUnknownText = false
    local hasKnownText = false
    for text in pairs(textMap) do
        if string.find(text, "appearance", 1, true) then
            hasAppearanceText = true
        end

        if string.find(text, "haven't collected", 1, true)
            or string.find(text, "not collected", 1, true)
            or string.find(text, "not yet collected", 1, true)
            or string.find(text, "missing appearance", 1, true)
            or string.find(text, "uncollected appearance", 1, true)
            or string.find(text, "learn this appearance", 1, true) then
            hasUnknownText = true
        end

        if string.find(text, "already known", 1, true)
            or string.find(text, "already collected", 1, true)
            or string.find(text, "known appearance", 1, true) then
            hasKnownText = true
        end
    end

    if hasKnownText then
        return false
    end

    local hasSetContainerText = false
    local hasCollectText = false
    local hasPartialCollection = false
    local hasCompleteCollection = false
    local hasUncollectedText = false
    for text in pairs(textMap) do
        if string.find(text, "ensemble", 1, true) or string.find(text, "arsenal", 1, true) then
            hasSetContainerText = true
        end

        if string.find(text, "collect", 1, true) or string.find(text, "collected", 1, true) then
            hasCollectText = true

            if string.find(text, "uncollected", 1, true) then
                hasUncollectedText = true
            end

            local uncollectedCount = tonumber(string.match(text, "contains%s+(%d+)%s+uncollected"))
            if uncollectedCount then
                if uncollectedCount > 0 then
                    hasPartialCollection = true
                else
                    hasCompleteCollection = true
                end
            end

            -- Ensemble/arsenal tooltips commonly expose progress like "Collected: 5/8".
            local collectedCount, totalCount = string.match(text, "(%d+)%s*/%s*(%d+)")
            collectedCount = tonumber(collectedCount)
            totalCount = tonumber(totalCount)
            if collectedCount and totalCount and totalCount > 0 then
                if collectedCount < totalCount then
                    hasPartialCollection = true
                elseif collectedCount >= totalCount then
                    hasCompleteCollection = true
                end
            end
        end
    end

    if hasPartialCollection then
        return true
    end

    if hasCompleteCollection then
        return false
    end

    if hasSetContainerText and hasUncollectedText then
        return true
    end

    if hasSetContainerText and hasUnknownText then
        return true
    end

    if hasSetContainerText and hasCollectText and hasKnownText then
        return false
    end

    -- Some ensemble/arsenal tooltips only provide generic collect text and omit
    -- explicit unknown markers. If there is no known/completed marker, treat as learnable.
    if hasSetContainerText and hasCollectText and not hasKnownText and not hasCompleteCollection then
        return true
    end

    return hasAppearanceText and hasUnknownText
end

local function IsLearnableTransmogItem(itemContext)
    if not IsPotentialTransmogItem(itemContext) then
        return false
    end

    local cacheKey = itemContext.bagItemLink or itemContext.itemLink or ("item:" .. itemContext.itemID)
    local cachedResult = transmogItemCacheByLink[cacheKey]
    if cachedResult ~= nil then
        return cachedResult
    end

    local tooltipTexts = {}
    if C_TooltipInfo then
        if C_TooltipInfo.GetBagItem and itemContext.bag and itemContext.slot then
            AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetBagItem(itemContext.bag, itemContext.slot))
        end

        if C_TooltipInfo.GetHyperlink then
            AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetHyperlink(cacheKey))
        end
    end

    local isLearnableTransmog = IsTransmogTooltipText(tooltipTexts)

    -- Avoid persisting false when item metadata may still be incomplete.
    if isLearnableTransmog or (itemContext.itemName and itemContext.itemClass and itemContext.itemSubClass) then
        transmogItemCacheByLink[cacheKey] = isLearnableTransmog
    end

    return isLearnableTransmog
end

local function IterateBagItems(callback, includeBank)
    -- Scan regular bags (backpack + bag slots)
    for bag = 0, NUM_BAG_SLOTS do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
            if containerInfo and containerInfo.itemID then
                callback(bag, slot, containerInfo)
            end
        end
    end
    
    -- Scan bank bags if requested
    if includeBank then
        -- Scan character bank bags (5-12)
        for bag = BANK_CONTAINER_FIRST, BANK_CONTAINER_LAST do
            local numSlots = C_Container.GetContainerNumSlots(bag)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                    if containerInfo and containerInfo.itemID then
                        callback(bag, slot, containerInfo)
                    end
                end
            end
        end
        
        -- Scan reagent bank (bag -3)
        local reagentSlots = C_Container.GetContainerNumSlots(REAGENTBANK_CONTAINER)
        if reagentSlots and reagentSlots > 0 then
            for slot = 1, reagentSlots do
                local containerInfo = C_Container.GetContainerItemInfo(REAGENTBANK_CONTAINER, slot)
                if containerInfo and containerInfo.itemID then
                    callback(REAGENTBANK_CONTAINER, slot, containerInfo)
                end
            end
        end
        
        -- Scan warbank tabs (account-wide bank, 13-17)
        for bag = ACCOUNTBANK_TAB_FIRST, ACCOUNTBANK_TAB_LAST do
            local numSlots = C_Container.GetContainerNumSlots(bag)
            if numSlots and numSlots > 0 then
                for slot = 1, numSlots do
                    local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                    if containerInfo and containerInfo.itemID then
                        callback(bag, slot, containerInfo)
                    end
                end
            end
        end
    end
end

local function GetBagItemContext(bag, slot, containerInfo)
    local itemID = containerInfo.itemID
    local itemName, itemLink, itemRarity, _, _, itemClass, itemSubClass, _, _, itemTexture = GetItemInfo(itemID)
    local bagItemLink = C_Container.GetContainerItemLink(bag, slot) or containerInfo.hyperlink or itemLink

    if not itemClass or not itemSubClass or IsBattlePetClassItem(itemID) then
        -- Newly acquired items can be uncached for a short time.
        -- Pet-class items also need full spell data for C_PetJournal.GetPetInfoByItemID to resolve species.
        C_Item.RequestLoadItemDataByID(itemID)
    end

    return {
        bag = bag,
        slot = slot,
        itemID = itemID,
        itemName = itemName,
        itemLink = itemLink,
        itemRarity = itemRarity,
        itemClass = itemClass,
        itemSubClass = itemSubClass,
        itemTexture = itemTexture,
        bagItemLink = bagItemLink,
    }
end

local function BuildLearnableMountData(itemContext)
    if itemContext.itemSubClass ~= "Mount" then
        return nil
    end

    local mountID = C_MountJournal.GetMountFromItem(itemContext.itemID)
    if not mountID then
        return nil
    end

    local name, spellID, icon, isActive, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)
    if isCollected then
        return nil
    end

    return {
        itemID = itemContext.itemID,
        itemName = itemContext.itemName,
        itemLink = itemContext.bagItemLink,
        itemTexture = itemContext.itemTexture,
        rarity = itemContext.itemRarity,
        mountID = mountID,
        bag = itemContext.bag,
        slot = itemContext.slot,
    }
end

local function BuildLearnableToyData(itemContext)
    if not IsToyItem(itemContext.itemID, itemContext.itemClass, itemContext.itemSubClass) then
        return nil
    end

    local isKnown = GetToyKnownState(itemContext.itemID)
    if isKnown == nil or isKnown then
        return nil
    end

    return {
        itemID = itemContext.itemID,
        itemName = itemContext.itemName,
        itemLink = itemContext.bagItemLink,
        itemTexture = itemContext.itemTexture,
        rarity = itemContext.itemRarity,
        bag = itemContext.bag,
        slot = itemContext.slot,
    }
end

local function BuildLearnableTransmogData(itemContext)
    if not IsLearnableTransmogItem(itemContext) then
        return nil
    end

    return {
        itemID = itemContext.itemID,
        itemName = itemContext.itemName,
        itemLink = itemContext.bagItemLink,
        itemTexture = itemContext.itemTexture,
        rarity = itemContext.itemRarity,
        bag = itemContext.bag,
        slot = itemContext.slot,
    }
end

local function BuildLearnableCurioData(itemContext)
    if not IsFollowerCurioItem(itemContext) then
        return nil
    end

    return {
        itemID = itemContext.itemID,
        itemName = itemContext.itemName,
        itemLink = itemContext.bagItemLink,
        itemTexture = itemContext.itemTexture,
        rarity = itemContext.itemRarity,
        bag = itemContext.bag,
        slot = itemContext.slot,
    }
end

local function BuildLearnableKnowledgeData(itemContext)
    if not IsProfessionKnowledgeItem(itemContext) then
        return nil
    end

    return {
        itemID = itemContext.itemID,
        itemName = itemContext.itemName,
        itemLink = itemContext.bagItemLink,
        itemTexture = itemContext.itemTexture,
        rarity = itemContext.itemRarity,
        bag = itemContext.bag,
        slot = itemContext.slot,
    }
end

-- Determine whether an item is a housing decor item and if it's already known.
local function IsDecorItem(itemID, itemClass, itemSubClass)
    -- Housing dyes are consumable colorants, not learnable decor unlocks.
    if itemSubClass and string.find(string.lower(itemSubClass), "dye", 1, true) then
        return false
    end

    -- Housing decor items are typically classified as "Miscellaneous" with specific subtypes
    -- The exact classification may vary by WoW version
    if itemSubClass == "Housing Decor" or itemSubClass == "Decoration" then
        return true
    end
    
    -- Some housing items might be in a "Housing" class
    if itemClass == "Housing" or itemClass == "Decor" then
        return true
    end
    
    return false
end

local function GetDecorKnownState(itemID)
    -- Check if APIs are available for housing decor
    -- Note: The exact API may vary depending on WoW version
    -- This checks for potential housing/decor APIs that may exist
    
    -- Try C_PlayerInteractionManager (TWW housing system)
    if C_PlayerInteractionManager and C_PlayerInteractionManager.IsDecorKnown then
        return C_PlayerInteractionManager.IsDecorKnown(itemID)
    end
    
    -- Try potential C_Housing API
    if C_Housing and C_Housing.IsDecorKnown then
        return C_Housing.IsDecorKnown(itemID)
    end
    
    -- Try PlayerHasDecor global function (similar to PlayerHasToy)
    if PLAYER_HAS_DECOR_FN then
        return PLAYER_HAS_DECOR_FN(itemID)
    end
    
    -- If no housing API is available, return nil (unknown state)
    return nil
end

local function BuildLearnableDecorData(itemContext)
    if not IsDecorItem(itemContext.itemID, itemContext.itemClass, itemContext.itemSubClass) then
        return nil
    end
    
    return {
        itemID = itemContext.itemID,
        itemName = itemContext.itemName,
        itemLink = itemContext.bagItemLink,
        itemTexture = itemContext.itemTexture,
        rarity = itemContext.itemRarity,
        isRepeatableDecor = true,
        bag = itemContext.bag,
        slot = itemContext.slot,
    }
end

local function BuildAllItemsList(items)
    local allItems = {}
    for _, itemType in ipairs(LEARNABLE_ITEM_ORDER) do
        for _, itemData in ipairs(items[itemType]) do
            table.insert(allItems, itemData)
        end
    end

    return allItems
end

-- Return pet data if item is a caged pet the player has not collected.
local function GetUncollectedPetData(bag, slot, itemID, itemLink, itemName, itemTexture, itemRarity)
    local speciesID = GetSpeciesIDFromBagSlot(bag, slot, itemID, itemLink, itemName)

    if speciesID and type(speciesID) == "number" and speciesID > 0 then
        local numOwned, limit = C_PetJournal.GetNumCollectedInfo(speciesID)
        -- Default limit is 3 if not returned by API
        numOwned = tonumber(numOwned) or 0
        limit = tonumber(limit) or 3
        
        if numOwned < limit then
            local speciesName, _, speciesIcon = C_PetJournal.GetPetInfoBySpeciesID(speciesID)
            return {
                itemID = itemID,
                itemName = speciesName or itemName,
                itemLink = itemLink,
                itemTexture = speciesIcon or itemTexture,
                rarity = itemRarity,
                speciesID = speciesID,
                bag = bag,
                slot = slot,
            }
        end
    end

    return nil
end

-- Scan bags and bank for learnable items
local function ScanForLearnableItems(includeBank)
    local learnableItems = {
        mounts = {},
        toys = {},
        transmog = {},
        curios = {},
        knowledge = {},
        pets = {},
        decor = {},
    }
    
    PrintMessage(string.format("Starting scan (includeBank=%s)...", tostring(includeBank)))
    
    local itemsScanned = 0
    local petsChecked = 0
    local petsAdded = 0
    
    IterateBagItems(function(bag, slot, containerInfo)
        if IsItemIgnored(containerInfo.itemID) then return end
        itemsScanned = itemsScanned + 1
        local itemContext = GetBagItemContext(bag, slot, containerInfo)

        if not LearnAlertDB or LearnAlertDB.detectMounts ~= false then
            local mountData = BuildLearnableMountData(itemContext)
            if mountData then
                table.insert(learnableItems.mounts, mountData)
                PrintMessage(string.format("  Found mount: %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
            end
        end

        if not LearnAlertDB or LearnAlertDB.detectToys ~= false then
            local toyData = BuildLearnableToyData(itemContext)
            if toyData then
                table.insert(learnableItems.toys, toyData)
                PrintMessage(string.format("  Found toy: %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
            end
        end

        if not LearnAlertDB or LearnAlertDB.detectTransmog ~= false then
            local transmogData = BuildLearnableTransmogData(itemContext)
            if transmogData then
                table.insert(learnableItems.transmog, transmogData)
                PrintMessage(string.format("  Found transmog appearance item: %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
            end
        end

        if not LearnAlertDB or LearnAlertDB.detectCurios ~= false then
            local curioData = BuildLearnableCurioData(itemContext)
            if curioData then
                table.insert(learnableItems.curios, curioData)
                PrintMessage(string.format("  Found follower curio: %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
            end
        end

        if not LearnAlertDB or LearnAlertDB.detectKnowledge ~= false then
            local knowledgeData = BuildLearnableKnowledgeData(itemContext)
            if knowledgeData then
                table.insert(learnableItems.knowledge, knowledgeData)
                PrintMessage(string.format("  Found profession knowledge item: %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
            end
        end

        if not LearnAlertDB or LearnAlertDB.detectDecor ~= false then
            local decorData = BuildLearnableDecorData(itemContext)
            if decorData then
                table.insert(learnableItems.decor, decorData)
                PrintMessage(string.format("  Found decor (repeatable): %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
            end
        end

        local isPetClassItem = IsBattlePetClassItem(itemContext.itemID)
        local hasBattlePetLink = itemContext.bagItemLink and string.find(itemContext.bagItemLink, "battlepet:", 1, true)

        -- Only run pet resolution for likely pet items to avoid heavy work while looting.
        if (not LearnAlertDB or LearnAlertDB.detectPets ~= false) and (isPetClassItem or hasBattlePetLink) then
            petsChecked = petsChecked + 1
            PrintMessage(string.format("  Checking pet: %s (ID:%d, Bag%d Slot%d)", itemContext.itemName or "?", itemContext.itemID, bag, slot))

            local petData = GetUncollectedPetData(
                bag,
                slot,
                itemContext.itemID,
                itemContext.bagItemLink,
                itemContext.itemName,
                itemContext.itemTexture,
                itemContext.itemRarity
            )
            if petData then
                petsAdded = petsAdded + 1
                table.insert(learnableItems.pets, petData)
                PrintMessage(string.format("    -> LEARNABLE! Added to list."))
            else
                PrintMessage(string.format("    -> Already collected or at limit."))
            end
        end
    end, includeBank)
    
    PrintMessage(string.format("Scan complete: %d items, %d pets checked, %d learnable pets found", itemsScanned, petsChecked, petsAdded))
    
    return learnableItems
end

-- Register the addon's settings panel with WoW's built-in Settings UI.
local function CreateSettingsPanel()
    if not Settings or not Settings.RegisterVerticalLayoutCategory then
        return
    end

    local category, layout = Settings.RegisterVerticalLayoutCategory("LearnAlert")

    -- Helper: register a boolean proxy setting backed by LearnAlertDB and create its checkbox.
    local function AddCheckbox(dbKey, displayName, tooltipText)
        local setting = Settings.RegisterProxySetting(
            category,
            "LearnAlert_" .. dbKey,
            Settings.VarType.Boolean,
            displayName,
            defaults[dbKey],
            function()
                return LearnAlertDB and LearnAlertDB[dbKey]
            end,
            function(value)
                if LearnAlertDB then
                    LearnAlertDB[dbKey] = value
                    ScheduleAlertUpdate(0)
                end
            end
        )
        Settings.CreateCheckbox(category, setting, tooltipText)
    end

    -- Section: general behavior
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("General"))
    end

    AddCheckbox("enabled", "Enable LearnAlert", "Enable or disable LearnAlert scanning and alerts.")
    AddCheckbox("showAlert", "Show Alert Window", "Show the learnable-items alert when matches are found.")
    AddCheckbox("verbose", "Verbose Chat Output", "Print detailed LearnAlert status messages to chat.")
    AddCheckbox("autoConfirmBindWarning", "Auto-confirm Bind Warning", "Automatically click OK on bind-to-you confirmation popups.")
    AddCheckbox("autoConfirmRefundWarning", "Auto-confirm Non-refundable Warning", "Automatically click OK on non-refundable confirmation popups.")

    -- Section: item-type detection toggles
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Item Type Detection"))
    end

    AddCheckbox("detectMounts",    "Mounts",               "Detect learnable mount items in bags and bank.")
    AddCheckbox("detectToys",      "Toys",                 "Detect uncollected toy items in bags and bank.")
    AddCheckbox("detectTransmog",  "Transmog",             "Detect uncollected transmog appearances in bags and bank.")
    AddCheckbox("detectCurios",    "Follower Curios",      "Detect follower curio items in bags and bank.")
    AddCheckbox("detectKnowledge", "Profession Knowledge", "Detect profession knowledge items in bags and bank.")
    AddCheckbox("detectPets",      "Battle Pets",          "Detect uncollected caged battle pets in bags and bank.")
    AddCheckbox("detectDecor",     "Housing Decor",        "Detect housing decor items in bags and bank.")

    if Settings.RegisterCanvasLayoutSubcategory then
        local ignoredPanel = CreateFrame("Frame", "LearnAlertIgnoredItemsSettingsPanel", nil, "BackdropTemplate")
        ignoredPanel:Hide()

        local title = ignoredPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 16, -16)
        title:SetText("Ignored Items")

        local helpText = ignoredPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        helpText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
        helpText:SetText("Drag an item from your bags onto the drop box to ignore it. Use Remove to restore it.")

        local dropBox = CreateFrame("Button", nil, ignoredPanel, "BackdropTemplate")
        dropBox:SetSize(320, 38)
        dropBox:SetPoint("TOPLEFT", helpText, "BOTTOMLEFT", 0, -10)
        dropBox:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        dropBox:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
        dropBox:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)

        local dropLabel = dropBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dropLabel:SetPoint("CENTER")
        dropLabel:SetText("Drop Bag Item Here To Ignore")

        local listHeader = ignoredPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        listHeader:SetPoint("TOPLEFT", dropBox, "BOTTOMLEFT", 0, -14)
        listHeader:SetText("Ignored Item List")

        local scrollFrame = CreateFrame("ScrollFrame", nil, ignoredPanel, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -8)
        scrollFrame:SetPoint("BOTTOMRIGHT", ignoredPanel, "BOTTOMRIGHT", -30, 14)

        local listContent = CreateFrame("Frame", nil, scrollFrame)
        listContent:SetSize(560, 1)
        scrollFrame:SetScrollChild(listContent)
        scrollFrame:SetScript("OnSizeChanged", function(self, width)
            listContent:SetWidth(math.max(1, width - 26))
        end)

        local emptyText = listContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        emptyText:SetPoint("TOPLEFT", 0, 0)
        emptyText:SetText("No ignored items yet.")

        local rowPool = {}
        local rowHeight = 24

        local function CreateRow(index)
            local row = CreateFrame("Frame", nil, listContent)
            row:SetHeight(rowHeight)
            row:SetPoint("TOPLEFT", 0, -((index - 1) * rowHeight))
            row:SetPoint("TOPRIGHT", -6, -((index - 1) * rowHeight))

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(18, 18)
            row.icon:SetPoint("LEFT", 2, 0)

            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.text:SetPoint("RIGHT", -70, 0)
            row.text:SetJustifyH("LEFT")

            row.removeButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.removeButton:SetSize(62, 20)
            row.removeButton:SetPoint("RIGHT", -2, 0)
            row.removeButton:SetText("Remove")
            row.removeButton:SetScript("OnClick", function(self)
                local itemID = self:GetParent().itemID
                if RemoveIgnoredItem(itemID) then
                    local itemName = GetItemInfo(itemID) or ("Item " .. itemID)
                    print(string.format("|cff00a0ff[LearnAlert]|r No longer ignoring |cff888888%s|r.", itemName))
                    ScheduleAlertUpdate(0)
                end
            end)

            row:Hide()
            return row
        end

        local function RefreshIgnoredRows()
            local ignoredIDs = GetSortedIgnoredItemIDs()
            emptyText:SetShown(#ignoredIDs == 0)

            for index, itemID in ipairs(ignoredIDs) do
                local row = rowPool[index]
                if not row then
                    row = CreateRow(index)
                    rowPool[index] = row
                end

                local itemName, itemLink, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemID)
                row.itemID = itemID
                row.icon:SetTexture(itemTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
                if itemLink then
                    row.text:SetText(string.format("%s |cff888888(ID: %d)|r", itemLink, itemID))
                else
                    row.text:SetText(string.format("%s |cff888888(ID: %d)|r", itemName or "Unknown", itemID))
                end
                row:Show()
            end

            for index = #ignoredIDs + 1, #rowPool do
                rowPool[index]:Hide()
            end

            listContent:SetHeight(math.max(1, #ignoredIDs * rowHeight))
        end

        local function TryAddIgnoredFromCursor()
            local cursorType, itemID = GetCursorInfo()
            if cursorType ~= "item" or not itemID then
                return
            end

            ClearCursor()
            if AddIgnoredItem(itemID) then
                local itemName = GetItemInfo(itemID) or ("Item " .. itemID)
                print(string.format("|cff00a0ff[LearnAlert]|r Ignoring |cff888888%s|r.", itemName))
                ScheduleAlertUpdate(0)
            else
                print("|cff00a0ff[LearnAlert]|r That item is already ignored.")
            end
        end

        dropBox:SetScript("OnReceiveDrag", TryAddIgnoredFromCursor)
        dropBox:SetScript("OnMouseUp", function(_, mouseButton)
            if mouseButton == "LeftButton" or mouseButton == "RightButton" then
                TryAddIgnoredFromCursor()
            end
        end)

        ignoredPanel:SetScript("OnShow", RefreshIgnoredRows)
        refreshIgnoredItemsSettingsUI = RefreshIgnoredRows

        local ignoredSubcategory = Settings.RegisterCanvasLayoutSubcategory(category, ignoredPanel, "Ignored Items")
        if ignoredSubcategory then
            Settings.RegisterAddOnCategory(ignoredSubcategory)
        end

        ignoredPanel:Hide()
    end

    Settings.RegisterAddOnCategory(category)
    learnAlertSettingsCategory = category
end

-- Create a clickable item button
local function CreateItemButton(parent, index)
    local button = CreateFrame("Button", "LearnAlertItemButton" .. index, parent, "SecureActionButtonTemplate, BackdropTemplate")
    button:SetSize(220, 28)
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    button:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    button:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    
    -- Icon
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(22, 22)
    button.icon:SetPoint("LEFT", 3, 0)
    
    -- Cooldown frame (shows GCD)
    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetAllPoints(button.icon)
    button.cooldown:SetDrawEdge(false)
    button.cooldown:SetDrawSwipe(true)
    button.cooldown:SetSwipeColor(0, 0, 0, 0.7)
    
    -- Item name text
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.text:SetPoint("LEFT", button.icon, "RIGHT", 5, 0)
    button.text:SetPoint("RIGHT", -5, 0)
    button.text:SetJustifyH("LEFT")
    button.text:SetTextColor(0, 1, 0.5)
    
    -- Highlight texture
    button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
    button.highlight:SetAllPoints()
    button.highlight:SetColorTexture(1, 1, 1, 0.1)
    
    -- Set up secure attributes for item usage
    button:SetAttribute("type", "item")
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:HookScript("PreClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            MarkLearnAlertActionContext(self.itemID, self.bag, self.slot)
        else
            ClearLearnAlertActionContext()
        end
    end)
    
    -- Tooltip
    button:SetScript("OnEnter", function(self)
        if self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.bag and self.slot then
                GameTooltip:SetBagItem(self.bag, self.slot)
            else
                GameTooltip:SetItemByID(self.itemID)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff00ff00Click to learn|r", 1, 1, 1)
            GameTooltip:AddLine("|cff888888Right-click to ignore|r", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Update cooldown when button is clicked
    button:HookScript("OnClick", function(self)
        local mouseBtn = GetMouseButtonClicked()
        if mouseBtn == "RightButton" then
            if self.itemID and not InCombatLockdown() then
                local wasAdded = AddIgnoredItem(self.itemID)
                local itemName = GetItemInfo(self.itemID) or ("Item " .. self.itemID)
                if wasAdded then
                    print(string.format("|cff00a0ff[LearnAlert]|r Ignoring |cff888888%s|r. Type /la unignore %d to restore.", itemName, self.itemID))
                    ScheduleAlertUpdate(0)
                else
                    print(string.format("|cff00a0ff[LearnAlert]|r |cff888888%s|r is already ignored.", itemName))
                end
            end
            return
        end
        PrintDebugClick(string.format(
            "Click row: itemID=%s bag=%s slot=%s mouseButton=%s attrType=%s attrType1=%s attrItem=%s attrItem1=%s macrotext=%s macrotext1=%s",
            tostring(self.itemID),
            tostring(self.bag),
            tostring(self.slot),
            tostring(GetMouseButtonClicked() or "nil"),
            tostring(self:GetAttribute("type")),
            tostring(self:GetAttribute("type1")),
            tostring(self:GetAttribute("item")),
            tostring(self:GetAttribute("item1")),
            tostring(self:GetAttribute("macrotext")),
            tostring(self:GetAttribute("macrotext1"))
        ))

        -- Cooldown can start slightly after click; refresh immediately and with short retries.
        RefreshButtonCooldowns()
        C_Timer.After(0.03, RefreshButtonCooldowns)
        C_Timer.After(0.10, RefreshButtonCooldowns)

        -- Bag updates can be delayed; force quick redraw passes to keep rows bound to live slots.
        C_Timer.After(0.03, function()
            if addon and addon.UpdateAlert and not InCombatLockdown() then
                addon.UpdateAlert()
            end
        end)
        C_Timer.After(0.15, function()
            if addon and addon.UpdateAlert and not InCombatLockdown() then
                addon.UpdateAlert()
            end
        end)
    end)
    
    button:Hide()
    return button
end

-- Update a button with item data
local function UpdateButton(button, itemData, yOffset)
    local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemData.itemID)
    
    button.itemID = itemData.itemID
    button.bag = itemData.bag
    button.slot = itemData.slot
    button.icon:SetTexture(itemTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
    button.text:SetText(itemName or itemData.itemName)
    
    -- Prefer exact bag-slot usage when available to mirror manual right-click behavior.
    if itemData.bag and itemData.slot then
        button:SetAttribute("type", nil)
        button:SetAttribute("item", nil)
        button:SetAttribute("macrotext", nil)
        button:SetAttribute("type1", "macro")
        button:SetAttribute("macrotext1", string.format("/use %d %d", itemData.bag, itemData.slot))
        button:SetAttribute("item1", nil)
        button:SetAttribute("item", nil)
    else
        button:SetAttribute("type", nil)
        button:SetAttribute("macrotext", nil)
        button:SetAttribute("type1", "item")
        button:SetAttribute("macrotext1", nil)
        if itemData.itemLink then
            button:SetAttribute("item1", itemData.itemLink)
        elseif itemName then
            button:SetAttribute("item1", itemName)
        else
            -- Fallback to item ID if name/link not loaded yet.
            button:SetAttribute("item1", "item:" .. itemData.itemID)
        end
        button:SetAttribute("item", nil)
    end
    
    -- Keep row inset symmetric with the right side (240 frame width - 220 button width = 20 total).
    button:SetPoint("TOPLEFT", alertFrame, "TOPLEFT", 10, yOffset)
    button:Show()
end

-- Create the main alert frame
local function CreateAlertFrame()
    local frame = CreateFrame("Frame", "LearnAlertFrame", UIParent, "BackdropTemplate")
    frame:SetSize(240, 150)
    frame:SetPoint("CENTER", UIParent, "CENTER", LearnAlertDB.alertX, LearnAlertDB.alertY)
    frame:SetFrameStrata("DIALOG")
    frame:SetScale(LearnAlertDB.alertScale or 1.0)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    
    -- Background with border for visibility
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    
    -- Title bar
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(24)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    titleBar:SetBackdropColor(0.15, 0.4, 0.15, 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    
    titleBar:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, _, x, y = frame:GetPoint()
        LearnAlertDB.alertX = x
        LearnAlertDB.alertY = y
    end)
    
    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 8, 0)
    title:SetText("Learnable Items")
    title:SetTextColor(1, 1, 1)
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeBtn:SetPoint("RIGHT", -3, 0)
    closeBtn:SetSize(20, 20)
    closeBtn:SetScript("OnClick", function()
        HideAlertUntilShown()
    end)

    -- Hide button (persistent hide until /la show)
    local hideBtn = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
    hideBtn:SetSize(40, 18)
    hideBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    hideBtn:SetText("Hide")
    hideBtn:SetScript("OnClick", function()
        HideAlertUntilShown()
    end)
    
    -- Empty text
    local emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("CENTER", frame, "CENTER", 0, 0)
    emptyText:SetText("No learnable items.")
    emptyText:SetJustifyH("CENTER")
    frame.emptyText = emptyText
    
    frame:Hide()
    return frame
end

-- Update the alert display
local function UpdateAlert()
    if not alertFrame then return end
    if InCombatLockdown() then return end

    if LearnAlertDB and LearnAlertDB.enabled == false then
        alertFrame:Hide()
        return
    end

    if LearnAlertDB and LearnAlertDB.showAlert == false then
        alertFrame:Hide()
        return
    end
    
    local items = ScanForLearnableItems(isBankOpen)
    local totalCount = #items.mounts + #items.toys + #items.transmog + #items.curios + #items.knowledge + #items.pets + #items.decor
    
    if totalCount == 0 then
        alertFrame:Hide()
        return
    end
    
    -- Show alert
    alertFrame:Show()
    LearnAlertDB.showAlert = true
    
    -- Hide all buttons
    for _, button in ipairs(buttonPool) do
        button:Hide()
        button:ClearAllPoints()
    end
    
    alertFrame.emptyText:Hide()
    
    -- Combine all learnable items
    local allItems = BuildAllItemsList(items)
    
    -- Show buttons for each item
    local yOffset = -30
    local numShown = 0
    for i, itemData in ipairs(allItems) do
        if i > MAX_BUTTONS then break end
        
        -- Create button if needed
        if not buttonPool[i] then
            buttonPool[i] = CreateItemButton(alertFrame, i)
        end
        
        UpdateButton(buttonPool[i], itemData, yOffset)
        numShown = numShown + 1
        yOffset = yOffset - 32
    end
    
    -- Resize frame based on content
    alertFrame:SetHeight(38 + (numShown * 32))
    RefreshButtonCooldowns()
end

-- Coalesce bursts of bag/item events into a single update.
ScheduleAlertUpdate = function(delaySeconds)
    if isUpdateScheduled then
        return
    end

    isUpdateScheduled = true
    C_Timer.After(delaySeconds or 0.1, function()
        isUpdateScheduled = false
        if alertFrame and not InCombatLockdown() then
            UpdateAlert()
        end
    end)
end

-- Initialize addon
local function Initialize()
    -- Initialize saved variables
    if not LearnAlertDB then
        LearnAlertDB = {}
    end
    
    for key, value in pairs(defaults) do
        if LearnAlertDB[key] == nil then
            LearnAlertDB[key] = value
        end
    end
    
    -- Create UI
    alertFrame = CreateAlertFrame()
    CreateSettingsPanel()
    RegisterWarningAutoConfirmHook()

    -- Create button pool
    for i = 1, MAX_BUTTONS do
        buttonPool[i] = CreateItemButton(alertFrame, i)
    end
    
    -- Initial check
    C_Timer.After(1, function() ScheduleAlertUpdate(0) end)
    
    -- Set up periodic checks
    C_Timer.NewTicker(LearnAlertDB.checkInterval, function()
        ScheduleAlertUpdate(0)
    end)
    
        PrintMessage("Loaded! Type /la or /learnalert for commands.")
end

-- List learnable items in chat
local function ListLearnables()
    local items = ScanForLearnableItems(isBankOpen)
    
    print("|cff00a0ff[LearnAlert]|r Learnable items:")
    
    if #items.mounts == 0 and #items.toys == 0 and #items.transmog == 0 and #items.curios == 0 and #items.knowledge == 0 and #items.pets == 0 and #items.decor == 0 then
        print("  No learnable items found.")
        return
    end
    
    if #items.mounts > 0 then
        print("|cff00ff00Mounts:|r")
        for _, mount in ipairs(items.mounts) do
            print("  |cffffd700" .. mount.itemName .. "|r (ID: " .. mount.itemID .. ")")
        end
    end
    
    if #items.toys > 0 then
        print("|cffff00ffToys:|r")
        for _, toy in ipairs(items.toys) do
            print("  |cffffd700" .. toy.itemName .. "|r (ID: " .. toy.itemID .. ")")
        end
    end

    if #items.transmog > 0 then
        print("|cff66ff66Transmog:|r")
        for _, transmog in ipairs(items.transmog) do
            print("  |cffffd700" .. transmog.itemName .. "|r (ID: " .. transmog.itemID .. ")")
        end
    end

    if #items.curios > 0 then
        print("|cff33ffaaFollower Curios:|r")
        for _, curio in ipairs(items.curios) do
            print("  |cffffd700" .. curio.itemName .. "|r (ID: " .. curio.itemID .. ")")
        end
    end

    if #items.knowledge > 0 then
        print("|cff66ccffProfession Knowledge:|r")
        for _, knowledge in ipairs(items.knowledge) do
            print("  |cffffd700" .. knowledge.itemName .. "|r (ID: " .. knowledge.itemID .. ")")
        end
    end
    
    if #items.pets > 0 then
        print("|cff00ffffPets:|r")
        for _, pet in ipairs(items.pets) do
            print("  |cffffd700" .. pet.itemName .. "|r (ID: " .. pet.itemID .. ")")
        end
    end
    
    if #items.decor > 0 then
        print("|cffffaa00Housing Decor:|r")
        for _, decor in ipairs(items.decor) do
            print("  |cffffd700" .. decor.itemName .. "|r (ID: " .. decor.itemID .. ") [repeatable]")
        end
    end
end

-- Debug output window
local debugFrame
local function CreateDebugFrame()
    if debugFrame then
        return debugFrame
    end
    
    local frame = CreateFrame("Frame", "LearnAlertDebugFrame", UIParent, "BackdropTemplate")
    frame:SetSize(700, 500)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:Hide()
    
    -- Background
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.95)
    
    -- Title bar
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    titleBar:SetBackdropColor(0.1, 0.5, 0.8, 1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    
    titleBar:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)
    
    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 10, 0)
    title:SetText("LearnAlert Debug Output")
    title:SetTextColor(1, 1, 1)
    frame.title = title
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeBtn:SetPoint("RIGHT", -5, 0)
    closeBtn:SetSize(24, 24)
    closeBtn:SetScript("OnClick", function()
        frame:Hide()
    end)
    
    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "LearnAlertDebugScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 10)
    
    -- Edit box for text content
    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetWidth(650)
    editBox:SetHeight(440)
    editBox:SetFontObject(GameFontWhite)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function()
        frame:Hide()
    end)
    scrollFrame:SetScrollChild(editBox)
    frame.editBox = editBox
    
    debugFrame = frame
    return frame
end

local function ShowDebugWindow(title, text)
    local frame = CreateDebugFrame()
    frame.title:SetText(title or "LearnAlert Debug Output")
    frame.editBox:SetText(text or "")
    frame.editBox:SetCursorPosition(0)
    frame:Show()
end

-- Debug function to show all learnable item types in bags with status
local function DebugMounts()
    local output = {}
    table.insert(output, "LearnAlert - Mount Debug - ALL items in bags")
    if isBankOpen then
        table.insert(output, " and bank")
    end
    table.insert(output, "\n")
    table.insert(output, string.format("C_MountJournal available: %s\n", C_MountJournal and "yes" or "no"))
    table.insert(output, "\n")
    
    local itemCount = 0

    IterateBagItems(function(bag, slot, containerInfo)
        local itemContext = GetBagItemContext(bag, slot, containerInfo)
        local isMountSubClass = (itemContext.itemSubClass == "Mount")
        local mountID = C_MountJournal.GetMountFromItem(itemContext.itemID)
        local mountStatus = "N/A"
        if mountID then
            local name, spellID, icon, isActive, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)
            mountStatus = isCollected and "COLLECTED" or (isUsable and "LEARNABLE" or "UNUSABLE")
        end

        table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
        table.insert(output, string.format("  Class='%s' SubClass='%s'\n", itemContext.itemClass or "nil", itemContext.itemSubClass or "nil"))
        table.insert(output, string.format("  IsMount=%s  MountID=%s  Status=%s\n",
            isMountSubClass and "YES" or "NO",
            mountID and tostring(mountID) or "nil",
            mountStatus))
        table.insert(output, "\n")

        itemCount = itemCount + 1
    end, isBankOpen)

    table.insert(output, string.format("\nTotal items scanned: %d", itemCount))
    
    ShowDebugWindow("LearnAlert - Mount Debug", table.concat(output))
end

-- Detailed pet debugging to inspect bag links and species resolution.
local function DebugPetScan()
    local output = {}
    table.insert(output, "LearnAlert - Pet Debug - ALL items in bags")
    if isBankOpen then
        table.insert(output, " and bank")
    end
    table.insert(output, "\n")
    table.insert(output, string.format("C_PetJournal available: %s\n", C_PetJournal and "yes" or "no"))
    table.insert(output, "\n")
    
    local itemCount = 0

    IterateBagItems(function(bag, slot, containerInfo)
        local itemContext = GetBagItemContext(bag, slot, containerInfo)

        -- Check pet detection
        local speciesID = GetSpeciesIDFromBagSlot(bag, slot, itemContext.itemID, itemContext.bagItemLink, itemContext.itemName)
        local isPetClass = IsBattlePetClassItem(itemContext.itemID)
        local petStatus = "N/A"
        if speciesID then
            local numOwned, limit = C_PetJournal.GetNumCollectedInfo(speciesID)
            numOwned = numOwned or 0
            limit = limit or 3
            petStatus = (numOwned >= limit) and "COLLECTED" or string.format("LEARNABLE (%d/%d)", numOwned, limit)
        elseif isPetClass then
            petStatus = "CANDIDATE"
        end

        table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
        table.insert(output, string.format("  Class='%s' SubClass='%s'\n", itemContext.itemClass or "nil", itemContext.itemSubClass or "nil"))
        table.insert(output, string.format("  IsPetClass=%s  SpeciesID=%s  Status=%s\n",
            isPetClass and "YES" or "NO",
            speciesID and tostring(speciesID) or "nil",
            petStatus))
        -- For unresolved pet-class items, show per-fallback diagnostics.
        if isPetClass and not speciesID then
            local rawSpeciesFromAPI = C_PetJournal.GetPetInfoByItemID(itemContext.itemID)
            local _, _, _, _, _, classIDInfo = GetItemInfoInstant(itemContext.itemID)
            BuildPetSpeciesNameCache()
            local nameMatchIDs = petSpeciesByNameCache[itemContext.itemName or ""]
            local apiNameMatchIDs = type(rawSpeciesFromAPI) == "string" and petSpeciesByNameCache[rawSpeciesFromAPI]
            table.insert(output, string.format("  [DIAG] ClassID=%s  GetPetInfoByItemID=%s  NameCacheHits=%s  APINameHits=%s\n",
                tostring(classIDInfo),
                tostring(rawSpeciesFromAPI),
                nameMatchIDs and tostring(#nameMatchIDs) or "0",
                apiNameMatchIDs and tostring(#apiNameMatchIDs) or "0"))
        end
        table.insert(output, "\n")

        itemCount = itemCount + 1
    end, isBankOpen)

    table.insert(output, string.format("\nTotal items scanned: %d", itemCount))
    
    ShowDebugWindow("LearnAlert - Pet Debug", table.concat(output))
end

-- Detailed toy debugging to inspect item metadata and ToyBox API responses.
local function DebugToys()
    local output = {}
    table.insert(output, "LearnAlert - Toy Debug - ALL items in bags")
    if isBankOpen then
        table.insert(output, " and bank")
    end
    table.insert(output, "\n")
    table.insert(output, string.format("C_ToyBox available: %s\n", C_ToyBox and "yes" or "no"))
    if C_ToyBox then
        table.insert(output, string.format("  C_ToyBox.IsToyKnown: %s\n", C_ToyBox.IsToyKnown and "yes" or "no"))
        table.insert(output, string.format("  C_ToyBox.GetToyInfo: %s\n", C_ToyBox.GetToyInfo and "yes" or "no"))
    end
    table.insert(output, string.format("PlayerHasToy available: %s\n", PlayerHasToy and "yes" or "no"))
    table.insert(output, "\n")
    
    local itemCount = 0

    IterateBagItems(function(bag, slot, containerInfo)
        local itemContext = GetBagItemContext(bag, slot, containerInfo)

        local isToyFunction = IsToyItem(itemContext.itemID, itemContext.itemClass, itemContext.itemSubClass)
        local isToyKnownValue = GetToyKnownState(itemContext.itemID)
        local isToyKnown = "API unavailable"
        if isToyKnownValue ~= nil then
            isToyKnown = isToyKnownValue and "YES" or "NO"
        end

        local toyInfoResult = "nil"
        if C_ToyBox and C_ToyBox.GetToyInfo then
            local toyName, toyIcon = C_ToyBox.GetToyInfo(itemContext.itemID)
            if toyName and toyName ~= "" then
                toyInfoResult = "has data"
            end
        end

        table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
        table.insert(output, string.format("  Class='%s' SubClass='%s'\n", itemContext.itemClass or "nil", itemContext.itemSubClass or "nil"))
        table.insert(output, string.format("  IsToyItem=%s  IsToyKnown=%s  GetToyInfo=%s\n",
            isToyFunction and "YES" or "NO",
            isToyKnown,
            toyInfoResult))
        table.insert(output, "\n")

        itemCount = itemCount + 1
    end, isBankOpen)

    table.insert(output, string.format("\nTotal items scanned: %d", itemCount))
    
    ShowDebugWindow("LearnAlert - Toy Debug", table.concat(output))
end

-- Detailed transmog debugging to inspect metadata and tooltip matching.
local function DebugTransmog()
    local output = {}
    table.insert(output, "LearnAlert - Transmog Debug - ALL items in bags")
    if isBankOpen then
        table.insert(output, " and bank")
    end
    table.insert(output, "\n")
    table.insert(output, string.format("C_TooltipInfo available: %s\n", C_TooltipInfo and "yes" or "no"))
    table.insert(output, string.format("C_TransmogCollection available: %s\n", C_TransmogCollection and "yes" or "no"))
    table.insert(output, "\n")

    local itemCount = 0

    IterateBagItems(function(bag, slot, containerInfo)
        local itemContext = GetBagItemContext(bag, slot, containerInfo)

        local isCandidate = IsPotentialTransmogItem(itemContext)
        local isLearnable = IsLearnableTransmogItem(itemContext)
        local cacheKey = itemContext.bagItemLink or itemContext.itemLink or ("item:" .. itemContext.itemID)
        local cacheState = transmogItemCacheByLink[cacheKey]
        local tooltipTexts = {}

        if C_TooltipInfo then
            if C_TooltipInfo.GetBagItem and itemContext.bag and itemContext.slot then
                AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetBagItem(itemContext.bag, itemContext.slot))
            end

            if C_TooltipInfo.GetHyperlink then
                AddLowerTooltipTexts(tooltipTexts, C_TooltipInfo.GetHyperlink(cacheKey))
            end
        end

        table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
        table.insert(output, string.format("  Class='%s' SubClass='%s'\n", itemContext.itemClass or "nil", itemContext.itemSubClass or "nil"))
        table.insert(output, string.format("  IsTransmogCandidate=%s  IsLearnableTransmog=%s  Cache=%s\n",
            isCandidate and "YES" or "NO",
            isLearnable and "YES" or "NO",
            tostring(cacheState)))

        local itemNameLower = itemContext.itemName and string.lower(itemContext.itemName) or ""
        if string.find(itemNameLower, "ensemble:", 1, true)
            or string.find(itemNameLower, "arsenal:", 1, true) then
            local tooltipLines = {}
            for text in pairs(tooltipTexts) do
                if string.find(text, "collect", 1, true)
                    or string.find(text, "appearance", 1, true)
                    or string.find(text, "ensemble", 1, true)
                    or string.find(text, "arsenal", 1, true)
                    or string.match(text, "%d+%s*/%s*%d+") then
                    table.insert(tooltipLines, text)
                end
            end

            table.sort(tooltipLines)
            if #tooltipLines > 0 then
                table.insert(output, "  Tooltip transmog lines:\n")
                for _, lineText in ipairs(tooltipLines) do
                    table.insert(output, string.format("    - %s\n", lineText))
                end
            else
                table.insert(output, "  Tooltip transmog lines: [none matched]\n")
            end
        end

        table.insert(output, "\n")

        itemCount = itemCount + 1
    end, isBankOpen)

    table.insert(output, string.format("\nTotal items scanned: %d", itemCount))

    ShowDebugWindow("LearnAlert - Transmog Debug", table.concat(output))
end

-- Detailed profession knowledge debugging to inspect metadata and tooltip matching.
local function DebugKnowledge()
    local output = {}
    table.insert(output, "LearnAlert - Profession Knowledge Debug - ALL items in bags")
    if isBankOpen then
        table.insert(output, " and bank")
    end
    table.insert(output, "\n")
    table.insert(output, string.format("C_TooltipInfo available: %s\n", C_TooltipInfo and "yes" or "no"))
    table.insert(output, "\n")

    local itemCount = 0

    IterateBagItems(function(bag, slot, containerInfo)
        local itemContext = GetBagItemContext(bag, slot, containerInfo)
        local isKnowledge = IsProfessionKnowledgeItem(itemContext)
        local cacheState = knowledgeItemCacheByID[itemContext.itemID]

        table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
        table.insert(output, string.format("  Class='%s' SubClass='%s'\n", itemContext.itemClass or "nil", itemContext.itemSubClass or "nil"))
        table.insert(output, string.format("  IsProfessionKnowledge=%s  Cache=%s\n",
            isKnowledge and "YES" or "NO",
            tostring(cacheState)))
        table.insert(output, "\n")

        itemCount = itemCount + 1
    end, isBankOpen)

    table.insert(output, string.format("\nTotal items scanned: %d", itemCount))

    ShowDebugWindow("LearnAlert - Profession Knowledge Debug", table.concat(output))
end

-- Detailed follower curio debugging to inspect metadata and tooltip matching.
local function DebugCurios()
    local output = {}
    table.insert(output, "LearnAlert - Follower Curio Debug - ALL items in bags")
    if isBankOpen then
        table.insert(output, " and bank")
    end
    table.insert(output, "\n")
    table.insert(output, string.format("C_TooltipInfo available: %s\n", C_TooltipInfo and "yes" or "no"))
    table.insert(output, "\n")

    local itemCount = 0

    IterateBagItems(function(bag, slot, containerInfo)
        local itemContext = GetBagItemContext(bag, slot, containerInfo)
        local isCurio = IsFollowerCurioItem(itemContext)
        local cacheState = curioItemCacheByID[itemContext.itemID]

        table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
        table.insert(output, string.format("  Class='%s' SubClass='%s'\n", itemContext.itemClass or "nil", itemContext.itemSubClass or "nil"))
        table.insert(output, string.format("  IsFollowerCurio=%s  Cache=%s\n",
            isCurio and "YES" or "NO",
            tostring(cacheState)))
        table.insert(output, "\n")

        itemCount = itemCount + 1
    end, isBankOpen)

    table.insert(output, string.format("\nTotal items scanned: %d", itemCount))

    ShowDebugWindow("LearnAlert - Follower Curio Debug", table.concat(output))
end

-- Detailed housing decor debugging to inspect item metadata and Housing API responses.
local function DebugDecor()
    local output = {}
    table.insert(output, "LearnAlert - Housing Decor Debug - ALL items in bags")
    if isBankOpen then
        table.insert(output, " and bank")
    end
    table.insert(output, "\n")
    table.insert(output, "Checking for housing decor API availability:\n")
    table.insert(output, string.format("  C_PlayerInteractionManager: %s\n", C_PlayerInteractionManager and "yes" or "no"))
    if C_PlayerInteractionManager then
        table.insert(output, string.format("    C_PlayerInteractionManager.IsDecorKnown: %s\n", C_PlayerInteractionManager.IsDecorKnown and "yes" or "no"))
    end
    table.insert(output, string.format("  C_Housing: %s\n", C_Housing and "yes" or "no"))
    if C_Housing then
        table.insert(output, string.format("    C_Housing.IsDecorKnown: %s\n", C_Housing.IsDecorKnown and "yes" or "no"))
    end
    table.insert(output, string.format("  PlayerHasDecor: %s\n", PLAYER_HAS_DECOR_FN and "yes" or "no"))
    table.insert(output, "\n")
    
    local itemCount = 0

    IterateBagItems(function(bag, slot, containerInfo)
        local itemContext = GetBagItemContext(bag, slot, containerInfo)

        local isDecorFunction = IsDecorItem(itemContext.itemID, itemContext.itemClass, itemContext.itemSubClass)
        local isDecorKnownValue = GetDecorKnownState(itemContext.itemID)
        local isDecorKnown = "UNKNOWN (not used for decor filtering)"
        if isDecorKnownValue ~= nil then
            isDecorKnown = isDecorKnownValue and "YES (not used for decor filtering)" or "NO (not used for decor filtering)"
        end

        table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
        table.insert(output, string.format("  Class='%s' SubClass='%s'\n", itemContext.itemClass or "nil", itemContext.itemSubClass or "nil"))
        table.insert(output, string.format("  IsDecorItem=%s  IsDecorKnown=%s\n",
            isDecorFunction and "YES" or "NO",
            isDecorKnown))
        table.insert(output, "\n")

        itemCount = itemCount + 1
    end, isBankOpen)

    table.insert(output, string.format("\nTotal items scanned: %d", itemCount))
    
    ShowDebugWindow("LearnAlert - Housing Decor Debug", table.concat(output))
end

-- Debug bank inventory specifically
local function DebugBank()
    local output = {}
    table.insert(output, "LearnAlert - Bank Debug\n")
    table.insert(output, string.format("Bank state: %s\n", isBankOpen and "OPEN" or "CLOSED"))
    table.insert(output, "\n")
    
    if not isBankOpen then
        table.insert(output, "Bank is not open. Open your bank to scan bank items.\n")
        ShowDebugWindow("LearnAlert - Bank Debug", table.concat(output))
        return
    end
    
    local itemCount = 0
    local bankItemsFound = false
    
    -- Scan character bank bags (5-12)
    table.insert(output, "=== Character Bank Bags (5-12) ===\n")
    for bag = BANK_CONTAINER_FIRST, BANK_CONTAINER_LAST do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                if containerInfo and containerInfo.itemID then
                    bankItemsFound = true
                    local itemContext = GetBagItemContext(bag, slot, containerInfo)
                    
                    -- Check detection status
                    local mountData = BuildLearnableMountData(itemContext)
                    local toyData = BuildLearnableToyData(itemContext)
                    local transmogData = BuildLearnableTransmogData(itemContext)
                    local curioData = BuildLearnableCurioData(itemContext)
                    local knowledgeData = BuildLearnableKnowledgeData(itemContext)
                    local decorData = BuildLearnableDecorData(itemContext)
                    local isPetClass = IsBattlePetClassItem(itemContext.itemID)
                    local hasBattlePetLink = itemContext.bagItemLink and string.find(itemContext.bagItemLink, "battlepet:", 1, true)
                    local petData = nil
                    if isPetClass or hasBattlePetLink then
                        petData = GetUncollectedPetData(bag, slot, itemContext.itemID, itemContext.bagItemLink, itemContext.itemName, itemContext.itemTexture, itemContext.itemRarity)
                    end
                    
                    local detectionStatus = "None"
                    if mountData then detectionStatus = "MOUNT (learnable)"
                    elseif toyData then detectionStatus = "TOY (learnable)"
                    elseif transmogData then detectionStatus = "TRANSMOG (learnable)"
                    elseif curioData then detectionStatus = "FOLLOWER CURIO (learnable)"
                    elseif knowledgeData then detectionStatus = "PROFESSION KNOWLEDGE (learnable)"
                    elseif decorData then detectionStatus = "DECOR (learnable)"
                    elseif petData then detectionStatus = "PET (learnable)"
                    elseif isPetClass or hasBattlePetLink then detectionStatus = "Pet (already collected)"
                    end
                    
                    table.insert(output, string.format("Bag%d Slot%d: %s (ID:%d)\n", bag, slot, itemContext.itemName or "?", itemContext.itemID))
                    table.insert(output, string.format("  Status: %s\n", detectionStatus))
                    itemCount = itemCount + 1
                end
            end
        end
    end
    
    -- Scan reagent bank
    table.insert(output, "\n=== Reagent Bank ===\n")
    local reagentSlots = C_Container.GetContainerNumSlots(REAGENTBANK_CONTAINER)
    if reagentSlots and reagentSlots > 0 then
        for slot = 1, reagentSlots do
            local containerInfo = C_Container.GetContainerItemInfo(REAGENTBANK_CONTAINER, slot)
            if containerInfo and containerInfo.itemID then
                bankItemsFound = true
                local itemContext = GetBagItemContext(REAGENTBANK_CONTAINER, slot, containerInfo)
                
                local mountData = BuildLearnableMountData(itemContext)
                local toyData = BuildLearnableToyData(itemContext)
                local transmogData = BuildLearnableTransmogData(itemContext)
                local curioData = BuildLearnableCurioData(itemContext)
                local knowledgeData = BuildLearnableKnowledgeData(itemContext)
                local decorData = BuildLearnableDecorData(itemContext)
                local isPetClass = IsBattlePetClassItem(itemContext.itemID)
                local hasBattlePetLink = itemContext.bagItemLink and string.find(itemContext.bagItemLink, "battlepet:", 1, true)
                local petData = nil
                if isPetClass or hasBattlePetLink then
                    petData = GetUncollectedPetData(REAGENTBANK_CONTAINER, slot, itemContext.itemID, itemContext.bagItemLink, itemContext.itemName, itemContext.itemTexture, itemContext.itemRarity)
                end
                
                local detectionStatus = "None"
                if mountData then detectionStatus = "MOUNT (learnable)"
                elseif toyData then detectionStatus = "TOY (learnable)"
                elseif transmogData then detectionStatus = "TRANSMOG (learnable)"
                elseif curioData then detectionStatus = "FOLLOWER CURIO (learnable)"
                elseif knowledgeData then detectionStatus = "PROFESSION KNOWLEDGE (learnable)"
                elseif decorData then detectionStatus = "DECOR (learnable)"
                elseif petData then detectionStatus = "PET (learnable)"
                elseif isPetClass or hasBattlePetLink then detectionStatus = "Pet (already collected)"
                end
                
                table.insert(output, string.format("Reagent Slot%d: %s (ID:%d)\n", slot, itemContext.itemName or "?", itemContext.itemID))
                table.insert(output, string.format("  Status: %s\n", detectionStatus))
                itemCount = itemCount + 1
            end
        end
    else
        table.insert(output, "Reagent bank not accessible\n")
    end
    
    -- Scan warbank
    table.insert(output, "\n=== Warbank Tabs (13-17) ===\n")
    local warbankFound = false
    for bag = ACCOUNTBANK_TAB_FIRST, ACCOUNTBANK_TAB_LAST do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local containerInfo = C_Container.GetContainerItemInfo(bag, slot)
                if containerInfo and containerInfo.itemID then
                    warbankFound = true
                    bankItemsFound = true
                    local itemContext = GetBagItemContext(bag, slot, containerInfo)
                    
                    local mountData = BuildLearnableMountData(itemContext)
                    local toyData = BuildLearnableToyData(itemContext)
                    local transmogData = BuildLearnableTransmogData(itemContext)
                    local curioData = BuildLearnableCurioData(itemContext)
                    local knowledgeData = BuildLearnableKnowledgeData(itemContext)
                    local decorData = BuildLearnableDecorData(itemContext)
                    local isPetClass = IsBattlePetClassItem(itemContext.itemID)
                    local hasBattlePetLink = itemContext.bagItemLink and string.find(itemContext.bagItemLink, "battlepet:", 1, true)
                    local petData = nil
                    if isPetClass or hasBattlePetLink then
                        petData = GetUncollectedPetData(bag, slot, itemContext.itemID, itemContext.bagItemLink, itemContext.itemName, itemContext.itemTexture, itemContext.itemRarity)
                    end
                    
                    local detectionStatus = "None"
                    if mountData then detectionStatus = "MOUNT (learnable)"
                    elseif toyData then detectionStatus = "TOY (learnable)"
                    elseif transmogData then detectionStatus = "TRANSMOG (learnable)"
                    elseif curioData then detectionStatus = "FOLLOWER CURIO (learnable)"
                    elseif knowledgeData then detectionStatus = "PROFESSION KNOWLEDGE (learnable)"
                    elseif decorData then detectionStatus = "DECOR (learnable)"
                    elseif petData then detectionStatus = "PET (learnable)"
                    elseif isPetClass or hasBattlePetLink then detectionStatus = "Pet (already collected)"
                    end
                    
                    table.insert(output, string.format("Warbank%d Slot%d: %s (ID:%d)\n", bag - ACCOUNTBANK_TAB_FIRST + 1, slot, itemContext.itemName or "?", itemContext.itemID))
                    table.insert(output, string.format("  Status: %s\n", detectionStatus))
                    itemCount = itemCount + 1
                end
            end
        end
    end
    
    if not warbankFound then
        table.insert(output, "No warbank items found (may not be available on this account)\n")
    end
    
    if not bankItemsFound then
        table.insert(output, "\nNo items found in any bank containers.\n")
    end
    
    table.insert(output, string.format("\nTotal bank items scanned: %d", itemCount))
    
    ShowDebugWindow("LearnAlert - Bank Debug", table.concat(output))
    
    -- Trigger an alert update after showing debug info
    if alertFrame then
        PrintMessage("Refreshing alert with current scan results...")
        ScheduleAlertUpdate(0.1)
    end
end

-- Slash commands
SLASH_LEARNALERT1 = "/learnalert"
SLASH_LEARNALERT2 = "/la"

local function PrintCommandHelp()
    print("|cff00a0ff[LearnAlert] Commands:|r")
    print("  /la show - Show the alert")
    print("  /la hide - Hide the alert")
    print("  /la toggle - Toggle the alert")
    print("  /la list - List learnable items in chat")
    print("  /la check - Check for learnable items now")
    print("  /la verbose - Toggle verbose messages")
    print("  /la debugmount (/la dm) - Show mount detection diagnostics")
    print("  /la debugpet (/la dp) - Show detailed pet detection diagnostics")
    print("  /la debugtoy (/la dt) - Show detailed toy detection diagnostics")
    print("  /la debugtransmog (/la dtr) - Show detailed transmog detection diagnostics")
    print("  /la debugcurio (/la dcu) - Show detailed follower curio detection diagnostics")
    print("  /la debugknowledge (/la dk) - Show detailed profession knowledge detection diagnostics")
    print("  /la debugdecor (/la dd) - Show detailed housing decor detection diagnostics")
    print("  /la debugbank (/la db) - Show bank inventory and detection status")
    print("  /la debugclick (/la dc) - Toggle click payload debug logging (chat + copy window)")
    print("  /la settings - Open the LearnAlert settings panel")
    print("  /la ignorelist (/la il) - List all ignored items")
    print("  /la unignore <id> (/la ui <id>) - Remove an item from the ignore list")
    print("  /la clearignored (/la ci) - Clear all ignored items")
    print("  /la help - Show this help")
    print(" ")
    print("|cff888888Alert automatically checks for learnable mounts, toys, transmog items, follower curios, profession knowledge items, pets, and housing decor.|r")
end

SlashCmdList["LEARNALERT"] = function(msg)
    local cmd = msg:match("^(%S*)") or ""
    cmd = cmd:lower()
    
    if cmd == "" or cmd == "help" then
        PrintCommandHelp()
        
    elseif cmd == "show" then
        if InCombatLockdown() then
            PrintMessage("Cannot show alert during combat.")
        else
            alertFrame:Show()
            LearnAlertDB.showAlert = true
            UpdateAlert()
        end
        
    elseif cmd == "hide" then
        HideAlertUntilShown()
        
    elseif cmd == "toggle" then
        if InCombatLockdown() then
            PrintMessage("Cannot toggle alert during combat.")
        elseif alertFrame:IsShown() then
            alertFrame:Hide()
            LearnAlertDB.showAlert = false
        else
            alertFrame:Show()
            LearnAlertDB.showAlert = true
            UpdateAlert()
        end
        
    elseif cmd == "list" or cmd == "l" then
        ListLearnables()
        
    elseif cmd == "check" or cmd == "c" then
        if InCombatLockdown() then
            PrintMessage("Cannot check during combat.")
        else
            local items = ScanForLearnableItems(isBankOpen)
            UpdateAlert()
            
            local scanScope = isBankOpen and "bags and bank" or "bags only"
            PrintMessage(string.format(
                "Checked %s: %d mount(s), %d toy(s), %d transmog item(s), %d follower curio(s), %d profession knowledge item(s), %d pet(s), %d decor learnable.",
                scanScope,
                #items.mounts,
                #items.toys,
                #items.transmog,
                #items.curios,
                #items.knowledge,
                #items.pets,
                #items.decor
            ))
        end
    
    elseif cmd == "verbose" or cmd == "v" then
        LearnAlertDB.verbose = not LearnAlertDB.verbose
        print("|cff00a0ff[LearnAlert]|r Verbose mode: " .. (LearnAlertDB.verbose and "ON" or "OFF"))
        
    elseif cmd == "debugmount" or cmd == "dm" then
        DebugMounts()

    elseif cmd == "debugpet" or cmd == "dp" then
        DebugPetScan()
        
    elseif cmd == "debugtoy" or cmd == "dt" then
        DebugToys()

    elseif cmd == "debugtransmog" or cmd == "dtr" then
        DebugTransmog()

    elseif cmd == "debugcurio" or cmd == "dcu" then
        DebugCurios()

    elseif cmd == "debugknowledge" or cmd == "dk" then
        DebugKnowledge()
    
    elseif cmd == "debugdecor" or cmd == "dd" then
        DebugDecor()
    
    elseif cmd == "debugbank" or cmd == "db" then
        DebugBank()

    elseif cmd == "debugclick" or cmd == "dc" then
        LearnAlertDB.debugClicks = not LearnAlertDB.debugClicks
        print("|cff00a0ff[LearnAlert]|r Debug click logging: " .. (LearnAlertDB.debugClicks and "ON" or "OFF"))

    elseif cmd == "ignorelist" or cmd == "il" then
        local ignoredIDs = GetSortedIgnoredItemIDs()
        if #ignoredIDs == 0 then
            print("|cff00a0ff[LearnAlert]|r Ignore list is empty.")
        else
            print("|cff00a0ff[LearnAlert]|r Ignored items:")
            for _, itemID in ipairs(ignoredIDs) do
                local itemName = GetItemInfo(itemID) or "Unknown"
                print(string.format("  |cff888888%s|r (ID: %d) - /la unignore %d", itemName, itemID, itemID))
            end
        end

    elseif cmd == "unignore" or cmd == "ui" then
        local idStr = msg:match("^%S+%s+(.+)$")
        local itemID = tonumber(idStr)
        if not itemID then
            print("|cff00a0ff[LearnAlert]|r Usage: /la unignore <itemID>")
        elseif RemoveIgnoredItem(itemID) then
            local itemName = GetItemInfo(itemID) or ("Item " .. itemID)
            print(string.format("|cff00a0ff[LearnAlert]|r No longer ignoring |cff888888%s|r.", itemName))
            ScheduleAlertUpdate(0)
        else
            print("|cff00a0ff[LearnAlert]|r Item " .. (idStr or "?") .. " is not in the ignore list.")
        end

    elseif cmd == "clearignored" or cmd == "ci" then
        LearnAlertDB.ignoredItems = {}
        if refreshIgnoredItemsSettingsUI then
            refreshIgnoredItemsSettingsUI()
        end
        print("|cff00a0ff[LearnAlert]|r All ignored items cleared.")
        ScheduleAlertUpdate(0)

    elseif cmd == "settings" then
        if not OpenSettingsCategory(learnAlertSettingsCategory) then
            print("|cff00a0ff[LearnAlert]|r Settings panel is unavailable (requires WoW 10.0+).")
        end

    else
        print("|cffff0000[LearnAlert]|r Unknown command: " .. cmd)
        PrintCommandHelp()
    end
end

-- Event handler frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("BAG_NEW_ITEMS_UPDATED")
eventFrame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("BANKFRAME_OPENED")
eventFrame:RegisterEvent("BANKFRAME_CLOSED")
for _, warningEvent in ipairs(WARNING_CONFIRM_EVENTS) do
    eventFrame:RegisterEvent(warningEvent)
end

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == addonName then
        Initialize()
        self:UnregisterEvent("ADDON_LOADED")

    elseif AcceptBindWarningEvent(event, arg1, ...) then
        PrintMessage("Auto-confirmed bind warning from event: " .. tostring(event))

    elseif AcceptRefundWarningEvent(event, arg1, ...) then
        PrintMessage("Auto-confirmed refund warning from event: " .. tostring(event))
        
    elseif event == "BAG_UPDATE_DELAYED" then
        ClearDetectionCaches()
        -- Check for learnable items and update alert
        -- This includes bank items when bank is open
        if alertFrame then
            if isBankOpen then
                -- Use slightly longer delay when bank is open to ensure items are loaded
                ScheduleAlertUpdate(0.25)
            else
                ScheduleAlertUpdate(0.12)
            end
        end
    
    elseif event == "BANKFRAME_OPENED" then
        -- Scan bank bags when bank is opened
        isBankOpen = true
        if alertFrame and LearnAlertDB and LearnAlertDB.enabled then
            PrintMessage("Scanning bank for learnable items...")
            -- Use longer delay to ensure bank items are loaded
            ScheduleAlertUpdate(0.5)
        end
    
    elseif event == "BANKFRAME_CLOSED" then
        -- Stop scanning bank when bank is closed
        isBankOpen = false
        if alertFrame then
            -- Rescan immediately to remove bank items from alert
            ScheduleAlertUpdate(0.1)
        end

    elseif event == "BAG_UPDATE_COOLDOWN" then
        -- Keep row cooldown visuals in sync with item/GCD cooldown state.
        if alertFrame then
            RefreshButtonCooldowns()
        end

    elseif event == "BAG_NEW_ITEMS_UPDATED" then
        ClearDetectionCaches()
        -- Trigger quickly when new purchases/loot are pushed into bags.
        if alertFrame then
            ScheduleAlertUpdate(0.12)
        end

    elseif event == "ITEM_DATA_LOAD_RESULT" or event == "GET_ITEM_INFO_RECEIVED" then
        ClearDetectionCachesForItem(arg1)
        -- Re-scan when item metadata becomes available.
        if alertFrame then
            ScheduleAlertUpdate(0.15)
        end
        
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Check after leaving combat
        if alertFrame then
            ScheduleAlertUpdate(0)
        end
    end
end)

-- Export for external use
addon.UpdateAlert = UpdateAlert
addon.ListLearnables = ListLearnables
addon.ScanForLearnableItems = ScanForLearnableItems
