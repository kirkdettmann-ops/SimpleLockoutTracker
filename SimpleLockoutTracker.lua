local _, AddonTable = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("UPDATE_INSTANCE_INFO")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

local lockouts = {}

-- Helper to safely request info
local function UpdateLockouts()
    wipe(lockouts)
    local numSaved = GetNumSavedInstances()
    
    for i = 1, numSaved do
        local name, id, reset, diff, locked, ext, instIDMostSig, isRaid, maxPlayers, diffName, numEncounters, encounterProgress = GetSavedInstanceInfo(i)
        
        if locked then
            lockouts[name] = {
                reset = reset,
                encounters = numEncounters,
                progress = encounterProgress,
                name = name,
                diffName = diffName
            }
            
            -- LFG tool usually displays format like "Mana Tombs (Heroic)"
            if diffName then
                lockouts[name .. " (" .. diffName .. ")"] = lockouts[name]
                -- Sometimes it omits the space, let's cover that just in case
                lockouts[name .. "(" .. diffName .. ")"] = lockouts[name]
            end
        end
    end
end

frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        RequestRaidInfo() -- Request the lockout info from the server when logging in
    elseif event == "UPDATE_INSTANCE_INFO" then
        UpdateLockouts()
    end
end)

-- Helper to normalize instance names for robust fuzzy matching
local function NormalizeName(str)
    if not str then return "" end
    str = string.lower(str)
    str = string.gsub(str, "[%p]", "") -- Remove punctuation (colons, parentheses, apostrophes)
    
    local prefixes = {
        "^coilfang ", "^hellfire citadel ", "^auchindoun ", "^tempest keep ", "^caverns of time ", "^the ", "^hellfire "
    }
    for _, prefix in ipairs(prefixes) do
        str = string.gsub(str, prefix, "")
    end
    -- Strip out confusing inner grammar that APIs interject
    str = string.gsub(str, " of the ", " ")
    str = string.gsub(str, " of ", " ")
    str = string.gsub(str, " the ", " ")
    
    -- Second pass to catch "The" if it was disguised behind a hub name (e.g., "Coilfang: The Underbog")
    str = string.gsub(str, "^the ", "")
    str = string.gsub(str, "%s+", " ")
    return strtrim(str)
end

-- Helper to locate the active LFG frame dynamically
local function GetLFGParent()
    if LFGListingFrame and LFGListingFrame:IsVisible() then return LFGListingFrame end
    if LookingForGroupFrame and LookingForGroupFrame:IsVisible() then return LookingForGroupFrame end
    if LFGListFrame and LFGListFrame:IsVisible() then return LFGListFrame end
    if PVEFrame and PVEFrame:IsVisible() then return PVEFrame end
    if LFDParentFrame and LFDParentFrame:IsVisible() then return LFDParentFrame end
    return nil
end

