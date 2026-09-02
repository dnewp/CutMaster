local addonName, ns = ...

ns.Util = ns.Util or {}

-- Output goes straight into a chat frame rather than through the chat event
-- system, so it has no message type and the chat settings UI cannot route it.
-- Picking the target frame here is the only way to move it. See /cm out.
function ns.Print(msg)
    local frame = DEFAULT_CHAT_FRAME
    local idx = ns.db and ns.db.settings and ns.db.settings.outputFrame
    if idx and idx > 1 then
        local f = _G["ChatFrame" .. idx]
        if f and f.AddMessage then frame = f end
    end
    frame:AddMessage("|cff33ff99CutMaster|r: " .. tostring(msg))
end

function ns.DeepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = ns.DeepCopy(v)
    end
    return out
end

function ns.ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            ns.ApplyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end

ns.Defaults = {
    version = 1,
    book = {},
    bookScannedAt = 0,
    bookPartial = false,
    bookDirty = false,
    players = {},
    log = {},
    capture = {},
    orders = {},
    nextOrderID = 1,
    ledger = { entries = {}, allTimeCopper = 0, allTimeGems = 0 },
    settings = {
        bark = {
            enabled = false,
            intervalSec = 180,
            perBark = 4,
            template = "WTS JC cuts: {gems} and more! /w me",
            cursor = 1,
            onlyInCity = true,
            pauseCombat = true,
            pauseInstance = true,
        },
        invite = {
            enabled = true,
            maxParty = 5,
            playerCooldownSec = 600,
            fromWhisper = true,
            whisper = {
                enabled = true,
                autoReply = true,
                autoSuggest = false,
                -- They named a gem we can cut.
                template = "Invited you for {gem}! Accept and trade me the mats.",
                -- They asked for a jeweller without naming anything.
                templateNoGem = "Hey! What cut do you need? Link the gem or name it "
                    .. "and I'll tell you if I have it.",
                -- They answered our question with a cut we have.
                confirmTemplate = "Yep, I can do {gem}. Trade me the mats and "
                    .. "I'll get it cut.",
                -- They named a cut we do not have, but we know that gem family.
                suggestTemplate = "I don't have that exact cut, but I can do: {gems}",
                -- They linked several and we only know some of them.
                partialTemplate = "I can do {have}, but I don't have {lack}.",
                cooldownSec = 600,
                replyCooldownSec = 10,
            },
        },
        filter = {
            requireBuyerSignal = true,
            netThreshold = 3,
            repeatWindowSec = 600,
            vetoWords = {
                "lfw", "jc lfw", "lf work", "looking for work",
                "wts", "selling", "will cut", "i cut", "cutting for",
            },
            sellerWords = {
                ["all cuts"] = 3, ["any cut"] = 2, ["full book"] = 3,
                ["most cuts"] = 3, ["every cut"] = 3, ["mats tip"] = 2,
                ["free cuts"] = 2, ["tips appreciated"] = 2, ["no charge"] = 2,
            },
            buyerWords = {
                ["wtb"] = 3, ["want to buy"] = 3, ["buying"] = 2, ["need"] = 2,
                ["anyone cut"] = 3, ["who can cut"] = 3, ["any jc"] = 2,
                ["lfjc"] = 3, ["lf jc"] = 3, ["have mats"] = 2, ["got mats"] = 2,
                ["have the mats"] = 2, ["will tip"] = 2, ["paying"] = 2, ["pay for"] = 2,
            },
            -- Asking for the profession itself, with no gem named. Word order
            -- separates these from a competitor's "JC LFW".
            professionWords = {
                "lf jc", "lfjc", "lf a jc", "any jc", "any jcs", "need a jc",
                "need jc", "looking for a jc", "looking for jc",
                "lf jewelcrafter", "lf a jewelcrafter", "any jewelcrafter",
                "need a jewelcrafter", "need jewelcrafter",
                "looking for a jewelcrafter", "jc online", "jc around",
            },
            canCutGuards = { "who", "anyone", "any1", "anybody", "someone", "jc" },
            weights = {
                manyLinks = 3, designLink = 4, repeatBark = 5, shapeMatch = 2, canCut = 4,
            },
        },
        scan = {
            autoStaleSec = 21600,
        },
        orders = {
            autoFromInvite = true,
            autoFromWhisper = true,
            autoFromParty = true,
            captureTranscript = true,
            autoAdvanceMats = true,
            autoFillTrade = true,
            promptOnDone = true,
            keepDoneDays = 30,
        },
        captureAll = false,
        outputFrame = 1,
        minimap = { hide = false },
        tracker = { shown = false, autoShow = true, point = nil },
        debug = false,
    },
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("CHAT_MSG_RAID_LEADER")
frame:RegisterEvent("CHAT_MSG_RAID")
frame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
frame:RegisterEvent("CHAT_MSG_PARTY")
frame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("TRADE_SHOW")
frame:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
    if event == "ADDON_LOADED" and arg1 == addonName then
        CutMasterDB = CutMasterDB or {}
        ns.ApplyDefaults(CutMasterDB, ns.Defaults)
        ns.db = CutMasterDB
        if ns.db.settings.bark.enabled then ns.Barker.Start() end
        if ns.Minimap and ns.Minimap.Init then ns.Minimap.Init() end
        if ns.db.settings.tracker.shown then
            C_Timer.After(1, function() ns.Tracker.Show() end)
        end
        ns.Print("loaded. /cm opens the window, /cm help lists commands.")
    elseif event == "SKILL_LINES_CHANGED" then
        if ns.db then ns.db.bookDirty = true end
    elseif event == "TRADE_SKILL_SHOW" then
        -- GetNumTradeSkills reads 0 for a frame or two after the event fires.
        C_Timer.After(0.2, function()
            if not ns.Scanner.IsJewelcrafting() then return end
            local count = 0
            for _ in pairs(ns.db.book) do count = count + 1 end
            local now = GetServerTime and GetServerTime() or time()
            local should = ns.Scanner.initiatedByUs or ns.Scanner.ShouldAutoScan(
                count, ns.db.bookDirty, ns.db.bookScannedAt,
                now, ns.db.settings.scan.autoStaleSec)
            if should then
                ns.Scanner.Scan({ silent = not ns.Scanner.initiatedByUs })
            end
        end)
    elseif event == "TRADE_SKILL_CLOSE" then
        ns.Scanner.initiatedByUs = false
    elseif event == "CHAT_MSG_CHANNEL" then
        local text, author, _, _, _, _, _, _, channelName = ...
        if channelName and channelName:find("Trade", 1, true) then
            ns.Events.OnTradeMessage(text, author)
        end
    elseif event == "CHAT_MSG_WHISPER" then
        local text, author = ...
        ns.Events.OnWhisper(text, author)
    elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"
        or event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
        local text, author = ...
        ns.Events.OnParty(text, author)
    elseif event == "CHAT_MSG_WHISPER_INFORM" then
        local text, target = ...
        if ns.db.settings.orders.captureTranscript then
            ns.Orders.AddTranscript(target, "out", text,
                GetServerTime and GetServerTime() or time())
        end
    elseif event == "TRADE_SHOW" or event == "TRADE_ACCEPT_UPDATE"
        or event == "TRADE_CLOSED" then
        ns.Trade.OnEvent(event, ...)
    end
end)
ns.frame = frame

