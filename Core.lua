local addonName, ns = ...

ns.Util = ns.Util or {}

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CutMaster|r: " .. tostring(msg))
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
            whisper = {
                enabled = true,
                template = "Invited you for {gem}, accept and trade me the mats + tip!",
                cooldownSec = 600,
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
            canCutGuards = { "who", "anyone", "any1", "anybody", "someone", "jc" },
            weights = {
                manyLinks = 3, designLink = 4, repeatBark = 5, shapeMatch = 2, canCut = 4,
            },
        },
        scan = {
            autoStaleSec = 21600,
        },
        debug = false,
    },
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
    if event == "ADDON_LOADED" and arg1 == addonName then
        CutMasterDB = CutMasterDB or {}
        ns.ApplyDefaults(CutMasterDB, ns.Defaults)
        ns.db = CutMasterDB
        ns.Print("loaded. /cm help for commands.")
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

    if cmd == "test" then
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
    else
        ns.Print("Commands: /cm scan, /cm book, /cm match <text>, /cm test")
    end
end

SLASH_CUTMASTER1 = "/cm"
SLASH_CUTMASTER2 = "/cutmaster"
SlashCmdList["CUTMASTER"] = HandleSlash
