local addonName, ns = ...

ns.UI = ns.UI or {}
local UI = ns.UI

local WIDTH, HEIGHT = 720, 540
local ROW_H = 18

local BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local function Skin(f, r, g, b, a)
    if f.SetBackdrop then
        f:SetBackdrop(BACKDROP)
        f:SetBackdropColor(r or 0.06, g or 0.06, b or 0.08, a or 0.95)
        f:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
    end
    return f
end

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate")
    b:SetSize(w or 90, h or 22)
    Skin(b, 0.15, 0.15, 0.18, 1)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(text)
    b:SetScript("OnEnter", function(self) self:SetBackdropColor(0.25, 0.25, 0.3, 1) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(0.15, 0.15, 0.18, 1) end)
    return b
end

local function Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    fs:SetText(text)
    return fs
end

-- Shared with UI_Orders.lua.
UI.Skin, UI.Button, UI.Label = Skin, Button, Label

--------------------------------------------------------------------------------
-- Main frame
--------------------------------------------------------------------------------

function UI.Create()
    if UI.frame then return UI.frame end

    local f = CreateFrame("Frame", "CutMasterFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate")
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    Skin(f)
    f:Hide()
    tinsert(UISpecialFrames, "CutMasterFrame")

    local title = Label(f, "CutMaster", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)

    UI.status = Label(f, "", "GameFontDisableSmall")
    UI.status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)

    local close = Button(f, "X", 22, 22)
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Bark Now is the most important control in the addon: a public chat
    -- message can only be sent from a hardware event, so this click (or the
    -- key binding) is the only path that actually works.
    local bark = Button(f, "Bark Now", 90, 22)
    bark:SetPoint("TOPRIGHT", close, "TOPLEFT", -6, 0)
    bark:SetScript("OnClick", function()
        local ok, info = ns.Barker.Tick(true)
        if not ok then ns.Print("bark skipped: " .. tostring(info)) end
        UI.Refresh()
    end)
    UI.barkButton = bark

    -- Master switch, next to Bark Now, so a silent addon is never mistaken
    -- for a broken one.
    local power = Button(f, "Disable", 70, 22)
    power:SetPoint("TOPRIGHT", bark, "TOPLEFT", -6, 0)
    power:SetScript("OnClick", function()
        ns.db.settings.enabled = not ns.Enabled()
        if ns.Enabled() then
            if ns.db.settings.bark.enabled then ns.Barker.Start() end
            ns.Print("|cff44ff44enabled.|r")
        else
            ns.Barker.Stop()
            ns.Print("|cffff4444disabled.|r")
        end
        UI.Refresh()
    end)
    UI.enableButton = power

    UI.tabs, UI.pages = {}, {}
    local names = { "Book", "Bark", "Orders", "Income", "Filter", "Log", "Invite" }
    for i, name in ipairs(names) do
        local tab = Button(f, name, 82, 20)
        tab:SetPoint("TOPLEFT", 8 + (i - 1) * 84, -46)
        tab:SetScript("OnClick", function() UI.SelectTab(i) end)
        UI.tabs[i] = tab

        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", 10, -72)
        page:SetPoint("BOTTOMRIGHT", -10, 10)
        page:Hide()
        UI.pages[i] = page
    end

    UI.BuildBook(UI.pages[1])
    UI.BuildBark(UI.pages[2])
    UI.BuildOrders(UI.pages[3])
    UI.BuildIncome(UI.pages[4])
    UI.BuildFilter(UI.pages[5])
    UI.BuildLog(UI.pages[6])
    UI.BuildInvite(UI.pages[7])

    UI.frame = f
    UI.SelectTab(1)
    return f
end

function UI.SelectTab(index)
    for i, tab in ipairs(UI.tabs) do
        UI.pages[i]:SetShown(i == index)
        tab:SetBackdropColor(i == index and 0.25 or 0.15,
            i == index and 0.25 or 0.15, i == index and 0.35 or 0.18, 1)
    end
    UI.current = index
    UI.Refresh()
