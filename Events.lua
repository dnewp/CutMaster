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

-- source is "trade" or "whisper". A whisper naming a gem is a request by
-- definition, since nobody whispers a stranger an advertisement, so the
-- buyer-signal requirement and the broadcast-shaped seller signals are
-- dropped for that channel.
function Events.Process(text, author, source, opts)
    opts = opts or {}
    if not ns.db then return end
    if not Events.index then Events.RebuildIndex() end

    local short = (author or ""):gsub("%-.*", "")
    if short == "" then return end

    local isWhisper = (source == "whisper")

    -- Our own barks are not input. Bail before touching any state.
    if not opts.dryRun and short == UnitName("player") then return end

    local norm = ns.Util.Normalize(text)
    local now = GetServerTime and GetServerTime() or time()
    local matched = ns.Matcher.Match(text, norm, Events.index)

    -- A dry run must never touch persistent player state, or repeatedly
    -- testing similar strings auto-flags the fake author as a competitor.
    local state = opts.dryRun and {} or ns.Players.Get(ns.db, short)

    -- Repeat detection ONLY applies to gem-mentioning trade chat. Trade chat is
    -- full of raid recruiters reposting on timers, and flagging them as
    -- competing jewelcrafters silently blacklists future customers. It is
    -- meaningless for whispers, where repetition is just a person talking.
    local isRepeat = false
    if #matched > 0 and not isWhisper then
        _, isRepeat = ns.Players.Observe(
            state, norm, now, ns.db.settings.filter.repeatWindowSec)
    end

    local filter = ns.db.settings.filter
    if isWhisper then
        filter = ns.DeepCopy(filter)
        filter.requireBuyerSignal = false
    end

    local blocked
    if not opts.dryRun then
        if isWhisper and not ns.db.settings.invite.fromWhisper then
            blocked = "whisper invites disabled"
        elseif UnitInParty(short) or UnitInRaid(short) then
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
        isWhisper = isWhisper,
        playerState = state,
        blocked = blocked,
        filter = filter,
    })
    result.source = source

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

    -- A whisper naming a gem family we know, but a cut we do not, is a live
    -- customer we would otherwise drop silently. Surface what we CAN cut.
    if isWhisper and #matched == 0 then
        local family, ids = ns.Matcher.NearMiss(norm, Events.index)
        if family and ids then
            local links = {}
            for _, id in ipairs(ids) do
                local e = ns.db.book[id]
                if e and (e.link or e.name) then links[#links + 1] = e.link or e.name end
            end
            if #links > 0 then
                ns.Print(string.format(
                    "|cffffcc00%s asked about a cut you do not know.|r You can cut: %s",
                    short, table.concat(links, " ")))
                result.reason = "unknown cut"
                if not opts.dryRun then
                    ns.Log.Add(short, text, matched, result, now)
                end
            end
        end
    end

    if result.verdict == "invite" and not result.blocked and not opts.dryRun then
        ns.Inviter.Invite(short, matched)
    end

    return result
end

function Events.OnTradeMessage(text, author, opts)
    return Events.Process(text, author, "trade", opts)
end

function Events.OnWhisper(text, author, opts)
    return Events.Process(text, author, "whisper", opts)
end
