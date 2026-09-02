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

    C_Timer.After(WHISPER_DELAY, function()
        local text = settings.whisper.template
            :gsub("{gem}", gemLink or "your cut")
            :gsub("{player}", short)
        SendChatMessage(text, "WHISPER", nil, short)
        Inviter.whisperCount = Inviter.whisperCount + 1
        if Inviter.whisperCount == WHISPER_WARN_AT then
            ns.Print("|cffff9900" .. WHISPER_WARN_AT ..
                " whispers sent this session. Watch the game whisper throttle.|r")
        end
    end)
end