end

function UI.Toggle()
    local f = UI.Create()
    if f:IsShown() then f:Hide() else f:Show(); UI.Refresh() end
end

function UI.Refresh()
    if not UI.frame or not UI.frame:IsShown() then return end
    local s = ns.db.settings
    local n, gems = 0, 0
    for _, e in pairs(ns.db.book) do
        if not e.stale then
            n = n + 1
            if e.classID == 3 then gems = gems + 1 end
        end
    end
    if not ns.Enabled() then
        UI.status:SetText("|cffff4444DISABLED|r  "
            .. "|cff888888no invites, whispers, barks or trade filling. "
            .. "Click Enable.|r")
        if UI.enableButton then UI.enableButton.text:SetText("Enable") end
        if UI.current == 1 and UI.RefreshBook then UI.RefreshBook() end
        if UI.current == 3 and UI.RefreshOrders then UI.RefreshOrders() end
        return
    end
    if UI.enableButton then UI.enableButton.text:SetText("Disable") end
    UI.status:SetText(string.format(
        "%d recipes (%d gems)  |  advertising %d  |  %d open orders  |  bark %s  |  invite %s%s",
        n, gems, #ns.Barker.AdvertisedEntries(), #ns.Orders.OpenList(),
        s.bark.enabled and "|cff44ff44on|r" or "|cffff4444off|r",
        s.invite.enabled and "|cff44ff44on|r" or "|cffff4444off|r",
        ns.Barker.pending and "  |  |cffffcc00BARK READY|r"
            or (s.bark.enabled and ("  |  next bark in "
                .. ns.Barker.SecondsUntilDue() .. "s") or "")))

    if UI.current == 1 and UI.RefreshBook then UI.RefreshBook() end
    if UI.current == 2 and UI.RefreshBark then UI.RefreshBark() end
    if UI.current == 3 and UI.RefreshOrders then UI.RefreshOrders() end
    if UI.current == 4 and UI.RefreshIncome then UI.RefreshIncome() end
    if UI.current == 6 and UI.RefreshLog then UI.RefreshLog() end
end

--------------------------------------------------------------------------------
-- Scrolling list helper
--------------------------------------------------------------------------------

local function ScrollList(parent, top, bottom)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, top or 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, bottom or 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    return scroll, content
end
UI.ScrollList = ScrollList

--------------------------------------------------------------------------------
-- Book tab
--------------------------------------------------------------------------------

