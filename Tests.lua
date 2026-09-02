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