local function BookCounts()
    local n, gems = 0, 0
    for _, e in pairs(ns.db.book) do
        if not e.stale then
            n = n + 1
            if e.classID == 3 then gems = gems + 1 end
        end
    end
    return n, gems
end

local function HandleSlash(input)
    local raw = ns.Util.Trim(input or "")
    local cmd, rest = raw:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "config" then
        ns.UI.Toggle()
    elseif cmd == "test" then
        ns.Tests.Run()
    elseif cmd == "scan" then
        ns.Scanner.Scan()
    elseif cmd == "book" then
        local n, gems = BookCounts()
        ns.Print(string.format("book holds %d recipes (%d gems).", n, gems))
    elseif cmd == "match" then
        if rest == "" then
            ns.Print("usage: /cm match <text or linked gem>")
            return
        end
        local index = ns.Matcher.BuildIndex(ns.db.book)
        local hits = ns.Matcher.Match(rest, ns.Util.Normalize(rest), index)
        if #hits == 0 then
            ns.Print("no gem matched.")
        end
        for _, h in ipairs(hits) do
            local e = ns.db.book[h.itemID]
            ns.Print(string.format("  %s  |cff888888[%s%s]|r",
                e and (e.link or e.name) or h.itemID, h.tier,
                h.qtyHint and (", qty " .. h.qtyHint) or ""))
        end
    elseif cmd == "invite" then
        local s = ns.db.settings.invite
        s.enabled = not s.enabled
        ns.Print("auto invite " .. (s.enabled and "|cff44ff44on|r" or "|cffff4444off|r"))
    elseif cmd == "bark" then
        local s = ns.db.settings.bark
        local secs = tonumber(rest)
        if secs then
            s.intervalSec = math.max(30, math.min(600, secs))
            s.enabled = true
            if secs ~= s.intervalSec then
                ns.Print(string.format(
                    "|cffff9900%d is outside the allowed 30 to 600 range, using %d.|r",
                    secs, s.intervalSec))
            end
            ns.Print(string.format("barking every %d seconds.", s.intervalSec))
            ns.Barker.Start(true)
        else
            s.enabled = not s.enabled
            ns.Print("barking " .. (s.enabled and "|cff44ff44on|r" or "|cffff4444off|r"))
            if s.enabled then ns.Barker.Start(true) else ns.Barker.Stop() end
        end
    elseif cmd == "tracker" then
        ns.Tracker.Toggle()
    elseif cmd == "orders" then
        local open = ns.Orders.OpenList()
        if #open == 0 then
            ns.Print("no open orders.")
        end
        for _, o in ipairs(open) do
            ns.Print(string.format("|cffffffff#%d|r %s [%s]%s  %s",
                o.id, o.player, o.status,
                o.needsSplit and " |cffff9900SPLIT?|r" or "",
                ns.Orders.Summarise(o)))
            if (o.copperIn or 0) > 0 then
                ns.Print("    paid " .. ns.Ledger.Money(o.copperIn))
            end
        end
    elseif cmd == "order" then
        local sub, arg = rest:match("^(%S*)%s*(.*)$")
        sub = (sub or ""):lower()
        local now = GetServerTime and GetServerTime() or time()
        if sub == "add" and arg ~= "" then
            local o = ns.Orders.Create(arg, "manual", "", {}, now)
            ns.Print(string.format("order #%d opened for %s. "
                .. "Trade them the mats and it will fill itself in.", o.id, arg))
        elseif sub == "done" then
            local id = tonumber(arg)
            for _, o in ipairs(ns.db.orders) do
                if o.id == id then
                    ns.Orders.SetStatus(o, "done", now)
                    ns.Print(string.format("order #%d closed.", id))
                    return
                end
            end
            ns.Print("no order with that id.")
        elseif sub == "cancel" then
            local id = tonumber(arg)
            for _, o in ipairs(ns.db.orders) do
                if o.id == id then
                    ns.Orders.SetStatus(o, "cancelled", now)
                    ns.Print(string.format("order #%d cancelled.", id))
                    return
                end
            end
            ns.Print("no order with that id.")
        else
            ns.Print("usage: /cm order add <player> | done <id> | cancel <id>")
        end
    elseif cmd == "income" then
        ns.Ledger.Report()
    elseif cmd == "adv" then
        local book = ns.db.book
        local sub = rest:lower()
        if sub == "all" or sub == "none" or sub == "rare" or sub == "epic" then
            local n = ns.Barker.ApplyAdvertiseFilter(book, sub)
            ns.Print(string.format("advertising %d recipes (%s).", n, sub))
        elseif sub:sub(1, 1) == "+" or sub:sub(1, 1) == "-" then
            local on = sub:sub(1, 1) == "+"
            local n = ns.Barker.SetAdvertiseMatching(book, rest:sub(2), on)
            ns.Print(string.format("%s %d recipes matching '%s'.",
                on and "added" or "removed", n, rest:sub(2)))
        else
            local list = ns.Barker.AdvertisedEntries()
            ns.Print(string.format("advertising %d recipes:", #list))
            for i = 1, math.min(#list, 40) do
                ns.Print("  " .. (ns.db.book[list[i].itemID].link or list[i].name))
            end
            if #list > 40 then ns.Print(string.format("  ...and %d more", #list - 40)) end
            ns.Print("usage: /cm adv epic | rare | all | none | +<text> | -<text>")
        end
    elseif cmd == "send" then
        local ok, info = ns.Barker.Tick(true)
        if not ok then ns.Print("bark skipped: " .. tostring(info)) end
    elseif cmd == "preview" then
        local msg, _, used = ns.Barker.Preview()
        if not msg then
            ns.Print("nothing to advertise. Scan your book first.")
        else
            ns.Print(string.format("next bark (%d gems, %d chars):", used, #msg))
            ns.Print("  " .. msg)
        end
    elseif cmd == "tryparty" then
        if rest == "" then
            ns.Print("usage: /cm tryparty <a party chat message>")
            return
        end
        local r = ns.Events.OnParty(rest, "TestDummy", { dryRun = true })
        if r then
            ns.Print(string.format("verdict |cffffffff%s|r (%s), seller %d buyer %d",
                r.verdict, r.reason, r.sellerScore or 0, r.buyerScore or 0))
        end
    elseif cmd == "trywhisper" then
        if rest == "" then
            ns.Print("usage: /cm trywhisper <a whispered message>")
            return
        end
        local r = ns.Events.OnWhisper(rest, "TestDummy", { dryRun = true })
        if r then
            ns.Print(string.format("verdict |cffffffff%s|r (%s), seller %d buyer %d net %d",
                r.verdict, r.reason, r.sellerScore or 0, r.buyerScore or 0, r.netScore or 0))
            ns.Print(ns.Log.DescribeHits(r))
        end
    elseif cmd == "debug" then
        ns.db.settings.debug = not ns.db.settings.debug
        ns.Print("debug " .. (ns.db.settings.debug and "on" or "off"))
    elseif cmd == "capture" then
        local s = ns.db.settings
        s.captureAll = not s.captureAll
        if s.captureAll then
            ns.Print("capture |cff44ff44on|r. Recording every Trade message, "
                .. "matched or not. Run /reload to flush it to disk.")
        else
            ns.Print(string.format("capture |cffff4444off|r. %d messages held.",
                #(ns.db.capture or {})))
        end
    elseif cmd == "status" then
        local s = ns.db.settings
        local function onoff(v)
            return v and "|cff44ff44on|r" or "|cffff4444off|r"
        end
        local n, gems = BookCounts()
        local age = ns.db.bookScannedAt > 0
            and math.floor(((GetServerTime and GetServerTime() or time())
                - ns.db.bookScannedAt) / 60) or -1
        ns.Print(string.format("auto invite %s   barking %s (%ds, timer %s)   capture %s   debug %s",
            onoff(s.invite.enabled), onoff(s.bark.enabled), s.bark.intervalSec,
            ns.Barker.ticker and "running" or "stopped",
            onoff(s.captureAll), onoff(s.debug)))
        ns.Print(string.format("advertising %d recipes", #ns.Barker.AdvertisedEntries()))
        ns.Print(string.format("book: %d recipes (%d gems), scanned %s",
            n, gems, age >= 0 and (age .. " min ago") or "never"))
        ns.Print(string.format("log: %d entries   capture: %d messages",
            #ns.db.log, #(ns.db.capture or {})))
    elseif cmd == "out" then
        if rest == "" then
            ns.Print("chat windows:")
            for i = 1, NUM_CHAT_WINDOWS do
                local name = GetChatWindowInfo(i)
                if name and name ~= "" then
                    ns.Print(string.format("  %d = %s%s", i, name,
                        ns.db.settings.outputFrame == i and "  |cff44ff44(current)|r" or ""))
                end
            end
            ns.Print("usage: /cm out <number>")
        else
            local n = tonumber(rest)
            if n and _G["ChatFrame" .. n] then
                ns.db.settings.outputFrame = n
                ns.Print("CutMaster output now prints here.")
            else
                ns.Print("no such chat window. Run /cm out to list them.")
            end
        end
    elseif cmd == "clearcapture" then
        ns.db.capture = {}
        ns.Print("capture cleared.")
    elseif cmd == "clearflags" then
        local n = 0
        for _, st in pairs(ns.db.players) do
            if st.flaggedSeller then st.flaggedSeller = nil; n = n + 1 end
        end
        ns.Print(string.format("cleared the auto seller flag on %d players.", n))
    elseif cmd == "log" then
        local entries = ns.Log.Recent(10)
        if #entries == 0 then
            ns.Print("log is empty.")
        end
        for i = #entries, 1, -1 do
            ns.Print(ns.Log.Describe(entries[i]))
            ns.Print(ns.Log.DescribeHits(entries[i]))
        end
    elseif cmd == "try" then
        if rest == "" then
            ns.Print("usage: /cm try <a trade chat message>")
            return
        end
        local r = ns.Events.OnTradeMessage(rest, "TestDummy", { dryRun = true })
        if r then
            ns.Print(string.format("verdict |cffffffff%s|r (%s), seller %d buyer %d net %d",
                r.verdict, r.reason, r.sellerScore or 0, r.buyerScore or 0, r.netScore or 0))
            ns.Print(ns.Log.DescribeHits(r))
        end
    else
        ns.Print("Commands: /cm (open window), /cm scan, /cm book, /cm match <text>,")
        ns.Print("  /cm try <msg>,")
        ns.Print("  /cm trywhisper <msg>, /cm tryparty <msg>, /cm bark [secs],")
        ns.Print("  /cm send, /cm preview,")
        ns.Print("  /cm adv rare|all|none|+text|-text,")
        ns.Print("  /cm invite, /cm log, /cm debug, /cm capture, /cm clearcapture,")
        ns.Print("  /cm orders, /cm order add|done|cancel, /cm tracker, /cm income,")
        ns.Print("  /cm clearflags, /cm out [n], /cm status, /cm test")
    end
end

-- Key binding names shown in the game's Key Bindings menu.
BINDING_HEADER_CUTMASTER = "CutMaster"
BINDING_NAME_CUTMASTER_BARK = "Send bark to Trade"
BINDING_NAME_CUTMASTER_TOGGLE = "Toggle CutMaster window"

-- Called from a key binding, which IS a hardware event, so the protected
-- SendChatMessage is allowed here where a timer callback would be blocked.
function CutMaster_BarkNow()
    local ok, info = ns.Barker.Tick(true)
    if not ok then ns.Print("bark skipped: " .. tostring(info)) end
end

function CutMaster_Toggle()
    if ns.UI and ns.UI.Toggle then
        ns.UI.Toggle()
    else
        ns.Print("UI not loaded.")
    end
end

SLASH_CUTMASTER1 = "/cm"
SLASH_CUTMASTER2 = "/cutmaster"
SlashCmdList["CUTMASTER"] = HandleSlash
