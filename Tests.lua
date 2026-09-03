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
    -- Written to SavedVariables so failures can be read off disk after a
    -- /reload instead of being retyped out of the chat frame.
    ns.db.lastTestRun = { at = GetServerTime and GetServerTime() or time(), failures = {} }

    for _, c in ipairs(T.cases) do
        local ok, err = pcall(c.fn)
        if ok then
            pass = pass + 1
        else
            fail = fail + 1
            ns.Print("|cffff4444FAIL|r " .. c.name .. " => " .. tostring(err))
            local f = ns.db.lastTestRun.failures
            f[#f + 1] = { name = c.name, err = tostring(err) }
        end
    end
    ns.db.lastTestRun.passed = pass
    ns.db.lastTestRun.failed = fail
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
        [24033] = { itemID = 24033, name = "Bold Living Ruby",
                    classID = 3, bindType = 0, match = true, aliases = {} },
        [24048] = { itemID = 24048, name = "Runed Living Ruby",
                    classID = 3, bindType = 0, match = true, aliases = {} },
        [24028] = { itemID = 24028, name = "Solid Star of Elune",
                    classID = 3, bindType = 0, match = true, aliases = {} },
        [23096] = { itemID = 23096, name = "Great Golden Draenite",
                    classID = 3, bindType = 0, match = true, aliases = {} },
        [99999] = { itemID = 99999, name = "Hidden Cut Gem",
                    classID = 3, bindType = 0, match = false, aliases = {} },
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

local function barkEntries(n)
    local out = {}
    for i = 1, n do
        local id = 24000 + i
        out[i] = { itemID = id,
            link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0|h[Bold Living Ruby]|h|r" }
    end
    return out
end

local BARK_TPL = "WTS JC cuts: {gems} and more! /w me"

T.Case("Barker.Fit stays within the 255 character cap", function()
    local msg = ns.Barker.Fit(barkEntries(40), 1, BARK_TPL, 255, 4)
    T.Eq(msg ~= nil, true, "message built")
    T.Eq(#msg <= 255, true, "within cap, got " .. #msg)
end)

T.Case("Barker.Fit advances the cursor by the number used", function()
    local _, nextCursor, used = ns.Barker.Fit(barkEntries(40), 1, BARK_TPL, 255, 4)
    T.Eq(used >= 2, true, "at least two links fit")
    T.Eq(nextCursor, 1 + used, "cursor advanced by used")
end)

T.Case("Barker.Fit wraps at the end of the list", function()
    local entries = barkEntries(5)
    local _, nextCursor, used = ns.Barker.Fit(entries, 4, BARK_TPL, 255, 4)
    T.Eq(used > 0, true, "something was used")
    T.Eq(nextCursor <= #entries, true, "cursor wrapped into range, got " .. nextCursor)
end)

T.Case("Barker.Fit honours perBark", function()
    local _, _, used = ns.Barker.Fit(barkEntries(40), 1, BARK_TPL, 255, 2)
    T.Eq(used, 2, "capped at perBark")
end)

T.Case("Barker.Fit rejects a template without the gems placeholder", function()
    T.Eq(ns.Barker.Fit(barkEntries(5), 1, "WTS JC cuts, no placeholder", 255, 4), nil, "rejected")
end)

T.Case("Barker.Fit returns nil for an empty list", function()
    T.Eq(ns.Barker.Fit({}, 1, BARK_TPL, 255, 4), nil, "nil")
end)

local function classifyWhisper(text, over)
    over = over or {}
    local index = ns.Matcher.BuildIndex(over.book or fixtureBook())
    local norm = ns.Util.Normalize(text)
    local filter = ns.DeepCopy(ns.Defaults.settings.filter)
    filter.requireBuyerSignal = false
    return ns.Classifier.Evaluate({
        norm = norm,
        raw = text,
        matched = ns.Matcher.Match(text, norm, index),
        linkCount = #ns.Util.ExtractItemIDs(text),
        hasDesignLink = false,
        isRepeat = false,
        isDirect = true,
        filter = filter,
    })
end

T.Case("Whisper naming a bare gem is a request", function()
    T.Eq(classifyWhisper(RUBY_LINK).verdict, "invite", "bare link in whisper invites")
    T.Eq(classifyWhisper("bold living ruby please").verdict, "invite", "plain text")
end)

T.Case("Whisper does not penalise a customer listing several gems", function()
    local three = RUBY_LINK .. " " .. RUBY_LINK:gsub("24033", "24048")
        .. " " .. RUBY_LINK:gsub("24033", "23096")
    local r = classifyWhisper("can you do " .. three)
    T.Eq(r.sellerHits.manyLinks, nil, "manyLinks suppressed in whispers")
    T.Eq(r.verdict, "invite", "verdict")
end)

T.Case("Whisper still vetoes someone selling to us", function()
    T.Eq(classifyWhisper("WTS " .. RUBY_LINK .. " 300g").verdict, "vetoed", "wts veto holds")
    T.Eq(classifyWhisper("JC LFW " .. RUBY_LINK).verdict, "vetoed", "lfw veto holds")
end)

local function qualityBook()
    return {
        [24033] = { itemID = 24033, name = "Bold Living Ruby",           classID = 3, quality = 3 },
        [32196] = { itemID = 32196, name = "Bold Crimson Spinel",        classID = 3, quality = 4 },
        [20969] = { itemID = 20969, name = "Lustrous Azure Moonstone",   classID = 3, quality = 2 },
        [10978] = { itemID = 10978, name = "A Falling Star",             classID = 3, quality = 2 },
        [25500] = { itemID = 25500, name = "Braided Copper Ring",        classID = 4, quality = 1 },
    }
end

T.Case("ApplyAdvertiseFilter rare keeps only rare and epic gems", function()
    local book = qualityBook()
    local n = ns.Barker.ApplyAdvertiseFilter(book, "rare")
    T.Eq(n, 2, "count")
    T.Eq(book[24033].advertise, true, "rare gem kept")
    T.Eq(book[32196].advertise, true, "epic gem kept")
    T.Eq(book[20969].advertise, false, "uncommon gem dropped")
    T.Eq(book[10978].advertise, false, "vanilla junk dropped")
    T.Eq(book[25500].advertise, false, "non gem dropped")
end)

T.Case("ApplyAdvertiseFilter all and none are absolute", function()
    local book = qualityBook()
    T.Eq(ns.Barker.ApplyAdvertiseFilter(book, "all"), 5, "all")
    T.Eq(ns.Barker.ApplyAdvertiseFilter(book, "none"), 0, "none")
end)

T.Case("SetAdvertiseMatching toggles by name substring", function()
    local book = qualityBook()
    ns.Barker.ApplyAdvertiseFilter(book, "none")
    T.Eq(ns.Barker.SetAdvertiseMatching(book, "crimson spinel", true), 1, "matched one")
    T.Eq(book[32196].advertise, true, "enabled")
    T.Eq(book[24033].advertise, false, "others untouched")
end)

T.Case("ApplyAdvertiseFilter epic keeps only epic gems", function()
    local book = qualityBook()
    local n = ns.Barker.ApplyAdvertiseFilter(book, "epic")
    T.Eq(n, 1, "count")
    T.Eq(book[32196].advertise, true, "epic gem kept")
    T.Eq(book[24033].advertise, false, "rare gem dropped")
    T.Eq(book[20969].advertise, false, "uncommon gem dropped")
end)

T.Case("NearMiss finds a known gem family from an unknown cut", function()
    local book = fixtureBook()
    book[24099] = { itemID = 24099, name = "Glowing Living Ruby",
                    classID = 3, match = true, aliases = {} }
    local index = ns.Matcher.BuildIndex(book)
    local norm = ns.Util.Normalize("can you do a Sparkling Living Ruby?")
    T.Eq(#ns.Matcher.Match("x", norm, index), 0, "no direct match")
    local family, ids = ns.Matcher.NearMiss(norm, index)
    T.Eq(family, "living ruby", "family")
    T.Eq(#ids, 3, "three known cuts of that family")
end)

T.Case("NearMiss returns nothing for unrelated text", function()
    local index = ns.Matcher.BuildIndex(fixtureBook())
    T.Eq(ns.Matcher.NearMiss(ns.Util.Normalize("lfg deadmines"), index), nil, "no family")
end)

T.Case("NearMiss prefers the longest matching family", function()
    local book = {
        [1] = { itemID = 1, name = "Balanced Shadowsong Amethyst",
                classID = 3, match = true, aliases = {} },
        [2] = { itemID = 2, name = "Bold Amethyst",
                classID = 3, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    local family = ns.Matcher.NearMiss(
        ns.Util.Normalize("wtb shifting shadowsong amethyst"), index)
    T.Eq(family, "shadowsong amethyst", "longest family wins")
end)

T.Case("Classifier invites a bare LF JC with no gem named", function()
    local r = classify("LF JC")
    T.Eq(r.verdict, "invite", "verdict")
    T.Eq(r.reason, "jc request", "reason")
    T.Eq(r.professionRequest, true, "flagged as a profession request")
end)

T.Case("Classifier invites other ways of asking for a jeweller", function()
    T.Eq(classify("anyone know a jc online?").verdict, "invite", "jc online")
    T.Eq(classify("need a jewelcrafter for some cuts").verdict, "invite", "need a jewelcrafter")
end)

T.Case("Classifier vetoes a competitor even when the text reads as a JC request", function()
    -- "any jc" makes this gem-relevant, so it reaches scoring, and the veto
    -- must still beat it. Word order keeps LF JC and JC LFW distinct.
    local r = classify("any jc lfw here, all cuts available")
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "lfw", "veto wins over the profession request")
end)

T.Case("Competitor ad naming no gem is ignored rather than vetoed", function()
    -- Correct outcome, just a different label: it never reaches the veto list
    -- because it is out of scope. Keeping vetoes scoped to gem-relevant
    -- messages is what stops every WTS in trade chat filling the log.
    local r = classify("JC LFW all cuts available pst")
    T.Eq(r.verdict, "lowscore", "not invited")
    T.Eq(r.reason, "no gem match", "out of scope before vetoes are consulted")
end)

T.Case("Classifier ignores requests for other professions", function()
    T.Eq(classify("LF enchanter for boots").reason, "no gem match", "not our trade")
end)

local function reagentBook()
    return {
        -- Bold and Runed Living Ruby both consume one Living Ruby (23436).
        [24033] = { itemID = 24033, name = "Bold Living Ruby",
                    reagents = { [23436] = 1 } },
        [24048] = { itemID = 24048, name = "Runed Living Ruby",
                    reagents = { [23436] = 1 } },
        [24028] = { itemID = 24028, name = "Solid Star of Elune",
                    reagents = { [23440] = 1 } },
        [99998] = { itemID = 99998, name = "Soulbound Figurine",
                    reagents = { [23441] = 1 }, bindType = 1 },
    }
end

local function orderFor(itemIDs, qty)
    local o = { items = {}, matsReceived = {} }
    for _, id in ipairs(itemIDs) do
        o.items[#o.items + 1] = { itemID = id, qty = qty or 1, qtySource = "default" }
    end
    return o
end

T.Case("InferQuantities takes the count from the mats, not the text", function()
    local o = orderFor({ 24033 })
    o.items[1].qty = 1
    local split = ns.Orders.InferQuantities(o, { [23436] = 3 }, reagentBook())
    T.Eq(split, false, "unambiguous")
    T.Eq(o.items[1].qty, 3, "quantity from mats")
    T.Eq(o.items[1].qtySource, "mats", "source")
end)

T.Case("InferQuantities overrides a stated text quantity", function()
    local o = orderFor({ 24033 })
    o.items[1].qty = 2
    o.items[1].qtySource = "text"
    ns.Orders.InferQuantities(o, { [23436] = 3 }, reagentBook())
    T.Eq(o.items[1].qty, 3, "mats win over the text hint")
end)

T.Case("InferQuantities flags an ambiguous split instead of guessing", function()
    local o = orderFor({ 24033, 24048 })
    local split = ns.Orders.InferQuantities(o, { [23436] = 3 }, reagentBook())
    T.Eq(split, true, "needsSplit")
    T.Eq(o.items[1].qtySource, "ambiguous", "not silently allocated")
    T.Eq(o.items[2].qtySource, "ambiguous", "not silently allocated")
end)

T.Case("InferQuantities adds a cut they did not ask for", function()
    local o = orderFor({ 24033 })
    local _, added = ns.Orders.InferQuantities(o, { [23440] = 2 }, reagentBook())
    T.Eq(#added, 1, "one item added")
    T.Eq(added[1].itemID, 24028, "matched the reagent to the right cut")
    T.Eq(added[1].qty, 2, "quantity from mats")
end)

T.Case("InferQuantities never adds a bind on pickup craft", function()
    local o = orderFor({ 24033 })
    local _, added = ns.Orders.InferQuantities(o, { [23441] = 2 }, reagentBook())
    T.Eq(#added, 0, "soulbound craft cannot be delivered, so not added")
end)

T.Case("Ledger.SumSince only counts recent entries", function()
    local entries = {
        { at = 1000, copper = 5000, gems = { [1] = 2 } },
        { at =  100, copper = 9000, gems = { [1] = 1 } },
    }
    local copper, gems, n = ns.Ledger.SumSince(entries, 500)
    T.Eq(copper, 5000, "copper")
    T.Eq(gems, 2, "gems")
    T.Eq(n, 1, "entries")
end)

T.Case("Trade.Classify separates raw mats from finished cuts", function()
    local snapshot = {
        incoming = { [23436] = 3, [24033] = 1 },
        outgoing = { [24048] = 2 },
    }
    local raw, cuts, delivered = ns.Trade.Classify(snapshot, reagentBook())
    T.Eq(raw[23436], 3, "raw gem")
    T.Eq(raw[24033], nil, "a known cut is not raw")
    T.Eq(cuts[24033], 1, "known cut incoming")
    T.Eq(delivered[24048], 2, "delivered cut")
end)

T.Case("ApplyAdvertiseFilter never advertises bind on pickup", function()
    local book = {
        [1] = { itemID = 1, name = "Epic Gem",  classID = 3, quality = 4 },
        [2] = { itemID = 2, name = "Bound Gem", classID = 3, quality = 4, bindType = 1 },
    }
    T.Eq(ns.Barker.ApplyAdvertiseFilter(book, "all"), 1, "all still excludes BoP")
    T.Eq(book[2].advertise, false, "bop excluded")
end)

T.Case("Matcher skips bind on pickup crafts", function()
    local book = {
        [1] = { itemID = 1, name = "Bold Living Ruby",
                classID = 3, match = true, aliases = {} },
        [2] = { itemID = 2, name = "Bound Living Ruby", classID = 3,
                match = true, aliases = {}, bindType = 1 },
    }
    local index = ns.Matcher.BuildIndex(book)
    T.Eq(index.byID[2], nil, "bop not indexed")
    T.Eq(index.byID[1], true, "tradeable cut indexed")
end)

T.Case("WantedFromOrder never wants a soulbound craft", function()
    local book = {
        [1] = { itemID = 1, name = "Tradeable Cut" },
        [2] = { itemID = 2, name = "Soulbound Cut", bindType = 1 },
    }
    local order = { items = { { itemID = 1, qty = 3 }, { itemID = 2, qty = 1 } } }
    local wanted = ns.Trade.WantedFromOrder(order, book)
    T.Eq(wanted[1], 3, "tradeable cut wanted")
    T.Eq(wanted[2], nil, "soulbound cut never queued, cannot be traded")
end)

T.Case("WantedFromOrder sums duplicate line items for the same cut", function()
    local book = { [1] = { itemID = 1, name = "X" } }
    local order = { items = { { itemID = 1, qty = 2 }, { itemID = 1, qty = 4 } } }
    T.Eq(ns.Trade.WantedFromOrder(order, book)[1], 6, "quantities summed")
end)

T.Case("NextFillSlot finds a bag row for a many-of-one order", function()
    -- Regression for the "only ever adds 2" bug: the fix must never rely on
    -- coordinates computed before a move, so this simulates a FRESH scan
    -- each call the same way the real ticker does, against a stack that is
    -- split across two different bag positions.
    local wanted = { [50] = 6 }
    local snapshot = {
        { bag = 0, slot = 3, itemID = 50, link = "gem50", count = 4 },
        { bag = 1, slot = 1, itemID = 50, link = "gem50", count = 2 },
    }
    local row = ns.Trade.NextFillSlot(wanted, snapshot)
    T.Eq(row.bag, 0, "first matching row")
    T.Eq(row.count, 4, "reports the real stack size, not an assumed 1")

    wanted[50] = wanted[50] - row.count
    T.Eq(wanted[50], 2, "still wants the rest")

    -- A real re-scan happens AFTER row 1's stack has physically left the bag
    -- (UseContainerItem already moved it), so it would no longer appear.
    -- Reusing the original snapshot here would just find row 1 again, since
    -- NextFillSlot has no notion of "already consumed" -- that guarantee
    -- comes from BagSnapshot() being called fresh each tick in production.
    local afterFirstMove = { snapshot[2] }
    local row2 = ns.Trade.NextFillSlot(wanted, afterFirstMove)
    T.Eq(row2.bag, 1, "second stack found on the next fresh scan")
end)

T.Case("NextFillSlot handles multiple different gems in one order", function()
    local wanted = { [10] = 2, [20] = 1 }
    local snapshot = {
        { bag = 0, slot = 1, itemID = 99, link = "unrelated", count = 1 },
        { bag = 0, slot = 2, itemID = 20, link = "gem20", count = 1 },
        { bag = 0, slot = 3, itemID = 10, link = "gem10", count = 2 },
    }
    local row = ns.Trade.NextFillSlot(wanted, snapshot)
    T.Eq(row.itemID, 20, "skips the unrelated item, finds the first wanted one")
end)

T.Case("NextFillSlot returns nil once everything is satisfied", function()
    local wanted = { [1] = 0 }
    local snapshot = { { bag = 0, slot = 1, itemID = 1, link = "x", count = 5 } }
    T.Eq(ns.Trade.NextFillSlot(wanted, snapshot), nil, "nothing left to fill")
end)

T.Case("Loose matching ignores filler words", function()
    local book = {
        [21779] = { itemID = 21779, name = "Band of Natural Fire",
                    classID = 3, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    -- A raid ad reading "band of karabor" must not match on band + of.
    local norm = ns.Util.Normalize(
        "LFM BT tonight, floor loot, band of karabor HR, LF ret")
    T.Eq(#ns.Matcher.Match("x", norm, index), 0, "no false match on filler words")
end)

T.Case("Loose matching does not apply to jewelry", function()
    local book = {
        [21779] = { itemID = 21779, name = "Band of Natural Fire",
                    classID = 4, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    T.Eq(#index.loose, 0, "rings get no loose entry")
    -- The full name still matches.
    local norm = ns.Util.Normalize("wtb band of natural fire")
    T.Eq(#ns.Matcher.Match("x", norm, index), 1, "full name still works")
end)

T.Case("Solid Star of Elune keeps working despite containing 'of'", function()
    -- Stopwords are dropped from the bases, but "star" and "elune" remain,
    -- so real shorthand still resolves.
    T.Eq(matchIDs("wtb solid elune")[24028], "loose", "still matches")
end)

local function classifyParty(text)
    local index = ns.Matcher.BuildIndex(fixtureBook())
    local norm = ns.Util.Normalize(text)
    local filter = ns.DeepCopy(ns.Defaults.settings.filter)
    filter.requireBuyerSignal = false
    return ns.Classifier.Evaluate({
        norm = norm, raw = text,
        matched = ns.Matcher.Match(text, norm, index),
        linkCount = #ns.Util.ExtractItemIDs(text),
        isDirect = true, filter = filter,
    })
end

T.Case("Party chat naming a gem counts as the order", function()
    T.Eq(classifyParty("bold living ruby please").verdict, "invite", "plain name")
    T.Eq(classifyParty(RUBY_LINK).verdict, "invite", "bare link")
end)

T.Case("Party chat does not penalise listing several gems", function()
    local three = RUBY_LINK .. " " .. RUBY_LINK:gsub("24033", "24048")
        .. " " .. RUBY_LINK:gsub("24033", "23096")
    local r = classifyParty("can you do " .. three)
    T.Eq(r.sellerHits.manyLinks, nil, "broadcast signal suppressed")
    T.Eq(r.verdict, "invite", "verdict")
end)

T.Case("A profession request naming a cut we lack does not invite", function()
    -- "LF JC'er with [Veiled Pyrestone] pst": they named one specific cut and
    -- it is not ours, so the LF JC phrase must not carry it through.
    local index = ns.Matcher.BuildIndex(fixtureBook())
    local text = "LF JC'er with [Veiled Pyrestone] pst"
    local norm = ns.Util.Normalize(text)
    local r = ns.Classifier.Evaluate({
        norm = norm, raw = text,
        matched = ns.Matcher.Match(text, norm, index),
        linkCount = 0,
        namedUnknownGem = true,
        filter = ns.DeepCopy(ns.Defaults.settings.filter),
    })
    T.Eq(r.verdict, "lowscore", "no invite")
    T.Eq(r.reason, "named a cut we lack", "reason")
end)

T.Case("A bare profession request still invites", function()
    local index = ns.Matcher.BuildIndex(fixtureBook())
    local norm = ns.Util.Normalize("LF JC")
    local r = ns.Classifier.Evaluate({
        norm = norm, raw = "LF JC",
        matched = ns.Matcher.Match("LF JC", norm, index),
        linkCount = 0,
        namedUnknownGem = false,
        filter = ns.DeepCopy(ns.Defaults.settings.filter),
    })
    T.Eq(r.verdict, "invite", "still invites when nothing specific was named")
end)

-- Real Trade chat message from Goopyfloyd that got dropped with
-- reason "no buyer signal": "LF JEWELCRAFTER" is a professionWords phrase
-- but was never mirrored into buyerWords, so requireBuyerSignal blocked it
-- even though isProfReq was true.
T.Case("A profession request worded without 'jc' still invites", function()
    local r = classify("LF JEWELCRAFTER")
    T.Eq(r.verdict, "invite", "verdict")
    T.Eq(r.professionRequest, true, "flagged as a profession request")
end)

-- Also from Goopyfloyd, same session: "LF SOMEONE WHO CAN MAKE [gem]" matched
-- the gem name but scored zero buyer signal, since only "can cut" phrasing
-- was recognised, not "can make".
T.Case("Someone who can make a named gem is a buyer, not just can cut", function()
    local r = classify("LF someone who can make bold living ruby")
    T.Eq(r.verdict, "invite", "verdict")
end)

T.Case("A profession request naming a cut we DO have invites", function()
    local text = "LF JC for " .. RUBY_LINK
    local index = ns.Matcher.BuildIndex(fixtureBook())
    local norm = ns.Util.Normalize(text)
    local r = ns.Classifier.Evaluate({
        norm = norm, raw = text,
        matched = ns.Matcher.Match(text, norm, index),
        linkCount = 1,
        namedUnknownGem = false,
        filter = ns.DeepCopy(ns.Defaults.settings.filter),
    })
    T.Eq(r.verdict, "invite", "verdict")
    T.Eq(r.reason, "matched", "matched a real cut")
end)

T.Case("ExtractItemLinks returns each full link with its id", function()
    local two = RUBY_LINK .. RUBY_LINK:gsub("24033", "24048")
    local links = ns.Util.ExtractItemLinks(two)
    T.Eq(#links, 2, "count")
    T.Eq(links[1].id, 24033, "first id")
    T.Eq(links[2].id, 24048, "second id")
    T.Eq(links[1].link:find("Bold Living Ruby", 1, true) ~= nil, true, "keeps the link text")
end)

T.Case("ExtractItemLinks copes with no links", function()
    T.Eq(#ns.Util.ExtractItemLinks("got both?"), 0, "none")
end)

local ASK = ns.Defaults.settings.filter.askPhrases

T.Case("IsAvailabilityQuestion spots a direct question", function()
    local function q(t) return ns.Util.IsAvailabilityQuestion(t, ns.Util.Normalize(t), ASK) end
    T.Eq(q("Do you have veiled pyrestone cut?"), true, "do you have")
    T.Eq(q("got [Bold Crimson Spinel]?"), true, "got")
    T.Eq(q("can you cut this one?"), true, "can you cut")
    T.Eq(q("any chance you have a bold ruby?"), true, "any chance")
end)

T.Case("IsAvailabilityQuestion ignores someone thinking out loud", function()
    local function q(t) return ns.Util.IsAvailabilityQuestion(t, ns.Util.Normalize(t), ASK) end
    -- The real message that got auto-answered with a sales pitch.
    T.Eq(q("do why are so many cuts less expensive than [Crimson Spinel]"), false,
        "no question mark and no availability phrase")
    T.Eq(q("hey whats up?"), false, "question mark alone is not enough")
    T.Eq(q("i have all the cuts"), false, "no question mark")
end)

T.Case("RecentText stitches together what someone just said", function()
    local st = {}
    ns.Players.PushRecent(st, "Shifting Shadowsong?", 1000)
    ns.Players.PushRecent(st, "Amethyst", 1010)
    T.Eq(ns.Players.RecentText(st, 1015, 90), "Shifting Shadowsong? Amethyst", "joined")
    T.Eq(ns.Players.RecentText(st, 2000, 90), "", "old messages drop out")
end)

T.Case("A gem named across two messages matches once combined", function()
    local book = {
        [32637] = { itemID = 32637, name = "Balanced Shadowsong Amethyst",
                    classID = 3, bindType = 0, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    -- A cut prefix on its own is not enough: loose matching needs the prefix
    -- AND a base word, so "Balanced" alone finds nothing.
    T.Eq(#ns.Matcher.Match("x", ns.Util.Normalize("Balanced"), index), 0,
        "first fragment matches nothing")
    T.Eq(#ns.Matcher.Match("x", ns.Util.Normalize("Shadowsong Amethyst"), index), 0,
        "second fragment alone has no cut prefix")
    local combined = "Balanced Shadowsong Amethyst"
    T.Eq(#ns.Matcher.Match(combined, ns.Util.Normalize(combined), index), 1,
        "the two together resolve to one cut")
end)

T.Case("NearMiss recognises a single distinctive family word", function()
    local book = {
        [1] = { itemID = 1, name = "Balanced Shadowsong Amethyst",
                classID = 3, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    local family = ns.Matcher.NearMiss(ns.Util.Normalize("shifting shadowsong?"), index)
    T.Eq(family, "shadowsong", "partial family name recognised")
end)

T.Case("NearMiss does not fire on short common words", function()
    local book = {
        [1] = { itemID = 1, name = "Solid Star of Elune",
                classID = 3, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    T.Eq(ns.Matcher.NearMiss(ns.Util.Normalize("look at that star"), index), nil,
        "star is too short and too common")
end)

T.Case("OpenList only counts people who actually joined", function()
    local saved = ns.db.orders
    ns.db.orders = {
        { id = 1, player = "A", status = "pending",   items = {} },
        { id = 2, player = "B", status = "grouped",   items = {} },
        { id = 3, player = "C", status = "mats",      items = {} },
        { id = 4, player = "D", status = "done",      items = {} },
        { id = 5, player = "E", status = "cancelled", items = {} },
    }
    T.Eq(#ns.Orders.OpenList(), 2, "grouped and mats only")
    T.Eq(#ns.Orders.ActiveList(), 3, "pending included in the full picture")
    T.Eq(ns.Orders.PendingCount(), 1, "one still waiting to join")
    T.Eq(ns.Orders.PendingList()[1].player, "A", "pending list surfaces who it is, not just a count")
    T.Eq(ns.Orders.ByID(3).player, "C", "lookup by id")
    ns.db.orders = saved
end)

T.Case("ExpireStale cancels a pending order nobody joined for in time", function()
    local saved = ns.db.orders
    ns.db.orders = {
        { id = 1, player = "A", status = "pending", createdAt = 1000, items = {} },
        { id = 2, player = "B", status = "pending", createdAt = 1290, items = {} },
        { id = 3, player = "C", status = "grouped", createdAt = 1000, items = {} },
    }
    local expired = ns.Orders.ExpireStale(1300, 300)
    T.Eq(#expired, 1, "only the one past the timeout")
    T.Eq(ns.Orders.ByID(1).status, "cancelled", "A timed out")
    T.Eq(ns.Orders.ByID(2).status, "pending", "B is not there yet")
    T.Eq(ns.Orders.ByID(3).status, "grouped",
        "already grouped is not touched by the pending timeout")
    ns.db.orders = saved
end)

T.Case("CancelPending closes an order for someone who declined", function()
    local saved = ns.db.orders
    ns.db.orders = { { id = 1, player = "Goopyfloyd", status = "pending", items = {} } }
    local o = ns.Orders.CancelPending("Goopyfloyd", 5000)
    T.Eq(o.status, "cancelled", "declined order is cancelled")
    T.Eq(ns.Orders.Open("Goopyfloyd"), nil, "no longer open")
    ns.db.orders = saved
end)

T.Case("CancelPending leaves an order alone once they have actually grouped", function()
    local saved = ns.db.orders
    ns.db.orders = { { id = 1, player = "Goopyfloyd", status = "grouped", items = {} } }
    local o = ns.Orders.CancelPending("Goopyfloyd", 5000)
    T.Eq(o, nil, "grouped orders are not what CancelPending touches")
    T.Eq(ns.Orders.ByID(1).status, "grouped", "unchanged")
    ns.db.orders = saved
end)

T.Case("DeclinedName reads a player out of the system decline message", function()
    local fmt = "%s declines your group invitation."
    T.Eq(ns.Inviter.DeclinedName("Goopyfloyd declines your group invitation.", fmt),
        "Goopyfloyd", "name extracted")
    T.Eq(ns.Inviter.DeclinedName("Something unrelated happened.", fmt), nil,
        "unrelated system message does not match")
end)

T.Case("NearMiss reports whether the family name was complete", function()
    local book = {
        [1] = { itemID = 1, name = "Balanced Shadowsong Amethyst",
                classID = 3, match = true, aliases = {} },
        [2] = { itemID = 2, name = "Potent Pyrestone",
                classID = 3, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)

    local _, _, exact = ns.Matcher.NearMiss(
        ns.Util.Normalize("do you have veiled pyrestone cut?"), index)
    T.Eq(exact, true, "pyrestone is the whole family name, so they finished")

    local fam, ids, exact2 = ns.Matcher.NearMiss(
        ns.Util.Normalize("shifting shadowsong?"), index)
    T.Eq(fam, "shadowsong", "family")
    T.Eq(exact2, false, "amethyst missing, so the name is incomplete")
    T.Eq(#ids, 1, "one known cut in that family")
end)

T.Case("The master switch reports itself as enabled by default", function()
    local saved = ns.db.settings.enabled
    ns.db.settings.enabled = true
    T.Eq(ns.Enabled(), true, "on")
    ns.db.settings.enabled = false
    T.Eq(ns.Enabled(), false, "off")
    ns.db.settings.enabled = saved
end)

T.Case("Barking refuses while the addon is disabled", function()
    local saved = ns.db.settings.enabled
    ns.db.settings.enabled = false
    local ok, reason = ns.Barker.Tick(true)
    T.Eq(ok, false, "even a forced bark is refused")
    T.Eq(reason, "CutMaster is disabled", "reason")
    ns.db.settings.enabled = saved
end)

T.Case("An invite acknowledges every cut requested, not just the first", function()
    -- Regression: Inviter.Invite only ever read matched[1], so a request for
    -- two gems came back acknowledging one.
    local text = "WTB " .. RUBY_LINK .. " " .. RUBY_LINK:gsub("24033", "24048")
    local index = ns.Matcher.BuildIndex(fixtureBook())
    local hits = ns.Matcher.Match(text, ns.Util.Normalize(text), index)
    T.Eq(#hits, 2, "both gems matched")
    T.Eq(hits[1].itemID ~= hits[2].itemID, true, "two distinct cuts")
end)

T.Case("A bark is due measured from the last one actually sent", function()
    -- Sending by hand resets the clock: the reminder must not fire a few
    -- seconds later just because the interval elapsed since barking was
    -- switched on.
    T.Eq(ns.Barker.IsDue(1000, 1179, 180), false, "not yet")
    T.Eq(ns.Barker.IsDue(1000, 1180, 180), true, "exactly due")
    T.Eq(ns.Barker.IsDue(1000, 5000, 180), true, "long overdue")
    -- now is a real epoch timestamp, so with lastSentAt unset the elapsed
    -- time dwarfs any interval and a bark is due straight away.
    T.Eq(ns.Barker.IsDue(nil, 1788441671, 180), true, "never sent, due immediately")
    T.Eq(ns.Barker.IsDue(0, 1788441671, 600), true, "a zeroed timestamp is also due")
end)

T.Case("IsAvailabilityQuestion recognises a bare linked gem plus a trailing ?", function()
    -- The exact Sheraton case: a shift-clicked link with no typed words at
    -- all. The link followed by "?" IS the question; requiring a phrase from
    -- the list would miss every customer who just links and asks.
    local msg = RUBY_LINK .. "?"
    T.Eq(ns.Util.IsAvailabilityQuestion(msg, ns.Util.Normalize(msg), ASK), true,
        "bare link plus trailing ?")
end)

T.Case("IsAvailabilityQuestion does not fire on a link with no question mark", function()
    T.Eq(ns.Util.IsAvailabilityQuestion(RUBY_LINK, ns.Util.Normalize(RUBY_LINK), ASK),
        false, "link alone, mentioned in passing")
end)

T.Case("IsAvailabilityQuestion requires the ? to be at the end for a bare link", function()
    -- A link with a question elsewhere in the sentence is a different kind of
    -- question ("why is [X] so expensive? because...") not an availability ask.
    local msg = RUBY_LINK .. " is this a good deal? not sure"
    T.Eq(ns.Util.IsAvailabilityQuestion(msg, ns.Util.Normalize(msg), ASK), false,
        "question mark not trailing the message")
end)


T.Case("PrefixNearMiss finds ambiguous unrelated gems sharing a prefix", function()
    -- The Gingersfury case: "jagged" alone matches two UNRELATED gems, not
    -- tiers of one family, so this must stay distinct from NearMiss.
    local book = {
        [1] = { itemID = 1, name = "Jagged Seaspray Emerald",
                classID = 3, bindType = 0, match = true, aliases = {} },
        [2] = { itemID = 2, name = "Jagged Deep Peridot",
                classID = 3, bindType = 0, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    local text = "looking for jagged and do you happen to be an enchanter as well?"
    local word, ids = ns.Matcher.PrefixNearMiss(ns.Util.Normalize(text), index)
    T.Eq(word, "jagged", "prefix found")
    T.Eq(#ids, 2, "both unrelated gems returned, not merged as one family")
end)

T.Case("PrefixNearMiss requires the exact token, not a substring", function()
    local book = {
        [1] = { itemID = 1, name = "Jagged Seaspray Emerald",
                classID = 3, bindType = 0, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    T.Eq(ns.Matcher.PrefixNearMiss(ns.Util.Normalize("ragged old boots"), index),
        nil, "does not fire on an unrelated word containing similar letters")
end)

T.Case("PrefixNearMiss stays silent below the length gate", function()
    -- "bold" is 4 letters and appears constantly in unrelated chat
    -- ("bold move", "boldly"). Must not surface even as a local-only note.
    local book = {
        [1] = { itemID = 1, name = "Bold Living Ruby",
                classID = 3, bindType = 0, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    T.Eq(ns.Matcher.PrefixNearMiss(ns.Util.Normalize("that was a bold move"), index),
        nil, "short common prefix excluded")
end)

T.Case("PrefixNearMiss returns nil when nothing shares that prefix", function()
    local index = ns.Matcher.BuildIndex(fixtureBook())
    T.Eq(ns.Matcher.PrefixNearMiss(ns.Util.Normalize("lfg deadmines"), index),
        nil, "no match")
end)

T.Case("Orders.Open matches regardless of case", function()
    local saved = ns.db.orders
    ns.db.orders = { { id = 1, player = "wokenough", status = "grouped", items = {} } }
    T.Eq(ns.Orders.Open("Wokenough") ~= nil, true,
        "manually typed lowercase name still found via live proper-case lookup")
    T.Eq(ns.Orders.Open("WOKENOUGH") ~= nil, true, "all caps also matches")
    ns.db.orders = saved
end)

T.Case("Orders.Open still respects done and cancelled regardless of case", function()
    local saved = ns.db.orders
    ns.db.orders = { { id = 1, player = "Wokenough", status = "done", items = {} } }
    T.Eq(ns.Orders.Open("wokenough"), nil, "closed order not returned")
    ns.db.orders = saved
end)

T.Case("Classifier scores LF gem crafter as a buyer signal", function()
    -- The exact Wokenough message: matched the gem, but scored zero buyer
    -- signal and got blocked by requireBuyerSignal purely on wording.
    local text = "LF " .. RUBY_LINK .. " crafter"
    local index = ns.Matcher.BuildIndex(fixtureBook())
    local norm = ns.Util.Normalize(text)
    local r = ns.Classifier.Evaluate({
        norm = norm, raw = text,
        matched = ns.Matcher.Match(text, norm, index),
        linkCount = 1,
        filter = ns.DeepCopy(ns.Defaults.settings.filter),
    })
    T.Eq(r.verdict, "invite", "verdict")
    T.Eq(r.buyerHits.crafter, 2, "crafter scored as a buyer signal")
end)

T.Case("StripLinkText removes a link's display text entirely", function()
    local msg = "LF JC " .. RUBY_LINK
    T.Eq(ns.Util.StripLinkText(msg), "LF JC  ", "link and its name both gone")
end)

T.Case("A linked gem's own name does not loose-match an unrelated gem", function()
    -- The exact Ruylopez bug: linking Purified Shadow Pearl normalizes to
    -- "...purified shadow pearl", and "purified"+"pearl" alone used to loose
    -- match the completely unrelated Purified Jaggal Pearl, silently
    -- attaching a gem nobody asked for to the order.
    local shadowPearlLink =
        "|cff0070dd|Hitem:32836::::::::70:::::1:3524:::::|h[Purified Shadow Pearl]|h|r"
    local book = {
        [32836] = { itemID = 32836, name = "Purified Shadow Pearl",
                    classID = 3, bindType = 0, match = true, aliases = {} },
        [32833] = { itemID = 32833, name = "Purified Jaggal Pearl",
                    classID = 3, bindType = 0, match = true, aliases = {} },
    }
    local index = ns.Matcher.BuildIndex(book)
    local text = "LF JC " .. shadowPearlLink
    local hits = ns.Matcher.Match(text, ns.Util.Normalize(text), index)
    T.Eq(#hits, 1, "only the linked gem matches")
    T.Eq(hits[1].itemID, 32836, "Purified Shadow Pearl, not the unrelated Jaggal Pearl")
end)

T.Case("Loose matching still works for the customer's own typed words", function()
    -- The fix must not break ordinary shorthand outside of link text.
    T.Eq(matchIDs("wtb bold ruby")[24033], "loose", "still matches")
end)

T.Case("Orders.RemoveItem discards one line without touching the rest", function()
    local o = { items = {
        { itemID = 1, qty = 2, cut = true },
        { itemID = 2, qty = 1 },
        { itemID = 3, qty = 4, cut = true },
    }, needsSplit = false }
    T.Eq(ns.Orders.RemoveItem(o, 2), true, "removed")
    T.Eq(#o.items, 2, "one line gone")
    T.Eq(o.items[1].itemID, 1, "first item untouched")
    T.Eq(o.items[2].itemID, 3, "third item untouched")
end)

T.Case("Orders.RemoveItem returns false for an item not on the order", function()
    local o = { items = { { itemID = 1, qty = 1 } }, needsSplit = false }
    T.Eq(ns.Orders.RemoveItem(o, 99), false, "nothing to remove")
    T.Eq(#o.items, 1, "unchanged")
end)

T.Case("Orders.RemoveItem clears needsSplit once no ambiguous line remains", function()
    local o = { items = {
        { itemID = 1, qty = 1, qtySource = "ambiguous" },
        { itemID = 2, qty = 1, qtySource = "ambiguous" },
    }, needsSplit = true }
    ns.Orders.RemoveItem(o, 1)
    T.Eq(o.needsSplit, true, "the other ambiguous line still needs resolving")
    ns.Orders.RemoveItem(o, 2)
    T.Eq(o.needsSplit, false, "cleared once nothing ambiguous is left")
end)

T.Case("Orders.FindItemByName matches case-insensitively by substring", function()
    local savedBook = ns.db.book
    ns.db.book = {
        [32833] = { itemID = 32833, name = "Purified Jaggal Pearl" },
        [32836] = { itemID = 32836, name = "Purified Shadow Pearl" },
    }
    local o = { items = { { itemID = 32833 }, { itemID = 32836 } } }
    T.Eq(ns.Orders.FindItemByName(o, "jaggal"), 32833, "matches by substring")
    T.Eq(ns.Orders.FindItemByName(o, "SHADOW"), 32836, "case insensitive")
    T.Eq(ns.Orders.FindItemByName(o, "topaz"), nil, "no match returns nil")
    ns.db.book = savedBook
end)
