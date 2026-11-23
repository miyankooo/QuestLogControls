local addonName, ns = ...

local C_QuestLog = C_QuestLog
local GetNumQuestLogEntries = C_QuestLog.GetNumQuestLogEntries
local GetInfo = C_QuestLog.GetInfo
local GetQuestWatchType = C_QuestLog.GetQuestWatchType
local AddQuestWatch = C_QuestLog.AddQuestWatch
local RemoveQuestWatch = C_QuestLog.RemoveQuestWatch
local GetNumQuestWatches = C_QuestLog.GetNumQuestWatches
local GetQuestIDForQuestWatchIndex = C_QuestLog.GetQuestIDForQuestWatchIndex
local IsQuestDisabledForSession = C_QuestLog.IsQuestDisabledForSession
local CollapseQuestHeader = CollapseQuestHeader
local ExpandQuestHeader = ExpandQuestHeader
local PlaySound = PlaySound
local SOUNDKIT = SOUNDKIT

-- Native Quest Log geometry (Blizzard_UIPanels_Game/Mainline/QuestMapFrame.xml, Forever 1.60.1):
-- QuestLogTitleTemplate (leftPadding 4, width 290) places its 14x14 Checkbox at TOPRIGHT -> x 280..294 (center 287).
-- QuestLogHeaderTemplate (leftPadding 9, width 289) ends at x 298 -> RIGHT -4 aligns its checkbox at x 280..294 (center 287).
-- Header CollapseButton (20x20) sits 4 px left of the checkbox -> x 256..276 (center 266).
-- Top bar buttons sit at y +17 above QuestScrollFrame TOP (matching SearchBox, QuestLogCount and SettingsDropdown).
local CHECKBOX_SIZE = 14
local COLLAPSE_SIZE = 20
local PARTIAL_WIDTH = 6
local PARTIAL_HEIGHT = 2
local HEADER_CHECKBOX_RIGHT = -4
local HEADER_CONTROL_GAP = -4
local TOP_CENTER_Y = 17
local TOP_COLLAPSE_CENTER_X = 266
local TOP_TRACK_CENTER_X = 287
local SEARCH_WIDTH_MKB = 142
local SEARCH_WIDTH_GAMEPAD = 132
local SEARCH_WIDTH_NO_COUNT = 244

local zoneButtons = setmetatable({}, { __mode = "k" })
local allCollapseButton, allTrackButton
local hooked = false
local retireTip

local function IsTrackableQuest(info)
    return info and not info.isHeader and info.questID and info.questID > 0 and not info.isHidden and not info.isTask
end

local function CanUntrack()
    return QuestUtil and QuestUtil.CanRemoveQuestWatch and QuestUtil.CanRemoveQuestWatch()
end

-- Header counts without allocating a table.
local function GetHeaderState()
    local total, collapsed = 0, 0
    for i = 1, GetNumQuestLogEntries() do
        local info = GetInfo(i)
        if info and info.isHeader then
            total = total + 1
            if info.isCollapsed then
                collapsed = collapsed + 1
            end
        end
    end
    return total, collapsed
end

-- Global quest tracking counts without allocating a table.
local function GetAllTrackState()
    local total, watched = 0, 0
    for i = 1, GetNumQuestLogEntries() do
        local info = GetInfo(i)
        if IsTrackableQuest(info) then
            total = total + 1
            if GetQuestWatchType(info.questID) ~= nil then
                watched = watched + 1
            end
        end
    end
    return total, watched
end

-- Zone quest tracking counts for one header without allocating a table.
local function GetZoneTrackState(header)
    local index = header and header.questLogIndex
    local info = index and GetInfo(index)
    if not info or not info.isHeader or (header.sortKey and info.headerSortKey ~= header.sortKey) then
        return 0, 0, nil
    end
    local total, watched = 0, 0
    for i = index + 1, GetNumQuestLogEntries() do
        local quest = GetInfo(i)
        if quest then
            if quest.isHeader then break end
            if IsTrackableQuest(quest) then
                total = total + 1
                if GetQuestWatchType(quest.questID) ~= nil then
                    watched = watched + 1
                end
            end
        end
    end
    return total, watched, info.title
end

local function SetCheckboxVisual(button, total, watched)
    local allWatched = total > 0 and watched == total
    local partial = watched > 0 and watched < total
    local blocked = (total == 0) or (allWatched and not CanUntrack())
    button.CheckMark:SetShown(allWatched)
    button.Partial:SetShown(partial)
    button:SetEnabled(not blocked)
    button:SetAlpha(blocked and 0.4 or 1)
end

