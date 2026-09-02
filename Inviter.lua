local addonName, ns = ...

ns.Inviter = ns.Inviter or {}
local Inviter = ns.Inviter

Inviter.whisperCount = 0

local WHISPER_WARN_AT = 60
local WHISPER_DELAY = 1.5

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

function Inviter.Invite(name, matched)
    local short = name:gsub("%-.*", "")
    local settings = ns.db.settings.invite
    local now = GetServerTime and GetServerTime() or time()

    DoInvite(short)

    local state = ns.Players.Get(ns.db, short)
    state.lastInviteAt = now

    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.MAP_PING) end

    local gemLink
    if matched and matched[1] then
        local entry = ns.db.book[matched[1].itemID]
        gemLink = entry and (entry.link or entry.name)
    end
    ns.Print(string.format("invited %s for %s", short, gemLink or "a cut"))

    if not settings.whisper.enabled then return end

    local last = state.lastWhisperAt or 0
    if (now - last) < settings.whisper.cooldownSec then return end
    state.lastWhisperAt = now

    -- A profession request ("LF JC") names nothing, so asking them what they
    -- need beats claiming we invited them "for your cut".
    local gemless = not gemLink
    local template = gemless and settings.whisper.templateNoGem
        or settings.whisper.template
    if gemless then state.awaitingGem = now end

    C_Timer.After(WHISPER_DELAY, function()
        Inviter.Say(short, template, { gem = gemLink })
    end)
end

-- Sends a whisper immediately, subject to the short conversational cooldown.
-- Whispers are not protected the way public channel messages are, so this
-- works from an event handler.
function Inviter.Say(name, template, vars)
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
