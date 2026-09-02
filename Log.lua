local addonName, ns = ...

ns.Log = ns.Log or {}
local Log = ns.Log

local MAX_ENTRIES = 100

local VERDICT_COLOR = {
    invite = "|cff44ff44",
    vetoed = "|cffff4444",
    lowscore = "|cffffcc00",
}

function Log.Push(log, entry)
    table.insert(log, 1, entry)
    for i = #log, MAX_ENTRIES + 1, -1 do
        table.remove(log, i)
    end
    return log
end

local MAX_CAPTURE = 1500

-- Written to SavedVariables, so this is what gets read off disk after a
-- /reload. Store names as well as ids or the file is unreadable on its own.
function Log.Capture(player, msg, result, now)
    ns.db.capture = ns.db.capture or {}
    table.insert(ns.db.capture, 1, {
        at = now,
        player = player,
        msg = ns.Util.StripEscapes(msg),
        verdict = result.verdict,
        reason = result.reason,
        blocked = result.blocked,
        sellerScore = result.sellerScore,
        buyerScore = result.buyerScore,
        sellerHits = result.sellerHits,
        buyerHits = result.buyerHits,
    })
    for i = #ns.db.capture, MAX_CAPTURE + 1, -1 do
        table.remove(ns.db.capture, i)
    end
end

function Log.Add(player, msg, matched, result, now)
    local ids, names = {}, {}
    for _, h in ipairs(matched or {}) do
        ids[#ids + 1] = h.itemID
        local e = ns.db.book[h.itemID]
        names[#names + 1] = string.format("%s (%s)", e and e.name or h.itemID, h.tier)
    end

    return Log.Push(ns.db.log, {
        at = now,
        player = player,
        msg = ns.Util.StripEscapes(msg),
        matched = ids,
        matchedNames = names,
        verdict = result.verdict,
        reason = result.reason,
        blocked = result.blocked,
        sellerScore = result.sellerScore,
        sellerHits = result.sellerHits,
        buyerScore = result.buyerScore,
        buyerHits = result.buyerHits,
    })
end

function Log.Recent(n)
    local out = {}
    for i = 1, math.min(n, #ns.db.log) do
        out[i] = ns.db.log[i]
    end
    return out
end

function Log.Describe(entry)
    local color = VERDICT_COLOR[entry.verdict] or "|cffffffff"
    return string.format("%s%s|r %s (s%d/b%d, %s): %s",
        color, entry.verdict, entry.player or "?",
        entry.sellerScore or 0, entry.buyerScore or 0,
        entry.reason or "?", entry.msg or "")
end

-- Which named signals fired, for the "why did it decide that" case.
function Log.DescribeHits(entry)
    local parts = {}
    for k, v in pairs(entry.sellerHits or {}) do
        parts[#parts + 1] = string.format("|cffff8888-%s %d|r", k, v)
    end
    for k, v in pairs(entry.buyerHits or {}) do
        parts[#parts + 1] = string.format("|cff88ff88+%s %d|r", k, v)
    end
    if #parts == 0 then return "  (no signals)" end
    return "  " .. table.concat(parts, ", ")
end
