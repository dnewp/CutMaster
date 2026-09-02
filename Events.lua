local addonName, ns = ...

ns.Events = ns.Events or {}
local Events = ns.Events

-- Only the recipe ITEM ("Design: Bold Living Ruby") is a seller tell. Craft
-- spell links are not: real trade chat shows buyers using them too, e.g.
-- "LF enchanter for [Enchanting: Enchant Boots - Boar's Speed]".
local function HasDesignLink(raw)
    if not raw then return false end
    return raw:find("Design:", 1, true) ~= nil
end

function Events.RebuildIndex()
    Events.index = ns.Matcher.BuildIndex(ns.db.book)
    return Events.index
end

function Events.OnTradeMessage(text, author, opts)
    opts = opts or {}
    if not ns.db then return end
    if not Events.index then Events.RebuildIndex() end

    local short = (author or ""):gsub("%-.*", "")
    if short == "" then return end

    -- Our own barks are not input. Bail before touching any state.
    if not opts.dryRun and short == UnitName("player") then return end

    local norm = ns.Util.Normalize(text)
    local now = GetServerTime and GetServerTime() or time()
    local matched = ns.Matcher.Match(text, norm, Events.index)

    -- A dry run must never touch persistent player state, or repeatedly
    -- testing similar strings auto-flags the fake author as a competitor.
    local state = opts.dryRun and {} or ns.Players.Get(ns.db, short)

    -- Repeat detection ONLY applies to messages that mention a gem. Trade chat
    -- is full of raid recruiters and guild spam reposting on timers; flagging
    -- them as competing jewelcrafters silently blacklists future customers.
    local isRepeat = false
    if #matched > 0 then
        _, isRepeat = ns.Players.Observe(
            state, norm, now, ns.db.settings.filter.repeatWindowSec)
    end

    local blocked
    if not opts.dryRun then
        if UnitInParty(short) or UnitInRaid(short) then
            blocked = "already grouped"
        else
            blocked = ns.Inviter.BlockReason(
                state, now, GetNumGroupMembers() or 0, ns.db.settings.invite)
        end
    end

    local result = ns.Classifier.Evaluate({
        norm = norm,
        raw = text,
        matched = matched,
        linkCount = #ns.Util.ExtractItemIDs(text),
        hasDesignLink = HasDesignLink(text),
        isRepeat = isRepeat,
        playerState = state,
        blocked = blocked,
        filter = ns.db.settings.filter,
    })

    -- Capture mode records everything, matched or not, so false negatives are
    -- visible. Without it a customer the matcher never saw leaves no trace.
    if ns.db.settings.captureAll and not opts.dryRun then
        ns.Log.Capture(short, text, result, now)
    end

    if result.reason ~= "no gem match" and not opts.dryRun then
        ns.Log.Add(short, text, matched, result, now)
        if ns.db.settings.debug then
            ns.Print(ns.Log.Describe(ns.db.log[1]))
            ns.Print(ns.Log.DescribeHits(ns.db.log[1]))
        end
    end

    if result.verdict == "invite" and not result.blocked and not opts.dryRun then
        ns.Inviter.Invite(short, matched)
    end

    return result
end