-- Matches Blizzard's QuestLogTrackCheckboxTemplate (QuestMapFrame.xml:152-180): native 14x14 ticksquare,
-- native 17x14 yellow checkmark at (1, 1), and native ADD 0.4 ticksquare glow so size and glow align cleanly.
local function CreateTrackCheckbox(parent, onClick, fillTooltip)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(CHECKBOX_SIZE, CHECKBOX_SIZE)
    button:SetHitRectInsets(-3, -3, -4, -4)
    button:RegisterForClicks("LeftButtonUp")
    button:SetMotionScriptsWhileDisabled(true)

    local box = button:CreateTexture(nil, "BACKGROUND")
    box:SetAtlas("questlog-icon-ticksquare", true)
    box:SetPoint("CENTER")

    local check = button:CreateTexture(nil, "ARTWORK")
    check:SetAtlas("questlog-icon-checkmark-yellow", true)
    check:SetPoint("CENTER", 1, 1)
    check:Hide()
    button.CheckMark = check

    local partial = button:CreateTexture(nil, "ARTWORK")
    partial:SetSize(PARTIAL_WIDTH, PARTIAL_HEIGHT)
    partial:SetPoint("CENTER")
    partial:SetColorTexture(NORMAL_FONT_COLOR:GetRGB())
    partial:SetSnapToPixelGrid(true)
    partial:SetTexelSnappingBias(0)
    partial:Hide()
    button.Partial = partial

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAtlas("questlog-icon-ticksquare", true)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.4)
    highlight:SetPoint("CENTER")

    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        fillTooltip(GameTooltip, self)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    if SmartNavigation_MarkFrameIgnored then
        SmartNavigation_MarkFrameIgnored(button)
    end
    return button
end

-- Matches Blizzard's CollapseButtonTemplate (ListTemplates.xml:3-20) without propagating clicks to a parent.
local function CreateCollapseButton(parent, onClick, fillTooltip)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(COLLAPSE_SIZE, COLLAPSE_SIZE)
    button:RegisterForClicks("LeftButtonUp")
    button:SetMotionScriptsWhileDisabled(true)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    button.Icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.4)
    highlight:SetPoint("TOPLEFT", icon)
    highlight:SetPoint("BOTTOMRIGHT", icon)
    button.Highlight = highlight

    button:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then
            self.pressed = true
            self.Icon:AdjustPointsOffset(1, -1)
        end
    end)
    button:SetScript("OnMouseUp", function(self)
        if self.pressed then
            self.pressed = false
            self.Icon:AdjustPointsOffset(-1, 1)
        end
    end)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        fillTooltip(GameTooltip, self)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    function button:SetCollapsed(collapsed)
        local atlas = collapsed and "common-button-list-plus" or "common-button-list-minus"
        self.Icon:SetAtlas(atlas, true)
        self.Highlight:SetAtlas(atlas, true)
    end

    if SmartNavigation_MarkFrameIgnored then
        SmartNavigation_MarkFrameIgnored(button)
    end
    return button
end

local function ApplySearchWidth()
    local scrollFrame = QuestMapFrame and QuestMapFrame.QuestsFrame and QuestMapFrame.QuestsFrame.ScrollFrame
    local searchBox = scrollFrame and scrollFrame.SearchBox
    if not searchBox then return end
    if QuestLogCount and QuestLogCount:IsShown() then
        local width = (InputUtil and InputUtil.IsMKBUIEnabled and not InputUtil.IsMKBUIEnabled())
            and SEARCH_WIDTH_GAMEPAD or SEARCH_WIDTH_MKB
        searchBox:SetWidth(width)
    else
        searchBox:SetWidth(SEARCH_WIDTH_NO_COUNT)
    end
end

local function FillAllCollapseTooltip(tooltip)
    local total, collapsed = GetHeaderState()
    local expand = total > 0 and collapsed == total
    GameTooltip_SetTitle(tooltip, expand and "Expand All" or "Collapse All")
    GameTooltip_AddNormalLine(
        tooltip,
        expand and "Expand every section in your quest log." or "Collapse every section in your quest log."
    )
    if total == 0 then
        GameTooltip_AddErrorLine(tooltip, "No quest sections to toggle.")
    end
end

