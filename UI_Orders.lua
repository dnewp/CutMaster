local addonName, ns = ...

-- Orders and Income tabs. Kept out of UI.lua, which owns the frame, tabs and
-- the Book/Bark/Filter/Log/Invite pages.

ns.UI = ns.UI or {}
local UI = ns.UI

local STATUS_COLOR = {
    pending   = "|cffffcc00",
    grouped   = "|cff66ccff",
    mats      = "|cff44ff44",
    done      = "|cff888888",
    cancelled = "|cff888888",
}

local MAX_SPLIT_ROWS = 5
local ROW_BASE_H = 40

--------------------------------------------------------------------------------
-- Orders
--------------------------------------------------------------------------------

function UI.BuildOrders(page)
    local nameBox = CreateFrame("EditBox", nil, page,
        BackdropTemplateMixin and "BackdropTemplate")
    nameBox:SetSize(160, 22)
    nameBox:SetPoint("TOPLEFT", 0, 0)
    nameBox:SetAutoFocus(false)
    nameBox:SetFontObject("GameFontHighlightSmall")
    nameBox:SetTextInsets(6, 6, 0, 0)
    UI.Skin(nameBox, 0.1, 0.1, 0.12, 1)

    local function addOrder()
        local who = ns.Util.Trim(nameBox:GetText() or "")
        if who == "" then
            ns.Print("type a player name first.")
            return
        end
        local now = GetServerTime and GetServerTime() or time()
        if ns.Orders.Open(who) then
            ns.Print(who .. " already has an open order.")
        else
            local o = ns.Orders.Create(who, "manual", "", {}, now, "grouped")
            ns.Print(string.format("order #%d opened for %s. "
                .. "Trade them the mats and it fills itself in.", o.id, who))
        end
        nameBox:SetText("")
        nameBox:ClearFocus()
        UI.RefreshOrders()
    end

    nameBox:SetScript("OnEnterPressed", addOrder)

    local add = UI.Button(page, "Add Order", 84, 22)
    add:SetPoint("LEFT", nameBox, "RIGHT", 6, 0)
    add:SetScript("OnClick", addOrder)

    local showDone = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    showDone:SetSize(22, 22)
    showDone:SetPoint("TOPLEFT", 268, 0)
    local doneLbl = UI.Label(page, "show finished")
    doneLbl:SetPoint("LEFT", showDone, "RIGHT", 2, 0)
    showDone:SetScript("OnClick", function(self)
        UI.showDoneOrders = self:GetChecked() and true or false
        UI.RefreshOrders()
    end)

    local track = UI.Button(page, "Tracker", 76, 22)
    track:SetPoint("TOPRIGHT", -90, 0)
    track:SetScript("OnClick", function() ns.Tracker.Toggle() end)

    local prune = UI.Button(page, "Prune Old", 84, 22)
    prune:SetPoint("TOPRIGHT", 0, 0)
    prune:SetScript("OnClick", function()
        local now = GetServerTime and GetServerTime() or time()
        local before = #ns.db.orders
        ns.Orders.Prune(now, ns.db.settings.orders.keepDoneDays)
        ns.Print(string.format("pruned %d finished orders.", before - #ns.db.orders))
        UI.RefreshOrders()
    end)

    local scroll, content = UI.ScrollList(page, -28, 0)
    UI.orderRows = {}

    local function BuildRow(index)
        local row = CreateFrame("Frame", nil, content,
            BackdropTemplateMixin and "BackdropTemplate")
        row:SetSize(650, ROW_BASE_H)
        UI.Skin(row, 0.10, 0.10, 0.13, 0.9)

        row.head = UI.Label(row, "", "GameFontNormalSmall")
        row.head:SetPoint("TOPLEFT", 6, -5)
        row.head:SetJustifyH("LEFT")

        row.items = UI.Label(row, "", "GameFontHighlightSmall")
        row.items:SetPoint("TOPLEFT", 6, -21)
        row.items:SetWidth(440)
        row.items:SetJustifyH("LEFT")

        row.done = UI.Button(row, "Done", 56, 20)
        row.done:SetPoint("TOPRIGHT", -6, -6)
        row.cancel = UI.Button(row, "Cancel", 56, 20)
        row.cancel:SetPoint("RIGHT", row.done, "LEFT", -4, 0)
        row.ask = UI.Button(row, "Ask", 44, 20)
        row.ask:SetPoint("RIGHT", row.cancel, "LEFT", -4, 0)

        -- Split resolution, shown only when mats fitted more than one cut.
        row.splits = {}
        for i = 1, MAX_SPLIT_ROWS do
            local sr = CreateFrame("Frame", nil, row)
            sr:SetSize(420, 18)
            sr:SetPoint("TOPLEFT", 16, -38 - (i - 1) * 18)

            sr.label = UI.Label(sr, "", "GameFontHighlightSmall")
            sr.label:SetPoint("LEFT", 0, 0)
            sr.label:SetWidth(300)
            sr.label:SetJustifyH("LEFT")

            sr.minus = UI.Button(sr, "-", 20, 16)
            sr.minus:SetPoint("LEFT", 306, 0)
            sr.count = UI.Label(sr, "", "GameFontNormalSmall")
            sr.count:SetPoint("LEFT", 332, 0)
            sr.plus = UI.Button(sr, "+", 20, 16)
            sr.plus:SetPoint("LEFT", 350, 0)

            sr:Hide()
            row.splits[i] = sr
        end

        row.confirm = UI.Button(row, "Confirm split", 100, 20)
        row.confirm:Hide()

        UI.orderRows[index] = row
        return row
    end

    function UI.RefreshOrders()
        local list = {}
        for _, o in ipairs(ns.db.orders) do
            local finished = (o.status == "done" or o.status == "cancelled")
            if UI.showDoneOrders or not finished then list[#list + 1] = o end
        end

        for _, row in ipairs(UI.orderRows) do row:Hide() end

        local y = 0
        for i, o in ipairs(list) do
            local row = UI.orderRows[i] or BuildRow(i)

            local color = STATUS_COLOR[o.status] or "|cffffffff"
            row.head:SetText(string.format("|cffffffff#%d|r  %s  %s%s|r%s%s",
                o.id, o.player, color, o.status,
                (o.copperIn or 0) > 0 and ("   " .. ns.Ledger.Money(o.copperIn)) or "",
                o.needsSplit and "   |cffff9900needs split|r" or ""))
            row.items:SetText(ns.Orders.Summarise(o))

            row.done:SetScript("OnClick", function()
                ns.Orders.SetStatus(o, "done", GetServerTime and GetServerTime() or time())
                UI.RefreshOrders()
            end)
            row.cancel:SetScript("OnClick", function()
                ns.Orders.SetStatus(o, "cancelled",
                    GetServerTime and GetServerTime() or time())
                UI.RefreshOrders()
            end)
            row.ask:SetScript("OnClick", function()
                ns.Inviter.Say(o.player, ns.db.settings.invite.whisper.templateNoGem, {})
            end)

            local height = ROW_BASE_H
            local shown = 0
            for _, sr in ipairs(row.splits) do sr:Hide() end

            -- Ambiguous mats: they asked for two cuts made from the same raw
            -- gem, so only they know the split. The addon never guesses it.
            if o.needsSplit then
                for _, it in ipairs(o.items) do
                    if it.qtySource == "ambiguous" and shown < MAX_SPLIT_ROWS then
                        shown = shown + 1
                        local sr = row.splits[shown]
                        local e = ns.db.book[it.itemID]
                        sr.label:SetText(e and (e.link or e.name) or tostring(it.itemID))
                        sr.count:SetText(tostring(it.qty or 0))
                        sr.minus:SetScript("OnClick", function()
                            it.qty = math.max(0, (it.qty or 0) - 1)
                            sr.count:SetText(tostring(it.qty))
                        end)
                        sr.plus:SetScript("OnClick", function()
                            it.qty = (it.qty or 0) + 1
                            sr.count:SetText(tostring(it.qty))
                        end)
                        sr:Show()
                    end
                end
            end

            if shown > 0 then
                height = height + shown * 18 + 24
                row.confirm:ClearAllPoints()
                row.confirm:SetPoint("TOPLEFT", 16, -38 - shown * 18 - 2)
                row.confirm:SetScript("OnClick", function()
                    for _, it in ipairs(o.items) do
                        if it.qtySource == "ambiguous" then it.qtySource = "manual" end
                    end
                    o.needsSplit = false
                    UI.RefreshOrders()
                end)
                row.confirm:Show()
            else
                row.confirm:Hide()
            end

            row:SetHeight(height)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:Show()
            y = y + height + 4
        end

        content:SetSize(650, math.max(1, y))
    end
end

--------------------------------------------------------------------------------
-- Income
--------------------------------------------------------------------------------

function UI.BuildIncome(page)
    local totals = UI.Label(page, "", "GameFontHighlight")
    totals:SetPoint("TOPLEFT", 0, 0)
    totals:SetWidth(660)
    totals:SetJustifyH("LEFT")
    totals:SetSpacing(5)

    local custHead = UI.Label(page, "Top customers", "GameFontNormal")
    custHead:SetPoint("TOPLEFT", 0, -100)

    local customers = UI.Label(page, "", "GameFontHighlightSmall")
    customers:SetPoint("TOPLEFT", 0, -120)
    customers:SetWidth(320)
    customers:SetJustifyH("LEFT")
    customers:SetSpacing(4)

    local recentHead = UI.Label(page, "Recent payments", "GameFontNormal")
    recentHead:SetPoint("TOPLEFT", 350, -100)

    local recent = UI.Label(page, "", "GameFontHighlightSmall")
    recent:SetPoint("TOPLEFT", 350, -120)
    recent:SetWidth(320)
    recent:SetJustifyH("LEFT")
    recent:SetSpacing(4)

    local note = UI.Label(page,
        "|cff888888Income is gross. Mat costs are not deducted.|r",
        "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 0, 4)

    function UI.RefreshIncome()
        local L = ns.db.ledger
        local now = GetServerTime and GetServerTime() or time()
        local dayCopper, dayGems = ns.Ledger.SumSince(L.entries, now - 86400)
        local weekCopper = ns.Ledger.SumSince(L.entries, now - 604800)
        local avg = (L.allTimeGems or 0) > 0
            and math.floor((L.allTimeCopper or 0) / L.allTimeGems) or 0

        totals:SetText(string.format(
            "All time:  %s   over %d gems\nLast 24h:  %s   over %d gems\n"
            .. "Last 7d:   %s\nPer gem:   %s",
            ns.Ledger.Money(L.allTimeCopper or 0), L.allTimeGems or 0,
            ns.Ledger.Money(dayCopper), dayGems,
            ns.Ledger.Money(weekCopper),
            ns.Ledger.Money(avg)))

        local top = ns.Ledger.TopCustomers(10)
        if #top == 0 then
            customers:SetText("|cff888888nobody has paid you yet.|r")
        else
            local lines = {}
            for _, c in ipairs(top) do
                lines[#lines + 1] = string.format("%s  %s  |cff888888(%d)|r",
                    c.name, ns.Ledger.Money(c.copper), c.orders)
            end
            customers:SetText(table.concat(lines, "\n"))
        end

        local lines = {}
        for i = 1, math.min(12, #(L.entries or {})) do
            local e = L.entries[i]
            lines[#lines + 1] = string.format("%s  %s", e.player, ns.Ledger.Money(e.copper))
        end
        recent:SetText(#lines > 0 and table.concat(lines, "\n")
            or "|cff888888no payments recorded yet.|r")
    end
end
