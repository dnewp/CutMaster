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

function Players.Get(db, name)
    db.players = db.players or {}
    db.players[name] = db.players[name] or {}
    return db.players[name]
end