local function FillAllTrackTooltip(tooltip)
    local total, watched = GetAllTrackState()
    local allWatched = total > 0 and watched == total
    GameTooltip_SetTitle(tooltip, allWatched and QUEST_LOG_UNTRACK_ALL or QUEST_LOG_TRACK_ALL)
    if total > 0 then
        GameTooltip_AddNormalLine(
            tooltip,
            string.format("%d of %d |4quest:quests; tracked.", watched, total)
        )
        GameTooltip_AddNormalLine(
            tooltip,
            allWatched and "Click to untrack every quest in your log." or "Click to track every quest in your log."
        )
    else
        GameTooltip_AddErrorLine(tooltip, "No quests to track.")
    end
    if allWatched and not CanUntrack() then
        GameTooltip_AddErrorLine(tooltip, "Quest untracking is currently restricted.")
    end
end

local function FillZoneTrackTooltip(tooltip, button)
    local total, watched, title = GetZoneTrackState(button.header)
    local allWatched = total > 0 and watched == total
    GameTooltip_SetTitle(tooltip, allWatched and QUEST_LOG_UNTRACK_ALL or QUEST_LOG_TRACK_ALL)
    if title then
        GameTooltip_AddColoredLine(tooltip, title, NORMAL_FONT_COLOR)
    end
    if total > 0 then
        GameTooltip_AddNormalLine(
            tooltip,
            string.format("%d of %d |4quest:quests; tracked.", watched, total)
        )
    else
        GameTooltip_AddErrorLine(tooltip, "No quests to track in this section.")
    end
    if allWatched and not CanUntrack() then
        GameTooltip_AddErrorLine(tooltip, "Quest untracking is currently restricted.")
    end
end

local Refresh

local function ToggleAllHeaders()
    local total, collapsed = GetHeaderState()
    if total == 0 then return end
    if retireTip then retireTip() end
    local expand = collapsed == total
    local scrollFrame = QuestMapFrame.QuestsFrame.ScrollFrame
    if scrollFrame.SearchBox and scrollFrame.SearchBox:GetText() ~= "" then
        scrollFrame.SearchBox:Clear()
    end
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    for i = GetNumQuestLogEntries(), 1, -1 do
        local info = GetInfo(i)
        if info and info.isHeader then
            if expand and info.isCollapsed then
                ExpandQuestHeader(i)
            elseif not expand and not info.isCollapsed then
                CollapseQuestHeader(i)
            end
        end
    end
    scrollFrame:SetVerticalScroll(0)
    Refresh()
end