-- Creates the padlock icon with hover tooltip
local function CreatePadlock(parent, textRegion)
    -- Attach icon to the right of the font string
    local icon = CreateFrame("Frame", nil, parent)
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", textRegion, "RIGHT", 4, 0)
    
    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-LOCK")
    
    icon:EnableMouse(true)
    icon:SetScript("OnEnter", function(self)
        if self.lockoutInfo then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            
            local displayName = self.lockoutInfo.name
            if self.lockoutInfo.diffName then
                displayName = displayName .. " (" .. self.lockoutInfo.diffName .. ")"
            end
            GameTooltip:SetText(displayName)
            
            local resetTime = self.lockoutInfo.reset or 0
            local timeString = ""
            if resetTime > 86400 then
                timeString = math.floor(resetTime / 86400) .. " Days"
            elseif resetTime > 3600 then
                timeString = math.floor(resetTime / 3600) .. " Hours"
            else
                timeString = math.floor(resetTime / 60) .. " Mins"
            end
            
            GameTooltip:AddLine("Expires in: " .. timeString, 1, 1, 1)
            
            local prog = self.lockoutInfo.progress or 0
            local enc = self.lockoutInfo.encounters or 0
            if enc > 0 then
                GameTooltip:AddLine("Bosses Defeated: " .. prog .. " / " .. enc, 1, 0, 0)
            end
            
            GameTooltip:Show()
        end
    end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    
    return icon
end

-- Periodically scans the visible UI for LFG rows matching our lockouts
local function ScanUI()
    local parentFrame = GetLFGParent()
    if not parentFrame then return end
    
    -- Stack-based recursive search to find dungeon list items
    local toProcess = {parentFrame}
    local maxDepth = 400 -- safety catch to prevent infinite loops
    
    while #toProcess > 0 and maxDepth > 0 do
        local current = table.remove(toProcess)
        maxDepth = maxDepth - 1
        
        if current and not current:IsForbidden() then
            local objType = current:GetObjectType()
            
            -- LFG dungeons are usually represented as CheckButtons or Buttons
            if objType == "CheckButton" or objType == "Button" then
                -- Get the FontString to read the dungeon name
                local regions = {current:GetRegions()}
                local hasLockout = false
                
                for _, region in ipairs(regions) do
                    if region:GetObjectType() == "FontString" then
                        local text = region:GetText()
                        
                        -- Only process valid, non-empty text strings
                        if text and strtrim(text) ~= "" then
                            local normText = NormalizeName(text)
                            local matchedLockout = nil
                            
                            for lockoutName, lockoutData in pairs(lockouts) do
                                local normLockout = NormalizeName(lockoutName)
                                -- Fuzzy match: check if either normalized string is contained within the other
                                if normText ~= "" and normLockout ~= "" and (string.find(normText, normLockout, 1, true) or string.find(normLockout, normText, 1, true)) then
                                    -- Strict Override: Prevent Heroic lockouts from falsely triggering on Normal dungeon rows
                                    if lockoutData.diffName == "Heroic" and not string.find(normText, "heroic", 1, true) then
                                        -- Skip match
                                    else
                                        matchedLockout = lockoutData
                                        break
                                    end
                                end
                            end
                            
                            -- If the normalized strings aggressively match each other
                            if matchedLockout then
                                hasLockout = true
                                if not current.lockoutPadlock then
                                    current.lockoutPadlock = CreatePadlock(current, region)
                                end
                                
                                -- Anchor padlock universally to a static rigid offset so they stack in a perfect column
                                -- We dynamically position it ~230 pixels right of the checkbox, slipping it perfectly into the green margin!
                                current.lockoutPadlock:ClearAllPoints()
                                current.lockoutPadlock:SetPoint("LEFT", current, "LEFT", 225, 0) -- Change 225 to nudge padlock Left/Right!
                                
                                current.lockoutPadlock.lockoutInfo = matchedLockout
                                current.lockoutPadlock:Show()
                                
                                -- Re-apply Red text formatting specifically for match
                                local r, g, b = region:GetTextColor()
                                if r ~= 1 or g ~= 0 or b ~= 0 then
                                    region:SetTextColor(1, 0, 0)
                                end
                            else
                                -- If this frame was previously tagged red by us, safely restore standard gold.
                                -- (Blizzard's native UI code will safely auto-correct this if it needs to be grayed out natively)
                                local r, g, b = region:GetTextColor()
                                if r == 1 and g == 0 and b == 0 then
                                    region:SetTextColor(1, 0.82, 0)
                                end
                            end
                        end
                    end
                end
                
                -- Only hide the padlock if NO strings on this entire row uniquely matched a lockout
                if not hasLockout and current.lockoutPadlock then
                    current.lockoutPadlock:Hide()
                end
            end
            
            -- Add children to the stack to process
            local children = {current:GetChildren()}
            for _, child in ipairs(children) do
                table.insert(toProcess, child)
            end
        end
    end
end

-- Ultra-fast highly optimized background ticker (0.05 seconds = 20 FPS). 
-- This makes padlock/color generation instantaneous when scrolling without causing any performance lag.
C_Timer.NewTicker(0.05, ScanUI)

-- ==========================================================
-- DEBUG SLASH COMMAND
-- ==========================================================
SLASH_SIMPLELOCKOUT1 = "/sltdebug"
SlashCmdList["SIMPLELOCKOUT"] = function(msg)
    print("--- Simple Lockout Tracker Debug ---")
    local numLockouts = 0
    print("Active Lockout Keys:")
    for k, v in pairs(lockouts) do
        print("  - [" .. k .. "] => " .. v.name)
        numLockouts = numLockouts + 1
    end
    if numLockouts == 0 then print("  (No lockouts detected)") end
    
    local parent = GetLFGParent()
    if not parent then
        print("LFG Window State: NOT VISIBLE")
    else
        local parentName = parent:GetName() or "UnknownName"
        print("LFG Window State: VISIBLE (" .. parentName .. ")")
        
        local textCount = 0
        local toProcess = {parent}
        local maxDepth = 400
        print("Extracted Row Texts (from Buttons/CheckButtons):")
        while #toProcess > 0 and maxDepth > 0 do
            local current = table.remove(toProcess)
            maxDepth = maxDepth - 1
            if current and not current:IsForbidden() then
                local objType = current:GetObjectType()
                if objType == "CheckButton" or objType == "Button" then
                    local regions = {current:GetRegions()}
                    for _, region in ipairs(regions) do
                        if region:GetObjectType() == "FontString" then
                            local rawText = region:GetText()
                            if rawText then
                                local trimmedText = strtrim(rawText)
                                if trimmedText ~= "" then
                                    print("  Found: '" .. trimmedText .. "'")
                                    textCount = textCount + 1
                                end
                            end
                        end
                    end
                end
                for _, child in ipairs({current:GetChildren()}) do
                    table.insert(toProcess, child)
                end
            end
        end
        print("Total extracted texts: " .. textCount)
        if textCount == 0 then
            print("WARNING: Found 0 texts. UI elements might not be Buttons, or LFG frame name is wrong.")
        end
    end
    print("---------------------------------")
end
