local addonName, ns = ...

ns.Tests = ns.Tests or {}
local T = ns.Tests
T.cases = {}

function T.Case(name, fn)
    T.cases[#T.cases + 1] = { name = name, fn = fn }
end

function T.Eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected [%s], got [%s]",
            tostring(label or "value"), tostring(expected), tostring(actual)), 2)
    end
end

function T.Run()
    local pass, fail = 0, 0
    for _, c in ipairs(T.cases) do
        local ok, err = pcall(c.fn)
        if ok then
            pass = pass + 1
        else
            fail = fail + 1
            ns.Print("|cffff4444FAIL|r " .. c.name .. " => " .. tostring(err))
        end
    end
    ns.Print(string.format("Tests: |cff44ff44%d passed|r, %s%d failed|r",
        pass, fail > 0 and "|cffff4444" or "|cff44ff44", fail))
    return pass, fail
end

local RUBY_LINK = "|cffa335ee|Hitem:24033:0:0:0:0:0:0:0|h[Bold Living Ruby]|h|r"

T.Case("Util.Trim strips surrounding whitespace", function()
    T.Eq(ns.Util.Trim("  bold ruby  "), "bold ruby", "trim")
end)

T.Case("StripEscapes keeps link display text", function()
    T.Eq(ns.Util.StripEscapes(RUBY_LINK), "[Bold Living Ruby]", "stripped")
end)

T.Case("Normalize lowercases and strips punctuation", function()
    T.Eq(ns.Util.Normalize("WTB  Bold Living Ruby!!  "), "wtb bold living ruby", "normalized")
end)

T.Case("Normalize handles a link the same as plain text", function()
    T.Eq(ns.Util.Normalize("WTB " .. RUBY_LINK), "wtb bold living ruby", "normalized link")
end)