local function ToggleAllTracking()
    local total, watched = GetAllTrackState()
    if total == 0 then return end
    local remove = watched == total
    if remove and not CanUntrack() then
        UIErrorsFrame:AddExternalErrorMessage("Quest untracking is currently restricted.")
        return
    end
    if retireTip then retireTip() end
    PlaySound(remove and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)

    local questIDs = {}
    if remove then
        for i = 1, GetNumQuestWatches() do
            local questID = GetQuestIDForQuestWatchIndex(i)
            if questID then
                questIDs[#questIDs + 1] = questID
            end
        end
        for _, questID in ipairs(questIDs) do
            if not CanUntrack() then break end
            RemoveQuestWatch(questID)
        end
    else
        for i = 1, GetNumQuestLogEntries() do
            local info = GetInfo(i)
            if IsTrackableQuest(info) and GetQuestWatchType(info.questID) == nil then
                questIDs[#questIDs + 1] = info.questID
            end
        end
        local maxWatches = Constants and Constants.QuestWatchConsts and Constants.QuestWatchConsts.MAX_QUEST_WATCHES
        local hitLimit = false
        for _, questID in ipairs(questIDs) do
            if not IsQuestDisabledForSession(questID) then
                if maxWatches and GetNumQuestWatches() >= maxWatches then
                    hitLimit = true
                    break
                end
                AddQuestWatch(questID)
            end
        end
        if hitLimit then
            UIErrorsFrame:AddExternalErrorMessage(OBJECTIVES_WATCH_TOO_MANY)
        end
    end
    Refresh()
end

local function ToggleZoneTracking(button)
    local header = button.header
    local total, watched = GetZoneTrackState(header)
    if total == 0 then return end
    local remove = watched == total
    if remove and not CanUntrack() then
        UIErrorsFrame:AddExternalErrorMessage("Quest untracking is currently restricted.")
        return
    end
    if retireTip then retireTip() end
    PlaySound(remove and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)

    local questIDs = {}
    for i = header.questLogIndex + 1, GetNumQuestLogEntries() do
        local quest = GetInfo(i)
        if quest then
            if quest.isHeader then break end
            if IsTrackableQuest(quest) then
                questIDs[#questIDs + 1] = quest.questID
            end
        end
    end

    local maxWatches = Constants and Constants.QuestWatchConsts and Constants.QuestWatchConsts.MAX_QUEST_WATCHES
    local hitLimit = false
    for _, questID in ipairs(questIDs) do
        local isWatched = GetQuestWatchType(questID) ~= nil
        if remove and isWatched then
            if not CanUntrack() then break end
            RemoveQuestWatch(questID)
        elseif not remove and not isWatched and not IsQuestDisabledForSession(questID) then
            if maxWatches and GetNumQuestWatches() >= maxWatches then
                hitLimit = true
                break
            end
            AddQuestWatch(questID)
        end
    end
    if hitLimit then
        UIErrorsFrame:AddExternalErrorMessage(OBJECTIVES_WATCH_TOO_MANY)
    end
    Refresh()
end

local function GetOrCreateZoneButton(header)
    local button = zoneButtons[header]
    if not button then
        button = CreateTrackCheckbox(header, ToggleZoneTracking, FillZoneTrackTooltip)
        button.header = header
        button:SetPoint("RIGHT", header, "RIGHT", HEADER_CHECKBOX_RIGHT, 0)
        zoneButtons[header] = button
    end
    button:SetFrameLevel(header:GetFrameLevel() + 2)
    return button
end

Refresh = function()
    local scrollFrame = QuestMapFrame and QuestMapFrame.QuestsFrame and QuestMapFrame.QuestsFrame.ScrollFrame
    if not scrollFrame or not scrollFrame:IsShown() then return end

    if allCollapseButton then
        local totalHeaders, collapsedHeaders = GetHeaderState()
        local allCollapsed = totalHeaders > 0 and collapsedHeaders == totalHeaders
        allCollapseButton:SetCollapsed(allCollapsed)
        allCollapseButton:SetEnabled(totalHeaders > 0)
        allCollapseButton:SetAlpha(totalHeaders > 0 and 1 or 0.4)
        if GameTooltip:IsOwned(allCollapseButton) then
            GameTooltip:ClearLines()
            FillAllCollapseTooltip(GameTooltip)
            GameTooltip:Show()
        end
    end

    if allTrackButton then
        local totalQuests, watchedQuests = GetAllTrackState()
        SetCheckboxVisual(allTrackButton, totalQuests, watchedQuests)
        if GameTooltip:IsOwned(allTrackButton) then
            GameTooltip:ClearLines()
            FillAllTrackTooltip(GameTooltip)
            GameTooltip:Show()
        end
    end

    local pool = scrollFrame.headerFramePool
    if not pool then return end
    for header in pool:EnumerateActive() do
        if header.CollapseButton then
            local button = GetOrCreateZoneButton(header)
            header.CollapseButton:ClearAllPoints()
            header.CollapseButton:SetPoint("RIGHT", button, "LEFT", HEADER_CONTROL_GAP, 0)
            local total, watched = GetZoneTrackState(header)
            SetCheckboxVisual(button, total, watched)
            button:Show()
            if GameTooltip:IsOwned(button) then
                GameTooltip:ClearLines()
                FillZoneTrackTooltip(GameTooltip, button)
                GameTooltip:Show()
            end
        end
    end
end

local function Initialize()
    if hooked or not ns.db then return end
    local scrollFrame = QuestMapFrame and QuestMapFrame.QuestsFrame and QuestMapFrame.QuestsFrame.ScrollFrame
    if not scrollFrame then return end

    allCollapseButton = CreateCollapseButton(scrollFrame, ToggleAllHeaders, FillAllCollapseTooltip)
    allCollapseButton:SetPoint("CENTER", scrollFrame, "TOPLEFT", TOP_COLLAPSE_CENTER_X, TOP_CENTER_Y)

    allTrackButton = CreateTrackCheckbox(scrollFrame, ToggleAllTracking, FillAllTrackTooltip)
    allTrackButton:SetPoint("CENTER", scrollFrame, "TOPLEFT", TOP_TRACK_CENTER_X, TOP_CENTER_Y)

    ns.ShowTip, retireTip = ns.AttachTip(allTrackButton)

    hooksecurefunc("QuestLogQuests_Update", Refresh)
    hooksecurefunc("QuestLogQuests_ShowQuestCount", ApplySearchWidth)
    scrollFrame:HookScript("OnShow", function()
        ApplySearchWidth()
        Refresh()
    end)

    hooked = true
    ApplySearchWidth()
    Refresh()
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
events:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name == addonName then
            ns.firstRun = QuestLogControlsDB == nil
            if type(QuestLogControlsDB) ~= "table" then
                QuestLogControlsDB = {}
            end
            ns.db = QuestLogControlsDB
        end
        Initialize()
        if hooked and ns.db then
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "QUEST_WATCH_LIST_CHANGED" then
        Refresh()
    end
end)
