local addonName, ns = ...

ns.title = C_AddOns.GetAddOnMetadata(addonName, "Title")

-- Every chat line: the toc title in brackets in the gold of Blizzard's own chat links (ItemRef.lua), the
-- message in the chat frame's own colour.
function ns.Print(message)
    print(NORMAL_FONT_COLOR:WrapTextInColorCode("[" .. ns.title .. "]") .. ": " .. message)
end

-- No window or settings page: the Quest Log itself is the surface. The welcome line names what the addon
-- does, where to start and the help command; the help line opens with the same where-to-start sentence.
local START = "Use the buttons beside the quest count to collapse or track all quests, or tick a zone header to toggle its quests."
local WELCOME = "Adds native tracking and collapse controls to the Quest Log. " .. START
    .. " Type /qlc help for the commands."
local HELP = START .. " Type /qlc intro to see the welcome line and the tip again, or /qlc help for this list."

-- Blizzard's yellow callout as an own HelpTipTemplate frame, never HelpTip:Show, whose shared pool taints the
-- tips Blizzard shows later. Points down at the top controls and aligns right so it stays inside the map.
function ns.AttachTip(target)
    local tip
    local info = {
        text = "Collapse all sections or track all quests here, or tick any zone header.",
        buttonStyle = HelpTip.ButtonStyle.Close,
        targetPoint = HelpTip.Point.TopEdgeCenter,
        alignment = HelpTip.Alignment.Right,
        onAcknowledgeCallback = function()
            if ns.db then ns.db.tipSeen = true end
        end,
    }
    local function ShowTip()
        if not ns.db or ns.db.tipSeen or not target:IsVisible() or (tip and tip:IsShown()) then return end
        if not tip then
            tip = CreateFrame("Frame", nil, target, "HelpTipTemplate")
            tip.width = HelpTip.width
            tip:SetWidth(tip.width)
        end
        tip:Reset()
        tip:Init(target, info, target)
        tip:Show()
    end
    target:HookScript("OnShow", ShowTip)
    if target:IsVisible() then ShowTip() end

    -- The player used a control: the tip goes for good, shown or not.
    local function Retire()
        if tip and tip.info then
            tip:Acknowledge()
        elseif ns.db then
            ns.db.tipSeen = true
        end
    end
    return ShowTip, Retire
end

-- At login the client's own load lines are already in chat.
EventUtil.ContinueOnPlayerLogin(function()
    if ns.firstRun then
        ns.Print(WELCOME)
    end
end)

SLASH_QUESTLOGCONTROLS1, SLASH_QUESTLOGCONTROLS2 = "/questlogcontrols", "/qlc"
SlashCmdList.QUESTLOGCONTROLS = function(message)
    local command = strtrim(message or ""):lower()
    if command == "" or command == "help" or command == "?" then
        ns.Print(HELP)
    elseif command == "intro" then
        ns.Print(WELCOME)
        if ns.db then ns.db.tipSeen = nil end
        if ns.ShowTip then ns.ShowTip() end
    else
        ns.Print("Unknown command. Type /qlc help for the list.")
    end
end
