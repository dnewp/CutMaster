local addonName, ns = ...

ns.Minimap = ns.Minimap or {}
local M = ns.Minimap

local ICON = "Interface\\AddOns\\CutMaster\\CutMaster.tga"

function M.Init()
    local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    local Icon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
    if not LDB or not Icon then return end

    local obj = LDB:NewDataObject("CutMaster", {
        type = "launcher",
        icon = ICON,
        OnClick = function(_, button)
            if button == "MiddleButton" then
                ns.Tracker.Toggle()
            elseif button == "RightButton" then
                -- A real click, so this is a hardware event and the bark can
                -- actually send from here.
                local ok, info = ns.Barker.Tick(true)
                if not ok then ns.Print("bark skipped: " .. tostring(info)) end
            else
                ns.UI.Toggle()
            end
        end,
        OnTooltipShow = function(tt)
            local s = ns.db.settings
            local n, gems = 0, 0
            for _, e in pairs(ns.db.book) do
                if not e.stale then
                    n = n + 1
                    if e.classID == 3 then gems = gems + 1 end
                end
            end
            tt:AddLine("CutMaster")
            if not ns.Enabled() then
                tt:AddLine("|cffff4444DISABLED|r")
            end
            tt:AddLine(string.format("|cffffffff%d|r recipes, |cffffffff%d|r gems, "
                .. "|cffffffff%d|r advertised", n, gems, #ns.Barker.AdvertisedEntries()))
            tt:AddLine(string.format("|cffffffff%d|r open orders",
                #ns.Orders.OpenList()))
            tt:AddLine(string.format("barking %s   invites %s",
                s.bark.enabled and "|cff44ff44on|r" or "|cffff4444off|r",
                s.invite.enabled and "|cff44ff44on|r" or "|cffff4444off|r"))
            if ns.Barker.pending then
                tt:AddLine("|cffffcc00A bark is ready. Right click to send.|r")
            elseif ns.db.settings.bark.enabled then
                tt:AddLine(string.format("|cff888888next bark in %ds|r",
                    ns.Barker.SecondsUntilDue()))
            end
            tt:AddLine(" ")
            tt:AddLine("|cff888888Left click: open CutMaster|r")
            tt:AddLine("|cff888888Right click: send a bark now|r")
            tt:AddLine("|cff888888Middle click: toggle the order tracker|r")
        end,
    })

    ns.db.settings.minimap = ns.db.settings.minimap or {}
    Icon:Register("CutMaster", obj, ns.db.settings.minimap)
    M.obj = obj
    M.icon = Icon
end
