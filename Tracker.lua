local addonName, ns = ...

-- A slim always-on window listing open orders and what is left to cut.
-- Separate frame from the main config window on purpose: this one is meant to
-- sit on screen while you work, so it carries no settings and no tabs.

ns.Tracker = ns.Tracker or {}
local Tracker = ns.Tracker

local WIDTH = 300
local HEADER_H = 16
local ITEM_H = 16
local MAX_ROWS = 60

local STATUS_SHORT = {
    pending = "|cffffcc00waiting|r",
    grouped = "|cff66ccffgrouped|r",
    mats    = "|cff44ff44mats in|r",
}

local function Save()
    local f = Tracker.frame
    if not f then return end
    local point, _, relPoint, x, y = f:GetPoint()
    ns.db.settings.tracker.point = { point, relPoint, x, y }
end

function Tracker.Create()
    if Tracker.frame then return Tracker.frame end

    local f = CreateFrame("Frame", "CutMasterTracker", UIParent,
        BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(WIDTH, 240)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Save()
    end)
    f:SetClampedToScreen(true)
    ns.UI.Skin(f, 0.05, 0.05, 0.07, 0.92)
    f:Hide()

    local p = ns.db.settings.tracker.point
    if p then
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        f:SetPoint("RIGHT", -20, 0)
    end

    local title = ns.UI.Label(f, "Orders", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -6)
    Tracker.title = title

    local hint = ns.UI.Label(f,
        "|cff666666tick as you cut, right click a name to cancel|r",
        "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 6, 2)

    local close = ns.UI.Button(f, "X", 18, 16)
    close:SetPoint("TOPRIGHT", -6, -5)
    close:SetScript("OnClick", function() Tracker.Hide() end)

    local open = ns.UI.Button(f, "Open", 44, 16)
    open:SetPoint("RIGHT", close, "LEFT", -4, 0)
    open:SetScript("OnClick", function() ns.UI.Toggle() end)

    -- Quick pause without leaving the keyboard for a whole /cm disable: step
    -- away, click once, everything (invites, whispers, barks, trade fill)
    -- goes quiet, click again to resume exactly where it was.
    local power = ns.UI.Button(f, "On", 34, 16)
    power:SetPoint("RIGHT", open, "LEFT", -4, 0)
    power:SetScript("OnClick", function()
        ns.db.settings.enabled = not ns.Enabled()
        if ns.Enabled() then
            if ns.db.settings.bark.enabled then ns.Barker.Start() end
            ns.Print("|cff44ff44enabled.|r")
        else
            ns.Barker.Stop()
            ns.Print("|cffff4444disabled.|r")
        end
        Tracker.Refresh()
    end)
    Tracker.powerButton = power

    local scroll, content = ns.UI.ScrollList(f, -24, 6)
    scroll:SetPoint("TOPLEFT", 4, -24)
    scroll:SetPoint("BOTTOMRIGHT", -24, 16)
    Tracker.content = content
    Tracker.rows = {}

    Tracker.frame = f
    return f
end

local function GetRow(i)
    local row = Tracker.rows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, Tracker.content)
    row:SetSize(WIDTH - 34, ITEM_H)
    row:EnableMouse(true)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(16, 16)
    row.check:SetPoint("LEFT", 0, 0)

    row.text = ns.UI.Label(row, "", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 20, 0)
    row.text:SetWidth(WIDTH - 60)
    row.text:SetJustifyH("LEFT")

    Tracker.rows[i] = row
    return row
end

