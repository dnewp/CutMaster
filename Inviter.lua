local addonName, ns = ...

ns.Inviter = ns.Inviter or {}
local Inviter = ns.Inviter

Inviter.whisperCount = 0

local WHISPER_WARN_AT = 60
local WHISPER_DELAY = 1.5

-- Keeps a whisper inside the 255 character cap once links are expanded.
local MAX_GEMS_PER_WHISPER = 3

-- Pure. Reasons the invite cannot happen regardless of message content.
function Inviter.BlockReason(playerState, now, groupSize, settings)
    if not settings.enabled then return "invites disabled" end
    if groupSize >= settings.maxParty then return "group full" end
    if playerState and playerState.lastInviteAt
        and (now - playerState.lastInviteAt) < settings.playerCooldownSec then
        return "cooldown"
    end
    return nil
end

local function DoInvite(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    elseif InviteUnit then
        InviteUnit(name)
    else
        ns.Print("|cffff4444no invite API available on this client.|r")
    end
end

function Inviter.Invite(name, matched, ctx)
    if not ns.Enabled() then return end
    local short = name:gsub("%-.*", "")
    local settings = ns.db.settings.invite
    local now = GetServerTime and GetServerTime() or time()

    DoInvite(short)

    local state = ns.Players.Get(ns.db, short)
    state.lastInviteAt = now

    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.MAP_PING) end

    -- Acknowledge EVERY cut they asked for, not just the first. Someone
    -- requesting two gems and being told about one reads as half an answer.
    local have = {}
    for i = 1, math.min(#(matched or {}), MAX_GEMS_PER_WHISPER) do
        local entry = ns.db.book[matched[i].itemID]
        if entry then have[#have + 1] = entry.link or entry.name end
    end
    local haveText = #have > 0 and table.concat(have, " ") or nil

    local lack = {}
    for i = 1, math.min(#((ctx and ctx.cannotDo) or {}), MAX_GEMS_PER_WHISPER) do
        lack[i] = ctx.cannotDo[i]
    end

    ns.Print(string.format("invited %s for %s%s", short, haveText or "a cut",
        #lack > 0 and ("  |cffff9900cannot do: " .. table.concat(lack, " ") .. "|r") or ""))

    if not settings.whisper.enabled then return end

    local last = state.lastWhisperAt or 0
    if (now - last) < settings.whisper.cooldownSec then return end
    state.lastWhisperAt = now

    local template, vars
    if not haveText then
        -- A profession request ("LF JC") names nothing, so asking them what
        -- they need beats claiming we invited them "for your cut".
        template, vars = settings.whisper.templateNoGem, {}
        state.awaitingGem = now
    elseif #lack > 0 then
        -- They named some we have and some we do not. Say which is which in
        -- the same breath rather than letting them find out later.
        template = settings.whisper.partialTemplate
        vars = { have = haveText, lack = table.concat(lack, " ") }
    else
        template, vars = settings.whisper.template, { gem = haveText }
    end

    C_Timer.After(WHISPER_DELAY, function()
        Inviter.Say(short, template, vars)
    end)
end

-- Sends a whisper immediately, subject to the short conversational cooldown.
-- Whispers are not protected the way public channel messages are, so this
-- works from an event handler.
function Inviter.Say(name, template, vars)
    if not ns.Enabled() then return false end
    if not template or template == "" then return false end
    local now = GetServerTime and GetServerTime() or time()
    local state = ns.Players.Get(ns.db, name)
    local last = state.lastReplyAt or 0
    if (now - last) < (ns.db.settings.invite.whisper.replyCooldownSec or 10) then
        return false
    end
    state.lastReplyAt = now

    local text = template
    for k, v in pairs(vars or {}) do
        text = text:gsub("{" .. k .. "}", v)
    end
    text = text:gsub("{player}", name)
    text = text:gsub("{gem}", "your cut"):gsub("{gems}", "")

    SendChatMessage(text, "WHISPER", nil, name)
    Inviter.whisperCount = Inviter.whisperCount + 1
    if Inviter.whisperCount == WHISPER_WARN_AT then
        ns.Print("|cffff9900" .. WHISPER_WARN_AT ..
            " whispers sent this session. Watch the game whisper throttle.|r")
    end
    return true
end
