local addonName, ns = ...

ns.Events = ns.Events or {}
local Events = ns.Events

-- How far back to look when stitching together a fragmented request.
local CONTEXT_WINDOW = 90

-- A message this short naming a gem family is a fragment, not conversation.
local FRAGMENT_WORDS = 5

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

    -- Master switch. /cm try still works so the classifier can be tested
    -- while the addon is otherwise silent.
    if not opts.dryRun and not ns.Enabled() then return end

    local isWhisper = (source == "whisper")
    local isParty = (source == "party")
    -- Directed at us rather than broadcast to a channel.
    local isDirect = isWhisper or isParty

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
    if #matched > 0 and not isDirect then
        _, isRepeat = ns.Players.Observe(
            state, norm, now, ns.db.settings.filter.repeatWindowSec)
    end

    -- Fragmented requests. Someone typing "Shifting Shadowsong?" then
    -- "Amethyst" names one gem across two messages, and matching each line on
    -- its own finds nothing. Retry against the last minute of what they said.
    -- Only for whispers and party chat, where the messages are a conversation
    -- with us rather than unrelated lines in a busy channel.
    local usedContext = false
    if isDirect and #matched == 0 then
        local combined = ns.Players.RecentText(state, now, CONTEXT_WINDOW)
        if combined ~= "" then
            combined = combined .. " " .. text
            local cnorm = ns.Util.Normalize(combined)
            local cm = ns.Matcher.Match(combined, cnorm, Events.index)
            if #cm > 0 then
                matched = cm
                norm = cnorm
                usedContext = true
            end
        end
    end
    -- A trade chat post that named a real gem is remembered too, not just
    -- whispers. Wokenough posted "LF [Delicate Living Ruby] crafter" in
    -- Trade, then whispered nothing but "delicate" and "all 9" -- never the
    -- base word "living"/"ruby" needed to resolve the fragment. The gem name
    -- was said in public and then thrown away the moment the conversation
    -- moved to whisper. Gated on an actual match so raid ads and unrelated
    -- chat do not fill the buffer.
    if not opts.dryRun and (isDirect or #matched > 0) then
        ns.Players.PushRecent(state, text, now)
    end

    local filter = ns.db.settings.filter
    if isDirect then
        filter = ns.DeepCopy(filter)
        filter.requireBuyerSignal = false
    end

    -- Did they name a specific gem that is not in our book? Either a linked
    -- gem item we cannot craft, or a plain-text cut from a gem family we know.
    local namedUnknownGem = false
    if #matched == 0 then
        for _, id in ipairs(ns.Util.ExtractItemIDs(text)) do
            if not ns.db.book[id] then
                local classID = select(12, GetItemInfo(id))
                if classID == 3 then namedUnknownGem = true break end
            end
        end
        if not namedUnknownGem and ns.Matcher.NearMiss(norm, Events.index) then
            namedUnknownGem = true
        end
    end

    -- They may have linked several gems and we only know some of them.
    -- Booking the ones we can do and saying nothing about the rest leaves the
    -- customer asking "got both?", which is exactly what happened.
    local canDo, cannotDo = {}, {}
    do
        local matchedSet = {}
        for _, h in ipairs(matched) do matchedSet[h.itemID] = true end
        for _, l in ipairs(ns.Util.ExtractItemLinks(text)) do
            if matchedSet[l.id] then
                canDo[#canDo + 1] = l.link
            elseif not ns.db.book[l.id] and select(12, GetItemInfo(l.id)) == 3 then
                cannotDo[#cannotDo + 1] = l.link
            end
        end
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
        namedUnknownGem = namedUnknownGem,
        isRepeat = isRepeat,
        isDirect = isDirect,
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

    if isParty and not opts.dryRun and #matched > 0 then
        -- They joined and said what they want. Book it, do not whisper: they
        -- are standing right there and can read the party window.
        state.awaitingGem = nil
    end

    -- Conversational whisper handling. We ask gemless requesters what they
    -- need, then confirm whatever they answer with, and only book an order
    -- once we know it is a cut we can actually deliver.
    -- An invite sends its own whisper covering both what we can and cannot
    -- do, so these replies are only for when no invite is going out.
    local willInvite = result.verdict == "invite" and not result.blocked

    if isWhisper and not opts.dryRun and result.verdict ~= "vetoed" then
        local w = ns.db.settings.invite.whisper

        if #matched > 0 then
            local e = ns.db.book[matched[1].itemID]
            local link = e and (e.link or e.name)

            if #cannotDo > 0 and not willInvite and w.enabled and w.autoReply then
                -- They asked about several and we only have some. Answering
                -- which is directly responsive, not an unsolicited pitch.
                local have = #canDo > 0 and table.concat(canDo, " ") or (link or "that")
                ns.Inviter.Say(short, w.partialTemplate, {
                    have = have,
                    lack = table.concat(cannotDo, " "),
                })
                ns.Print(string.format(
                    "|cffffcc00%s asked for %d cuts, you have %d.|r Cannot do: %s",
                    short, #canDo + #cannotDo, #canDo, table.concat(cannotDo, " ")))
            elseif state.awaitingGem and not willInvite and w.enabled and w.autoReply then
                -- Only confirm when they are answering our question. A fresh
                -- request already gets the invite whisper, which says the same
                -- thing, and two whispers in a row reads like spam.
                ns.Inviter.Say(short, w.confirmTemplate, { gem = link })
            end
            state.awaitingGem = nil
            -- The order itself is booked by the shared path below.

        else
            local asked = ns.Util.IsAvailabilityQuestion(
                text, norm, ns.db.settings.filter.askPhrases)
            local mayReply = w.enabled and w.autoReply
                and (w.autoSuggest or (asked and w.answerQuestions))

            local family, ids, exactFamily = ns.Matcher.NearMiss(norm, Events.index)
            local links = {}
            for _, id in ipairs(ids or {}) do
                local b = ns.db.book[id]
                if b and (b.link or b.name) then links[#links + 1] = b.link or b.name end
            end

            -- Half a gem name is a question we can answer usefully: link our
            -- cuts of that family and ask which one. That is clarification,
            -- not a pitch, so it does not need an explicit question phrase.
            -- Kept to short messages so it cannot fire on someone chatting.
            local fragment = family and not exactFamily and #links > 0
                and (asked or #ns.Util.Tokenize(norm) <= FRAGMENT_WORDS)

            if fragment and w.enabled and w.autoReply then
                local show = {}
                for i = 1, math.min(3, #links) do show[i] = links[i] end
                ns.Inviter.Say(short, w.askWhichTemplate,
                    { gems = table.concat(show, " ") })
                ns.Print(string.format(
                    "|cffffcc00%s typed a partial gem name.|r Asked which of: %s",
                    short, table.concat(show, " ")))
                result.reason = "asked which cut"
                ns.Log.Add(short, text, matched, result, now)
                return result
            end

            if #links > 0 or (asked and namedUnknownGem) then
                if #links > 0 then
                    -- Printed for the user only. What we CAN cut is useful for
                    -- them to see; pushing it at the customer is not.
                    ns.Print(string.format(
                        "|cffffcc00%s asked about a cut you do not know.|r You can cut: %s",
                        short, table.concat(links, " ")))
                else
                    ns.Print(string.format(
                        "|cffffcc00%s asked for a cut you do not have.|r", short))
                end
                result.reason = "unknown cut"
                ns.Log.Add(short, text, matched, result, now)

                if mayReply then
                    if w.autoSuggest and #links > 0 then
                        -- Opt in only. Answering with a list of things they did
                        -- not ask about is a sales pitch, not an answer.
                        while #links > 3 do table.remove(links) end
                        ns.Inviter.Say(short, w.suggestTemplate,
                            { gems = table.concat(links, " ") })
                    else
                        ns.Inviter.Say(short, w.noneTemplate, {})
                    end
                end
            else
                -- Last resort: a bare cut prefix with none of its base words
                -- present ("looking for jagged..."). Genuinely ambiguous, e.g.
                -- Jagged Seaspray Emerald and Jagged Deep Peridot are unrelated
                -- gems that only share a tier adjective, so this is local only.
                -- Guessing which one to whisper about, in a message that is
                -- often asking about other things too, would be worse than
                -- staying quiet; the user can reply themselves once they see it.
                local prefixWord, prefixIDs = ns.Matcher.PrefixNearMiss(norm, Events.index)
                if prefixWord then
                    local pl = {}
                    for _, id in ipairs(prefixIDs) do
                        local b = ns.db.book[id]
                        if b and (b.link or b.name) then pl[#pl + 1] = b.link or b.name end
                    end
                    if #pl > 0 then
                        ns.Print(string.format(
                            "|cffffcc00%s mentioned \"%s\", could be:|r %s",
                            short, prefixWord, table.concat(pl, " ")))
                        result.reason = "ambiguous prefix"
                        ns.Log.Add(short, text, matched, result, now)
                    end
                end
            end
        end
    end

    if not opts.dryRun then
        local o = ns.db.settings.orders
        local wanted = (isWhisper and o.autoFromWhisper)
            or (isParty and o.autoFromParty)
            or (not isDirect and o.autoFromInvite)
        if wanted and result.verdict == "invite" and #matched > 0 then
            if usedContext then
                ns.Print(string.format(
                    "|cff888888(matched %s using their previous message)|r", short))
            end
            ns.Orders.Record(short, source, text, matched, now)
        end
        if isDirect and o.captureTranscript then
            ns.Orders.AddTranscript(short, "in", text, now)
        end
    end

    if willInvite and not opts.dryRun then
        ns.Inviter.Invite(short, matched, { cannotDo = cannotDo })
    end

    return result
end

function Events.OnTradeMessage(text, author, opts)
    return Events.Process(text, author, "trade", opts)
end

function Events.OnWhisper(text, author, opts)
    return Events.Process(text, author, "whisper", opts)
end

function Events.OnParty(text, author, opts)
    return Events.Process(text, author, "party", opts)
end