function Tracker.Refresh()
    local f = Tracker.frame
    if not f or not f:IsShown() then return end

    if Tracker.powerButton then
        local on = ns.Enabled()
        Tracker.powerButton.text:SetText(on and "On" or "Off")
        Tracker.powerButton:SetBackdropColor(
            on and 0.15 or 0.35, on and 0.35 or 0.15, 0.15, 1)
    end

    if not ns.Enabled() then
        Tracker.title:SetText("Orders  |cffff4444DISABLED|r")
        Tracker.content:SetSize(WIDTH - 34, 1)
        for _, row in ipairs(Tracker.rows) do row:Hide() end
        f:SetHeight(90)
        return
    end

    local orders = ns.Orders.OpenList()
    for _, row in ipairs(Tracker.rows) do row:Hide() end

    local used, y, remaining = 0, 0, 0

    for _, o in ipairs(orders) do
        if used >= MAX_ROWS then break end

        used = used + 1
        local head = GetRow(used)
        head.check:Hide()
        head.text:SetPoint("LEFT", 2, 0)
        head.text:SetText(string.format("|cffffffff%s|r  %s",
            o.player, STATUS_SHORT[o.status] or o.status))
        head:SetScript("OnMouseUp", function(_, button)
            if button ~= "RightButton" then return end
            ns.Orders.SetStatus(o, "cancelled",
                GetServerTime and GetServerTime() or time())
            ns.Print(string.format(
                "order #%d for %s cancelled. |cff888888/cm order reopen %d to undo|r",
                o.id, o.player, o.id))
            Tracker.Refresh()
        end)
        head:SetHeight(HEADER_H)
        head:SetPoint("TOPLEFT", 0, -y)
        head:Show()
        y = y + HEADER_H

        for _, it in ipairs(o.items) do
            if used >= MAX_ROWS then break end
            used = used + 1
            local row = GetRow(used)
            local e = ns.db.book[it.itemID]
            local name = e and (e.link or e.name) or tostring(it.itemID)

            row.check:Show()
            row.check:SetChecked(it.cut and true or false)
            row.check:SetScript("OnClick", function(self)
                it.cut = self:GetChecked() and true or false

                -- Ticking the last gem finishes the order. Leaving it open
                -- with everything ticked means the tracker never empties,
                -- which defeats the point of a to-do list.
                if it.cut then
                    local allCut = true
                    for _, other in ipairs(o.items) do
                        if not other.cut then allCut = false break end
                    end
                    if allCut then
                        ns.Orders.SetStatus(o, "done",
                            GetServerTime and GetServerTime() or time())
                        ns.Print(string.format(
                            "|cff44ff44order #%d for %s complete.|r "
                            .. "|cff888888/cm order reopen %d to undo|r",
                            o.id, o.player, o.id))
                    end
                end
                Tracker.Refresh()
            end)

            row:SetScript("OnMouseUp", nil)
            row.text:SetPoint("LEFT", 20, 0)
            local qty = string.format("x%d%s", it.qty or 1,
                it.qtySource == "mats" and "" or "?")
            if it.cut then
                row.text:SetText(string.format("|cff666666%s %s|r", qty, name))
            else
                row.text:SetText(string.format("|cffffcc00%s|r %s", qty, name))
                remaining = remaining + 1
            end

            row:SetHeight(ITEM_H)
            row:SetPoint("TOPLEFT", 0, -y)
            row:Show()
            y = y + ITEM_H
        end
    end

    if #orders == 0 then
        used = used + 1
        local row = GetRow(used)
        row.check:Hide()
        row.text:SetPoint("LEFT", 2, 0)
        row:SetScript("OnMouseUp", nil)
        row.text:SetText(ns.Orders.PendingCount() > 0
            and "|cff888888waiting for them to join|r"
            or "|cff888888no open orders|r")
        row:SetHeight(ITEM_H)
        row:SetPoint("TOPLEFT", 0, -y)
        row:Show()
        y = y + ITEM_H
    end

    local pending = ns.Orders.PendingCount()
    Tracker.title:SetText(string.format(
        "Orders  |cff888888%d open, %d to cut%s|r", #orders, remaining,
        pending > 0 and (", " .. pending .. " not joined") or ""))
    Tracker.content:SetSize(WIDTH - 34, math.max(1, y))
    f:SetHeight(math.min(400, math.max(90, y + 46)))
end

function Tracker.Show()
    Tracker.Create():Show()
    ns.db.settings.tracker.shown = true
    Tracker.Refresh()
    if not Tracker.ticker then
        -- Cheap poll rather than threading refresh calls through every order
        -- mutation. It only runs while the window is actually open.
        Tracker.ticker = C_Timer.NewTicker(1, function() Tracker.Refresh() end)
    end
end

function Tracker.Hide()
    if Tracker.frame then Tracker.frame:Hide() end
    ns.db.settings.tracker.shown = false
    if Tracker.ticker then
        Tracker.ticker:Cancel()
        Tracker.ticker = nil
    end
end

function Tracker.Toggle()
    if Tracker.frame and Tracker.frame:IsShown() then
        Tracker.Hide()
    else
        Tracker.Show()
    end
end

-- Called when an order is created so the window appears on its own the first
-- time there is something to track.
function Tracker.Notify()
    if ns.db.settings.tracker.autoShow and not (Tracker.frame and Tracker.frame:IsShown()) then
        Tracker.Show()
    else
        Tracker.Refresh()
    end
end