function UI.BuildBook(page)
    local scanBtn = Button(page, "Scan Book", 90, 22)
    scanBtn:SetPoint("TOPLEFT", 0, 0)
    scanBtn:SetScript("OnClick", function()
        if ns.Scanner.IsJewelcrafting() then
            ns.Scanner.Scan()
        else
            ns.Print("open your Jewelcrafting window, then click Scan Book.")
        end
        UI.Refresh()
    end)

    local modes = { { "Epic", "epic" }, { "Rare+", "rare" }, { "All", "all" }, { "None", "none" } }
    for i, m in ipairs(modes) do
        local b = Button(page, m[1], 60, 22)
        b:SetPoint("TOPLEFT", 96 + (i - 1) * 62, 0)
        b:SetScript("OnClick", function()
            ns.Barker.ApplyAdvertiseFilter(ns.db.book, m[2])
            UI.Refresh()
        end)
    end

    local search = CreateFrame("EditBox", nil, page, BackdropTemplateMixin and "BackdropTemplate")
    search:SetSize(180, 22)
    search:SetPoint("TOPRIGHT", 0, 0)
    search:SetAutoFocus(false)
    search:SetFontObject("GameFontHighlightSmall")
    search:SetTextInsets(6, 6, 0, 0)
    Skin(search, 0.1, 0.1, 0.12, 1)
    search:SetScript("OnTextChanged", function(self)
        UI.bookSearch = self:GetText():lower()
        UI.RefreshBook()
    end)
    local hint = Label(page, "filter by name", "GameFontDisableSmall")
    hint:SetPoint("RIGHT", search, "LEFT", -6, 0)

    local scroll, content = ScrollList(page, -28, 0)
    UI.bookContent = content
    UI.bookRows = {}

    function UI.RefreshBook()
        local list = {}
        for itemID, e in pairs(ns.db.book) do
            if not e.stale then
                if not UI.bookSearch or UI.bookSearch == ""
                    or (e.name or ""):lower():find(UI.bookSearch, 1, true) then
                    list[#list + 1] = e
                end
            end
        end
        table.sort(list, function(a, b)
            if (a.header or "") ~= (b.header or "") then
                return (a.header or "") < (b.header or "")
            end
            return (a.name or "") < (b.name or "")
        end)

        for _, row in ipairs(UI.bookRows) do row:Hide() end

        for i, e in ipairs(list) do
            local row = UI.bookRows[i]
            if not row then
                row = CreateFrame("Frame", nil, content)
                row:SetSize(560, ROW_H)

                row.adv = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                row.adv:SetSize(18, 18)
                row.adv:SetPoint("LEFT", 0, 0)

                row.match = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                row.match:SetSize(18, 18)
                row.match:SetPoint("LEFT", 26, 0)

                row.label = Label(row, "", "GameFontHighlightSmall")
                row.label:SetPoint("LEFT", 52, 0)
                row.label:SetJustifyH("LEFT")

                UI.bookRows[i] = row
            end
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
            row.entry = e
            row.adv:SetChecked(e.advertise and true or false)
            row.match:SetChecked(e.match and true or false)
            row.adv:SetScript("OnClick", function(self)
                row.entry.advertise = self:GetChecked() and true or false
                UI.Refresh()
            end)
            row.match:SetScript("OnClick", function(self)
                row.entry.match = self:GetChecked() and true or false
                ns.Events.RebuildIndex()
            end)
            row.label:SetText(string.format("%s  |cff777777%s|r%s",
                e.link or e.name or "?", e.header or "",
                e.stats and ("  |cff88ccff" .. e.stats .. "|r") or ""))
            row:Show()
        end

        content:SetSize(560, math.max(1, #list * ROW_H))
    end

    local legend = Label(page, "|cff888888left box = advertise, right box = match for invites|r",
        "GameFontDisableSmall")
    legend:SetPoint("BOTTOMLEFT", 0, -0)
    legend:Hide()
end

--------------------------------------------------------------------------------
-- Bark tab
--------------------------------------------------------------------------------

function UI.BuildBark(page)
    -- A checkbox rather than a button, so the on/off state is visible at a
    -- glance. This flag only gates the periodic "bark ready" nag (sound +
    -- print) -- manual sends via Bark Now, the key binding, the minimap
    -- right click, and /cm send all bypass it, so turning reminders off
    -- does not stop you from barking by hand.
    local remind = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    remind:SetSize(24, 24)
    remind:SetPoint("TOPLEFT", 0, 0)
    remind:SetScript("OnClick", function(self)
        local s = ns.db.settings.bark
        s.enabled = self:GetChecked() and true or false
        if s.enabled then ns.Barker.Start(true) else ns.Barker.Stop() end
        UI.Refresh()
    end)
    UI.remindCheck = remind

    local remindLbl = Label(page, "Remind me when it's time to bark")
    remindLbl:SetPoint("LEFT", remind, "RIGHT", 4, 0)

    local sendNow = Button(page, "Send Now", 90, 22)
    sendNow:SetPoint("TOPLEFT", 0, -28)
    sendNow:SetScript("OnClick", function()
        local ok, info = ns.Barker.Tick(true)
        if not ok then ns.Print("bark skipped: " .. tostring(info)) end
        UI.Refresh()
    end)

    local slider = CreateFrame("Slider", "CutMasterIntervalSlider", page, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 0, -60)
    slider:SetWidth(260)
    slider:SetMinMaxValues(30, 600)
    slider:SetValueStep(10)
    slider:SetObeyStepOnDrag(true)
    _G[slider:GetName() .. "Low"]:SetText("30s")
    _G[slider:GetName() .. "High"]:SetText("600s")
    slider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / 10 + 0.5) * 10
        ns.db.settings.bark.intervalSec = v
        _G[self:GetName() .. "Text"]:SetText("Reminder interval: " .. v .. "s")
        if ns.db.settings.bark.enabled then ns.Barker.Start(false) end
    end)
    UI.intervalSlider = slider

    local tplLabel = Label(page, "Message template ({gems} is required)")
    tplLabel:SetPoint("TOPLEFT", 0, -92)

    local tpl = CreateFrame("EditBox", nil, page, BackdropTemplateMixin and "BackdropTemplate")
    tpl:SetSize(580, 24)
    tpl:SetPoint("TOPLEFT", 0, -110)
    tpl:SetAutoFocus(false)
    tpl:SetFontObject("GameFontHighlightSmall")
    tpl:SetTextInsets(6, 6, 0, 0)
    Skin(tpl, 0.1, 0.1, 0.12, 1)
    tpl:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        if not text:find("{gems}", 1, true) then
            ns.Print("|cffff4444template must contain {gems}.|r")
            self:SetText(ns.db.settings.bark.template)
        else
            ns.db.settings.bark.template = text
            ns.Print("template saved.")
        end
        self:ClearFocus()
        UI.Refresh()
    end)
    UI.tplBox = tpl

    local preview = Label(page, "", "GameFontHighlightSmall")
    preview:SetPoint("TOPLEFT", 0, -146)
    preview:SetWidth(580)
    preview:SetJustifyH("LEFT")
    preview:SetSpacing(3)
    UI.preview = preview

    local note = Label(page,
        "|cffff9900WoW blocks addons from posting to public chat on a timer.|r\n"
        .. "The interval only reminds you. Sending needs a real key or click:\n"
        .. "the Bark Now button, /cm send, or a key bound under\n"
        .. "Options, Key Bindings, CutMaster.", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 0, 10)
    note:SetJustifyH("LEFT")
    note:SetSpacing(3)

    function UI.RefreshBark()
        local s = ns.db.settings.bark
        remind:SetChecked(s.enabled and true or false)
        slider:SetValue(s.intervalSec)
        _G[slider:GetName() .. "Text"]:SetText("Reminder interval: " .. s.intervalSec .. "s")
        if not tpl:HasFocus() then tpl:SetText(s.template) end
        local msg, _, used = ns.Barker.Preview()
        if msg then
            preview:SetText(string.format("|cff888888next bark, %d gems, %d chars:|r\n%s",
                used, #msg, msg))
        else
            preview:SetText("|cffff4444nothing to advertise. Scan, then pick gems in Book.|r")
        end
    end
end

--------------------------------------------------------------------------------
-- Filter tab
--------------------------------------------------------------------------------

function UI.BuildFilter(page)
    local f = ns.db and ns.db.settings.filter

    local req = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    req:SetPoint("TOPLEFT", 0, 0)
    req:SetSize(22, 22)
    local reqLabel = Label(page, "Require a buying signal in Trade chat")
    reqLabel:SetPoint("LEFT", req, "RIGHT", 4, 0)
    req:SetScript("OnClick", function(self)
        ns.db.settings.filter.requireBuyerSignal = self:GetChecked() and true or false
    end)
    req:SetScript("OnShow", function(self)
        self:SetChecked(ns.db.settings.filter.requireBuyerSignal)
    end)

    local slider = CreateFrame("Slider", "CutMasterThresholdSlider", page, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 4, -46)
    slider:SetWidth(260)
    slider:SetMinMaxValues(1, 10)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    _G[slider:GetName() .. "Low"]:SetText("1 strict")
    _G[slider:GetName() .. "High"]:SetText("10 loose")
    slider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        ns.db.settings.filter.netThreshold = v
        _G[self:GetName() .. "Text"]:SetText("Net seller threshold: " .. v)
    end)
    slider:SetScript("OnShow", function(self)
        self:SetValue(ns.db.settings.filter.netThreshold)
    end)

    local words = Label(page, "", "GameFontHighlightSmall")
    words:SetPoint("TOPLEFT", 0, -96)
    words:SetWidth(580)
    words:SetJustifyH("LEFT")
    words:SetSpacing(3)
    page:SetScript("OnShow", function()
        local v = table.concat(ns.db.settings.filter.vetoWords, ", ")
        local sw, bw = {}, {}
        for k, wt in pairs(ns.db.settings.filter.sellerWords) do
            sw[#sw + 1] = k .. " " .. wt
        end
        for k, wt in pairs(ns.db.settings.filter.buyerWords) do
            bw[#bw + 1] = k .. " " .. wt
        end
        table.sort(sw); table.sort(bw)
        words:SetText(
            "|cffff8888Hard vetoes|r (never invited, any channel):\n" .. v
            .. "\n\n|cffff8888Seller signals|r:\n" .. table.concat(sw, ", ")
            .. "\n\n|cff88ff88Buyer signals|r:\n" .. table.concat(bw, ", ")
            .. "\n\n|cff888888Edit these in CutMasterDB.settings.filter, "
            .. "or use /cm try <message> to test one.|r")
    end)
end

--------------------------------------------------------------------------------
-- Log tab
--------------------------------------------------------------------------------

function UI.BuildLog(page)
    local clear = Button(page, "Clear Flags", 90, 22)
    clear:SetPoint("TOPLEFT", 0, 0)
    clear:SetScript("OnClick", function()
        local n = 0
        for _, st in pairs(ns.db.players) do
            if st.flaggedSeller then st.flaggedSeller = nil; n = n + 1 end
        end
        ns.Print(string.format("cleared the auto seller flag on %d players.", n))
        UI.RefreshLog()
    end)

    local scroll, content = ScrollList(page, -28, 0)
    UI.logContent = content
    UI.logRows = {}

    function UI.RefreshLog()
        for _, row in ipairs(UI.logRows) do row:Hide() end
        local entries = ns.Log.Recent(40)
        for i, e in ipairs(entries) do
            local row = UI.logRows[i]
            if not row then
                row = CreateFrame("Frame", nil, content)
                row:SetSize(560, ROW_H * 2)
                row.line = Label(row, "", "GameFontHighlightSmall")
                row.line:SetPoint("TOPLEFT")
                row.line:SetWidth(430)
                row.line:SetJustifyH("LEFT")
                row.never = Button(row, "Never", 56, 18)
                row.never:SetPoint("TOPRIGHT", 0, 0)
                UI.logRows[i] = row
            end
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H * 2)
            row.line:SetText(ns.Log.Describe(e) .. "\n" .. ns.Log.DescribeHits(e))
            row.never:SetScript("OnClick", function()
                ns.Players.Get(ns.db, e.player).neverInvite = true
                ns.Print(e.player .. " will never be invited.")
            end)
            row:Show()
        end
        content:SetSize(560, math.max(1, #entries * ROW_H * 2))
    end
end

--------------------------------------------------------------------------------
-- Invite tab
--------------------------------------------------------------------------------

function UI.BuildInvite(page)
    local rows = {
        { "Auto invite from Trade chat", function() return ns.db.settings.invite.enabled end,
          function(v) ns.db.settings.invite.enabled = v end },
        { "Auto invite from whispers", function() return ns.db.settings.invite.fromWhisper end,
          function(v) ns.db.settings.invite.fromWhisper = v end },
        { "Whisper them after inviting", function() return ns.db.settings.invite.whisper.enabled end,
          function(v) ns.db.settings.invite.whisper.enabled = v end },
        { "Record every Trade message (capture)", function() return ns.db.settings.captureAll end,
          function(v) ns.db.settings.captureAll = v end },
        { "Debug output", function() return ns.db.settings.debug end,
          function(v) ns.db.settings.debug = v end },
    }

    for i, r in ipairs(rows) do
        local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 0, -(i - 1) * 26)
        cb:SetSize(22, 22)
        local lbl = Label(page, r[1])
        lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        cb:SetScript("OnClick", function(self) r[3](self:GetChecked() and true or false) end)
        cb:SetScript("OnShow", function(self) self:SetChecked(r[2]()) end)
    end

    local partyLabel = Label(page, "Stop inviting at party size")
    partyLabel:SetPoint("TOPLEFT", 4, -146)

    local slider = CreateFrame("Slider", "CutMasterPartySlider", page, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 4, -178)
    slider:SetWidth(220)
    slider:SetMinMaxValues(2, 5)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    _G[slider:GetName() .. "Low"]:SetText("2")
    _G[slider:GetName() .. "High"]:SetText("5")
    slider:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        ns.db.settings.invite.maxParty = v
        _G[self:GetName() .. "Text"]:SetText("Max party: " .. v)
    end)
    slider:SetScript("OnShow", function(self)
        self:SetValue(ns.db.settings.invite.maxParty)
    end)

    -- Every whisper the addon can send, editable. These go out in the user's
    -- name, so nothing here should be hardcoded.
    local templates = {
        { key = "template",
          label = "They named a gem you have  |cff888888{gem} {player}|r" },
        { key = "templateNoGem",
          label = "They asked for a jeweller but named nothing  |cff888888{player}|r" },
        { key = "confirmTemplate",
          label = "They answered with a cut you have  |cff888888{gem} {player}|r" },
        { key = "suggestTemplate",
          label = "They asked for a cut you lack  |cff888888{gems} {player}|r" },
        { key = "partialTemplate",
          label = "They asked for several, you have some  |cff888888{have} {lack}|r" },
        { key = "noneTemplate",
          label = "They asked outright and you have nothing close" },
        { key = "askWhichTemplate",
          label = "They typed half a gem name  |cff888888{gems}|r" },
    }

    local y = -196
    for _, t in ipairs(templates) do
        local lbl = Label(page, t.label)
        lbl:SetPoint("TOPLEFT", 0, y)

        local box = CreateFrame("EditBox", nil, page,
            BackdropTemplateMixin and "BackdropTemplate")
        box:SetSize(520, 22)
        box:SetPoint("TOPLEFT", 0, y - 16)
        box:SetAutoFocus(false)
        box:SetFontObject("GameFontHighlightSmall")
        box:SetTextInsets(6, 6, 0, 0)
        Skin(box, 0.1, 0.1, 0.12, 1)
        box:SetScript("OnShow", function(self)
            self:SetText(ns.db.settings.invite.whisper[t.key] or "")
        end)
        box:SetScript("OnEscapePressed", function(self)
            self:SetText(ns.db.settings.invite.whisper[t.key] or "")
            self:ClearFocus()
        end)
        box:SetScript("OnEnterPressed", function(self)
            ns.db.settings.invite.whisper[t.key] = self:GetText()
            ns.Print("saved.")
            self:ClearFocus()
        end)

        local reset = Button(page, "Reset", 52, 22)
        reset:SetPoint("TOPLEFT", 528, y - 16)
        reset:SetScript("OnClick", function()
            local d = ns.Defaults.settings.invite.whisper[t.key]
            ns.db.settings.invite.whisper[t.key] = d
            box:SetText(d or "")
        end)

        y = y - 35
    end

    local hint = Label(page,
        "|cff888888Press Enter to save a line, Escape to discard. "
        .. "Leave a line empty to send nothing for that case.|r",
        "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 0, y - 4)
end