T.Case("ExtractItemIDs pulls every item id", function()
    local ids = ns.Util.ExtractItemIDs(RUBY_LINK .. " and " .. RUBY_LINK:gsub("24033", "24028"))
    T.Eq(#ids, 2, "count")
    T.Eq(ids[1], 24033, "first")
    T.Eq(ids[2], 24028, "second")
end)

T.Case("ExtractItemIDs returns empty for plain text", function()
    T.Eq(#ns.Util.ExtractItemIDs("wtb bold living ruby"), 0, "count")
end)

T.Case("HasPhrase respects word boundaries", function()
    T.Eq(ns.Util.HasPhrase("jc lfw all cuts", "lfw"), true, "lfw present")
    T.Eq(ns.Util.HasPhrase("lfwork available", "lfw"), false, "lfw not inside lfwork")
    T.Eq(ns.Util.HasPhrase("who can cut this", "can cut"), true, "multi word")
end)

T.Case("Tokenize splits on whitespace", function()
    local t = ns.Util.Tokenize("wtb bold living ruby")
    T.Eq(#t, 4, "count")
    T.Eq(t[2], "bold", "second token")
end)

T.Case("ApplyDefaults fills missing nested keys", function()
    local defaults = { a = 1, nested = { x = 10, y = 20 } }
    local target = { nested = { x = 99 } }
    ns.ApplyDefaults(target, defaults)
    T.Eq(target.a, 1, "top level filled")
    T.Eq(target.nested.x, 99, "existing value preserved")
    T.Eq(target.nested.y, 20, "nested value filled")
end)

T.Case("ApplyDefaults does not share table references", function()
    local defaults = { nested = { x = 1 } }
    local a, b = {}, {}
    ns.ApplyDefaults(a, defaults)
    ns.ApplyDefaults(b, defaults)
    a.nested.x = 42
    T.Eq(b.nested.x, 1, "b unaffected")
    T.Eq(defaults.nested.x, 1, "defaults unaffected")
end)

T.Case("Defaults carry the veto and weight tables", function()
    T.Eq(type(ns.Defaults.settings.filter.vetoWords), "table", "vetoWords")
    T.Eq(ns.Defaults.settings.filter.netThreshold, 3, "netThreshold")
    T.Eq(ns.Defaults.settings.bark.intervalSec, 180, "interval")
end)

local function scannedEntry(itemID, name, header)
    return {
        itemID = itemID, name = name, header = header or "Red",
        link = "|cffa335ee|Hitem:" .. itemID .. ":0:0:0:0:0:0:0|h[" .. name .. "]|h|r",
        classID = 3, reagents = { [23436] = 1 },
    }
end

T.Case("MergeBook adds new entries with defaults on", function()
    local book, added = ns.Scanner.MergeBook({}, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(added, 1, "added count")
    T.Eq(book[24033].name, "Bold Living Ruby", "name")
    T.Eq(book[24033].advertise, true, "advertise default")
    T.Eq(book[24033].match, true, "match default")
    T.Eq(type(book[24033].aliases), "table", "aliases default")
    T.Eq(book[24033].reagents[23436], 1, "reagents captured")
end)

T.Case("MergeBook preserves user settings across a rescan", function()
    local old = { [24033] = {
        itemID = 24033, name = "Bold Living Ruby", advertise = false,
        match = false, aliases = { "bold ruby" },
    } }
    local book, added = ns.Scanner.MergeBook(old, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(added, 0, "nothing new")
    T.Eq(book[24033].advertise, false, "advertise preserved")
    T.Eq(book[24033].match, false, "match preserved")
    T.Eq(book[24033].aliases[1], "bold ruby", "aliases preserved")
end)

T.Case("MergeBook flags missing entries stale without deleting", function()
    local old = { [24028] = { itemID = 24028, name = "Solid Star of Elune", advertise = true } }
    local book = ns.Scanner.MergeBook(old, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(book[24028] ~= nil, true, "kept")
    T.Eq(book[24028].stale, true, "flagged stale")
    T.Eq(book[24033].stale, nil, "present entry not stale")
end)

T.Case("MergeBook clears stale when a recipe returns", function()
    local old = { [24033] = { itemID = 24033, name = "Bold Living Ruby", stale = true } }
    local book = ns.Scanner.MergeBook(old, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(book[24033].stale, nil, "stale cleared")
end)

T.Case("ShouldAutoScan always scans an empty book", function()
    T.Eq(ns.Scanner.ShouldAutoScan(0, false, 999999, 1000000, 21600), true, "empty")
end)

T.Case("ShouldAutoScan scans after a skill change", function()
    T.Eq(ns.Scanner.ShouldAutoScan(173, true, 999999, 1000000, 21600), true, "dirty")
end)

T.Case("ShouldAutoScan skips a fresh clean book", function()
    T.Eq(ns.Scanner.ShouldAutoScan(173, false, 999999, 1000000, 21600), false, "fresh")
end)

T.Case("ShouldAutoScan rescans a stale book", function()
    T.Eq(ns.Scanner.ShouldAutoScan(173, false, 0, 1000000, 21600), true, "stale")
end)

local function fixtureBook()
    return {
        [24033] = { itemID = 24033, name = "Bold Living Ruby", match = true, aliases = {} },
        [24048] = { itemID = 24048, name = "Runed Living Ruby", match = true, aliases = {} },
        [24028] = { itemID = 24028, name = "Solid Star of Elune", match = true, aliases = {} },
        [23096] = { itemID = 23096, name = "Great Golden Draenite", match = true, aliases = {} },
        [99999] = { itemID = 99999, name = "Hidden Cut Gem", match = false, aliases = {} },
    }
end

local function matchIDs(text, book)
    local index = ns.Matcher.BuildIndex(book or fixtureBook())
    local hits = ns.Matcher.Match(text, ns.Util.Normalize(text), index)
    local ids = {}
    for _, h in ipairs(hits) do ids[h.itemID] = h.tier end
    return ids, hits
end

T.Case("Matcher hits an item link exactly", function()
    T.Eq(matchIDs("wtb " .. RUBY_LINK)[24033], "link", "link tier")
end)

T.Case("Matcher hits a full plain text name", function()
    T.Eq(matchIDs("wtb bold living ruby please")[24033], "name", "name tier")
end)

T.Case("Matcher hits loose shorthand", function()
    T.Eq(matchIDs("wtb bold ruby")[24033], "loose", "bold ruby")
    T.Eq(matchIDs("need a runed ruby")[24048], "loose", "runed ruby")
    T.Eq(matchIDs("lf great draenite")[23096], "loose", "great draenite")
end)

T.Case("Matcher does not fire on a bare cut prefix", function()
    T.Eq(matchIDs("boldly going where no one has gone")[24033], nil, "boldly")
    T.Eq(matchIDs("bold move friend")[24033], nil, "bold alone")
end)

T.Case("Matcher ignores entries with match disabled", function()
    T.Eq(matchIDs("wtb hidden cut gem")[99999], nil, "excluded")
end)

T.Case("Matcher respects user aliases", function()
    local book = fixtureBook()
    book[24033].aliases = { "brb gem" }
    T.Eq(matchIDs("wtb brb gem", book)[24033], "alias", "alias tier")
end)

T.Case("Matcher prefers the link tier over loose", function()
    T.Eq(matchIDs("wtb bold ruby " .. RUBY_LINK)[24033], "link", "link wins")
end)

T.Case("QtyHint reads leading and trailing counts", function()
    T.Eq(ns.Matcher.QtyHint("wtb 3 bold living ruby", "bold living ruby"), 3, "leading digit")
    T.Eq(ns.Matcher.QtyHint("wtb 2x bold living ruby", "bold living ruby"), 2, "leading 2x")
    T.Eq(ns.Matcher.QtyHint("wtb bold living ruby x4", "bold living ruby"), 4, "trailing x4")
    T.Eq(ns.Matcher.QtyHint("wtb two bold living ruby", "bold living ruby"), 2, "word number")
    T.Eq(ns.Matcher.QtyHint("wtb bold living ruby", "bold living ruby"), nil, "no hint")
end)

T.Case("Players.Similar ignores digit differences", function()
    T.Eq(ns.Players.Similar("wts jc cuts 5g", "wts jc cuts 7g"), true, "price change")
    T.Eq(ns.Players.Similar("wts jc cuts", "wtb bold ruby"), false, "different text")
end)

T.Case("Players.Observe flags a repeated ad inside the window", function()
    local msg = "wts jc cuts all cuts avail pst"
    local st, rep = ns.Players.Observe(nil, msg, 1000, 600)
    T.Eq(rep, false, "first sighting")
    T.Eq(st.flaggedSeller, nil, "not yet flagged")
    st, rep = ns.Players.Observe(st, msg, 1100, 600)
    T.Eq(rep, true, "repeat detected")
    T.Eq(st.flaggedSeller, true, "flagged")
end)

T.Case("Players.Observe does not flag outside the window", function()
    local msg = "wts jc cuts all cuts avail pst"
    local st = ns.Players.Observe(nil, msg, 1000, 600)
    local _, rep = ns.Players.Observe(st, msg, 2000, 600)
    T.Eq(rep, false, "too far apart")
end)

T.Case("Players.Observe does not flag differing messages", function()
    local st = ns.Players.Observe(nil, "wtb bold ruby", 1000, 600)
    local st2, rep = ns.Players.Observe(st, "wtb runed ruby too", 1100, 600)
    T.Eq(rep, false, "different message")
    T.Eq(st2.flaggedSeller, nil, "not flagged")
end)

local function classify(text, over)
    over = over or {}
    local index = ns.Matcher.BuildIndex(over.book or fixtureBook())
    local norm = ns.Util.Normalize(text)
    return ns.Classifier.Evaluate({
        norm = norm,
        raw = text,
        matched = ns.Matcher.Match(text, norm, index),
        linkCount = #ns.Util.ExtractItemIDs(text),
        hasDesignLink = over.hasDesignLink or false,
        isRepeat = over.isRepeat or false,
        playerState = over.playerState,
        blocked = over.blocked,
        filter = over.filter or ns.DeepCopy(ns.Defaults.settings.filter),
    })
end

T.Case("Classifier vetoes JC LFW", function()
    local r = classify("JC LFW all cuts pst " .. RUBY_LINK)
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "lfw", "reason")
end)

T.Case("Classifier vetoes a WTS advertisement", function()
    local r = classify("WTS " .. RUBY_LINK .. " 5g")
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "wts", "reason")
end)

T.Case("Classifier vetoes LF work", function()
    T.Eq(classify("LF work jewelcrafter all cuts avail " .. RUBY_LINK).verdict, "vetoed", "verdict")
end)

T.Case("Classifier blocks can cut advertisements by score", function()
    local r = classify("Can cut any cut, mats + tip " .. RUBY_LINK)
    T.Eq(r.verdict, "lowscore", "not a veto")
    T.Eq(r.sellerScore >= 3, true, "seller score at or above threshold")
end)

T.Case("Classifier invites when can cut is guarded by anyone", function()
    T.Eq(classify("anyone who can cut " .. RUBY_LINK .. "? have mats").verdict, "invite", "verdict")
end)

T.Case("Classifier invites a plain WTB", function()
    T.Eq(classify("WTB bold ruby have mats").verdict, "invite", "verdict")
end)

T.Case("Classifier invites a question form request", function()
    T.Eq(classify("any jc able to cut " .. RUBY_LINK .. "?").verdict, "invite", "verdict")
end)

T.Case("Classifier invites LF plus will tip", function()
    T.Eq(classify("LF " .. RUBY_LINK .. " will tip").verdict, "invite", "verdict")
end)

T.Case("Classifier withholds an invite for a bare link", function()
    local r = classify(RUBY_LINK)
    T.Eq(r.verdict, "lowscore", "verdict")
    T.Eq(r.buyerScore, 0, "no buyer signal")
end)

T.Case("Classifier invites a bare link when requireBuyerSignal is off", function()
    local filter = ns.DeepCopy(ns.Defaults.settings.filter)
    filter.requireBuyerSignal = false
    T.Eq(classify(RUBY_LINK, { filter = filter }).verdict, "invite", "verdict")
end)

T.Case("Classifier scores manyLinks against three or more links", function()
    local three = RUBY_LINK .. " " .. RUBY_LINK:gsub("24033", "24048")
        .. " " .. RUBY_LINK:gsub("24033", "23096")
    T.Eq(classify("gems available " .. three).sellerHits.manyLinks, 3, "manyLinks weight")
end)

T.Case("Classifier scores a design link heavily", function()
    local r = classify("check these out " .. RUBY_LINK, { hasDesignLink = true })
    T.Eq(r.sellerHits.designLink, 4, "designLink weight")
end)

T.Case("Classifier applies the repeat bark weight", function()
    local r = classify("gems here " .. RUBY_LINK, { isRepeat = true })
    T.Eq(r.sellerHits.repeatBark, 5, "repeatBark weight")
end)

T.Case("Classifier vetoes a previously flagged seller", function()
    local r = classify("WTB bold ruby have mats", { playerState = { flaggedSeller = true } })
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "flagged seller", "reason")
end)

T.Case("Classifier reports an operational block without changing the verdict", function()
    -- Operational state must not decide content, or the addon cannot explain
    -- why it would have invited someone while invites are switched off.
    local r = classify("WTB bold ruby have mats", { blocked = "cooldown" })
    T.Eq(r.verdict, "invite", "content verdict still computed")
    T.Eq(r.blocked, "cooldown", "block reported separately")
    T.Eq(r.buyerScore > 0, true, "still scored")
end)

T.Case("Classifier still scores a vetoed message", function()
    local r = classify("WTS " .. RUBY_LINK .. " all cuts 5g")
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.sellerHits["all cuts"], 3, "signals recorded despite the veto")
end)

T.Case("Classifier does not fire without a gem match", function()
    local r = classify("WTB a mount have gold")
    T.Eq(r.verdict, "lowscore", "verdict")
    T.Eq(r.reason, "no gem match", "reason")
end)

T.Case("Classifier does not match boldly as a gem", function()
    T.Eq(classify("boldly going where no one has gone before").reason, "no gem match", "reason")
end)

T.Case("Log.Push caps the buffer at 100 entries", function()
    local log = {}
    for i = 1, 120 do ns.Log.Push(log, { id = i }) end
    T.Eq(#log, 100, "capped")
    T.Eq(log[1].id, 120, "newest first")
    T.Eq(log[100].id, 21, "oldest retained")
end)

T.Case("Log.Describe summarises a verdict", function()
    local line = ns.Log.Describe({
        player = "Bob", verdict = "vetoed", reason = "lfw",
        sellerScore = 0, buyerScore = 0, msg = "JC LFW",
    })
    T.Eq(line:find("Bob", 1, true) ~= nil, true, "names the player")
    T.Eq(line:find("lfw", 1, true) ~= nil, true, "gives the reason")
end)

T.Case("BlockReason reports the invite cooldown", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    T.Eq(ns.Inviter.BlockReason({ lastInviteAt = 1000 }, 1100, 1, s), "cooldown", "reason")
end)

T.Case("BlockReason clears once the cooldown expires", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    T.Eq(ns.Inviter.BlockReason({ lastInviteAt = 1000 }, 2000, 1, s), nil, "cleared")
end)

T.Case("BlockReason reports a full group", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    T.Eq(ns.Inviter.BlockReason({}, 5000, 5, s), "group full", "reason")
end)

T.Case("BlockReason reports auto invite disabled", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    s.enabled = false
    T.Eq(ns.Inviter.BlockReason({}, 5000, 1, s), "invites disabled", "reason")
end)
