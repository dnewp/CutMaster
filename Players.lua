local addonName, ns = ...

ns.Players = ns.Players or {}
local Players = ns.Players

-- Sellers repost the same advertisement on a timer, usually varying only the
-- price. Ignoring digits is what lets "5g" and "7g" count as the same message.
function Players.Similar(a, b)
    if not a or not b then return false end
    local ca = a:gsub("%d+", "")
    local cb = b:gsub("%d+", "")
    return ca == cb
end

function Players.Observe(state, norm, now, windowSec)
    state = state or {}
    local isRepeat = false

    if state.lastMsg and state.lastMsgAt
        and (now - state.lastMsgAt) <= windowSec
        and Players.Similar(state.lastMsg, norm) then
        isRepeat = true
        state.repeats = (state.repeats or 0) + 1
        state.flaggedSeller = true
    end

    state.lastMsg = norm
    state.lastMsgAt = now
    return state, isRepeat
end

local RECENT_MAX = 4

-- People type a gem name across several messages: "Shifting Shadowsong?" then
-- "Amethyst". Matching each line in isolation misses all of them, so keep a
-- short rolling buffer of what someone just said.
function Players.PushRecent(state, text, now)
    state.recent = state.recent or {}
    state.recent[#state.recent + 1] = { text = text, at = now }
    while #state.recent > RECENT_MAX do table.remove(state.recent, 1) end
    return state
end

function Players.RecentText(state, now, windowSec)
    local parts = {}
    for _, r in ipairs(state.recent or {}) do
        if (now - (r.at or 0)) <= windowSec then parts[#parts + 1] = r.text end
    end
    return table.concat(parts, " ")
end

function Players.Get(db, name)
    db.players = db.players or {}
    db.players[name] = db.players[name] or {}
    return db.players[name]
end
