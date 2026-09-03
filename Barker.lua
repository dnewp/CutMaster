local addonName, ns = ...

ns.Barker = ns.Barker or {}
local Barker = ns.Barker

local MAX_LEN = 255

-- The reminder counts from the last bark that actually went out, not from
-- when barking was switched on, so sending one by hand resets the clock.
-- That means polling rather than a ticker set to the full interval.
local POLL_INTERVAL = 5

local function Now()
    return GetServerTime and GetServerTime() or time()
end

-- Pure.
function Barker.IsDue(lastSentAt, now, intervalSec)
    return (now - (lastSentAt or 0)) >= intervalSec
end

function Barker.SecondsUntilDue()
    local s = ns.db.settings.bark
    local left = s.intervalSec - (Now() - (s.lastSentAt or 0))
    return left > 0 and math.floor(left) or 0
end

-- Pure. Fills the template with as many gem links as fit under maxLen and
-- reports where the rotation cursor should land next.
function Barker.Fit(entries, cursor, template, maxLen, perBark)
    if not entries or #entries == 0 then return nil end
    if not template or not template:find("{gems}", 1, true) then return nil end

    maxLen = maxLen or MAX_LEN
    cursor = cursor or 1
    if cursor < 1 or cursor > #entries then cursor = 1 end

    local shell = template:gsub("{gems}", "")
    local budget = maxLen - #shell

    local picked, used, length = {}, 0, 0
    local idx = cursor

    for _ = 1, math.min(perBark, #entries) do
        local link = entries[idx].link
        local addition = #link + (used > 0 and 1 or 0)
        if length + addition > budget then break end
        picked[#picked + 1] = link
        length = length + addition
        used = used + 1
        idx = idx + 1
        if idx > #entries then idx = 1 end
    end

    if used == 0 then return nil end

    local msg = template:gsub("{gems}", table.concat(picked, " "), 1)
    return msg, idx, used
end

-- Books scanned before bindType was captured have no idea what is soulbound.
-- Rather than depend on the user rescanning, fill it in from the item cache on
-- demand. Jewelcrafter-only epics (Falling Star, Kailee's Rose, Facet of
-- Eternity and friends) are quality 4 gems, so a quality filter alone happily
-- advertises gems that can never reach a customer.
local function BindTypeOf(itemID, e)
    if e.bindType ~= nil then return e.bindType end
    local bind = select(14, GetItemInfo(itemID))
    if bind ~= nil then e.bindType = bind end
    return bind
end

function Barker.AdvertisedEntries()
    local list = {}
    for itemID, e in pairs(ns.db.book) do
        if e.advertise and not e.stale and e.link and BindTypeOf(itemID, e) ~= 1 then
            list[#list + 1] = {
                itemID = itemID, link = e.link,
                header = e.header or "", name = e.name or "",
            }
        end
    end
    table.sort(list, function(a, b)
        if a.header ~= b.header then return a.header < b.header end
        return a.name < b.name
    end)
    return list
end

-- Locale safe: matches both "Trade" and "Trade - City".
function Barker.TradeChannel()
    local channels = { GetChannelList() }
    for i = 1, #channels, 3 do
        local id, name = channels[i], channels[i + 1]
        if type(name) == "string" and name:find("Trade", 1, true) then
            return id
        end
    end
    return nil
end

function Barker.BlockReason()
    local s = ns.db.settings.bark
    if not ns.Enabled() then return "CutMaster is disabled" end
    if not s.enabled then return "disabled" end
    if s.pauseCombat and (InCombatLockdown() or UnitAffectingCombat("player")) then
        return "in combat"
    end
    if s.pauseInstance and IsInInstance() then return "in an instance" end
    if s.onlyInCity and not Barker.TradeChannel() then return "no trade channel" end
    return nil
end

function Barker.Tick(force)
    local s = ns.db.settings.bark

    -- Even a forced bark respects the master switch.
    if not ns.Enabled() then return false, "CutMaster is disabled" end

    if not force then
        local blocked = Barker.BlockReason()
        if blocked then return false, blocked end
    end

    local channel = Barker.TradeChannel()
    if not channel then return false, "no trade channel" end

    local entries = Barker.AdvertisedEntries()
    local msg, nextCursor, used = Barker.Fit(entries, s.cursor, s.template, MAX_LEN, s.perBark)
    if not msg then return false, "nothing to advertise" end

    SendChatMessage(msg, "CHANNEL", nil, channel)

    -- Only advance on a message that actually went out, so a skipped tick
    -- never silently drops gems out of the rotation.
    s.cursor = nextCursor
    s.lastSentAt = Now()
    Barker.pending = false
    Barker.lastSkipReason = nil
    return true, used
end

-- Bulk advertise selection. "rare" is the useful default: TBC cut gems are
-- quality 3 or 4, while vanilla junk like Lustrous Azure Moonstone is 2, so
-- this drops the cheap cuts nobody is shopping for.
function Barker.ApplyAdvertiseFilter(book, mode)
    local n = 0
    for _, e in pairs(book) do
        if not e.stale then
            if mode == "all" then
                e.advertise = true
            elseif mode == "none" then
                e.advertise = false
            elseif mode == "rare" then
                e.advertise = (e.classID == 3 and (e.quality or 0) >= 3)
            elseif mode == "epic" then
                e.advertise = (e.classID == 3 and (e.quality or 0) >= 4)
            end
            -- Bind on pickup can never reach a customer, so it is never worth
            -- advertising. This overrides even "all" on purpose.
            if e.bindType == 1 then e.advertise = false end
            if e.advertise then n = n + 1 end
        end
    end
    return n
end

function Barker.SetAdvertiseMatching(book, needle, on)
    local n = 0
    needle = ns.Util.Normalize(needle)
    for _, e in pairs(book) do
        if not e.stale and e.name and ns.Util.Normalize(e.name):find(needle, 1, true) then
            e.advertise = on
            n = n + 1
        end
    end
    return n
end

function Barker.Stop()
    if Barker.ticker then
        Barker.ticker:Cancel()
        Barker.ticker = nil
    end
end

-- SendChatMessage to a public channel is PROTECTED on this client: it only
-- works when called during a hardware event (a keypress or a mouse click).
-- A C_Timer callback is not one, so the timer cannot send the bark itself.
-- Confirmed by ADDON_ACTION_BLOCKED with SendChatMessage on the stack.
--
-- So the timer only ARMS a bark and tells the user. Sending happens from the
-- key binding, the UI button, or /cm send, all of which are hardware events.
function Barker.Alert()
    local blocked = Barker.BlockReason()
    if blocked then return false, blocked end

    Barker.pending = true
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION) end
    ns.Print("|cffffcc00bark ready|r. Press your CutMaster bark key, "
        .. "or use /cm send.")
    return true
end

-- Runs every few seconds and only acts once the interval has elapsed since
-- the last bark actually sent.
function Barker.Poll()
    local s = ns.db.settings.bark
    if not s.enabled or not ns.Enabled() then return end
    if Barker.pending then return end
    if not Barker.IsDue(s.lastSentAt, Now(), s.intervalSec) then return end

    local ok, reason = Barker.Alert()
    if not ok then
        -- A skip is worth saying once, not every five seconds. Repeating it
        -- until the reason changes would be its own kind of spam.
        if reason ~= Barker.lastSkipReason then
            ns.Print("bark due but skipped: " .. tostring(reason))
            Barker.lastSkipReason = reason
        end
    else
        Barker.lastSkipReason = nil
    end
end

function Barker.Start(immediate)
    Barker.Stop()
    if immediate then
        local ok, info = Barker.Tick()
        if not ok then ns.Print("first bark skipped: " .. tostring(info)) end
    end
    Barker.ticker = C_Timer.NewTicker(POLL_INTERVAL, Barker.Poll)
end

function Barker.Preview()
    local entries = Barker.AdvertisedEntries()
    local s = ns.db.settings.bark
    return Barker.Fit(entries, s.cursor, s.template, MAX_LEN, s.perBark)
end
