--[[
    LearnAlert - Displays bouncing alerts for learnable mounts, toys, battle pets, and housing decor
    Detects mounts, toys, pets, and housing decor items in bags and bank that the character hasn't learned yet
    
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
    debugClicks = false,
    alertScale = 1.0,
    checkInterval = 2, -- Seconds between checks
}

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
local LEARNABLE_ITEM_ORDER = { "mounts", "toys", "pets", "decor" }
local BATTLEPET_CLASS_ID = (Enum and Enum.ItemClass and Enum.ItemClass.Battlepet) or 17
local PET_CAGE_ITEM_ID = 82800
local PLAYER_HAS_DECOR_FN = rawget(_G, "PlayerHasDecor")
local isUpdateScheduled = false
local isBankOpen = false
---@type GameTooltip
local petScanTooltip = CreateFrame("GameTooltip", "LearnAlertPetScanTooltip", UIParent, "GameTooltipTemplate")
local clickDebugFrame
local clickDebugEditBox
local clickDebugLines = {}

-- Hidden tooltip owner for bag-item metadata parsing.
petScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

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
        pets = {},
        decor = {},
    }
    
    PrintMessage(string.format("Starting scan (includeBank=%s)...", tostring(includeBank)))
    
    local itemsScanned = 0
    local petsChecked = 0
    local petsAdded = 0
    
    IterateBagItems(function(bag, slot, containerInfo)
        itemsScanned = itemsScanned + 1
        local itemContext = GetBagItemContext(bag, slot, containerInfo)

        local mountData = BuildLearnableMountData(itemContext)
        if mountData then
            table.insert(learnableItems.mounts, mountData)
            PrintMessage(string.format("  Found mount: %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
        end

        local toyData = BuildLearnableToyData(itemContext)
        if toyData then
            table.insert(learnableItems.toys, toyData)
            PrintMessage(string.format("  Found toy: %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
        end
        
        local decorData = BuildLearnableDecorData(itemContext)
        if decorData then
            table.insert(learnableItems.decor, decorData)
            PrintMessage(string.format("  Found decor (repeatable): %s (Bag%d Slot%d)", itemContext.itemName or "?", bag, slot))
        end

        local isPetClassItem = IsBattlePetClassItem(itemContext.itemID)
        local hasBattlePetLink = itemContext.bagItemLink and string.find(itemContext.bagItemLink, "battlepet:", 1, true)

        -- Only run pet resolution for likely pet items to avoid heavy work while looting.
        if isPetClassItem or hasBattlePetLink then
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
            GameTooltip:Show()
        end
    end)
    
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Update cooldown when button is clicked
    button:HookScript("OnClick", function(self)
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

    if LearnAlertDB and LearnAlertDB.showAlert == false then
        alertFrame:Hide()
        return
    end
    
    local items = ScanForLearnableItems(isBankOpen)
    local totalCount = #items.mounts + #items.toys + #items.pets + #items.decor
    
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
local function ScheduleAlertUpdate(delaySeconds)
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
    
    if #items.mounts == 0 and #items.toys == 0 and #items.pets == 0 and #items.decor == 0 then
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
    print("  /la debugdecor (/la dd) - Show detailed housing decor detection diagnostics")
    print("  /la debugbank (/la db) - Show bank inventory and detection status")
    print("  /la debugclick (/la dc) - Toggle click payload debug logging (chat + copy window)")
    print("  /la help - Show this help")
    print(" ")
    print("|cff888888Alert automatically checks for learnable mounts, toys, pets, and housing decor.|r")
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
                "Checked %s: %d mount(s), %d toy(s), %d pet(s), %d decor learnable.",
                scanScope,
                #items.mounts,
                #items.toys,
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
    
    elseif cmd == "debugdecor" or cmd == "dd" then
        DebugDecor()
    
    elseif cmd == "debugbank" or cmd == "db" then
        DebugBank()

    elseif cmd == "debugclick" or cmd == "dc" then
        LearnAlertDB.debugClicks = not LearnAlertDB.debugClicks
        print("|cff00a0ff[LearnAlert]|r Debug click logging: " .. (LearnAlertDB.debugClicks and "ON" or "OFF"))
        
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

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" and arg1 == addonName then
        Initialize()
        self:UnregisterEvent("ADDON_LOADED")
        
    elseif event == "BAG_UPDATE_DELAYED" then
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
        -- Trigger quickly when new purchases/loot are pushed into bags.
        if alertFrame then
            ScheduleAlertUpdate(0.12)
        end

    elseif event == "ITEM_DATA_LOAD_RESULT" or event == "GET_ITEM_INFO_RECEIVED" then
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
