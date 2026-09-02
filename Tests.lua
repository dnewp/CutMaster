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
