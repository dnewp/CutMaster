local addonName, ns = ...

ns.Util = ns.Util or {}
local Util = ns.Util

function Util.Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function Util.StripEscapes(s)
    if not s then return "" end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    return s
end

function Util.Normalize(s)
    if not s then return "" end
    s = Util.StripEscapes(s)
    s = s:lower()
    s = s:gsub("[^%w%s]", " ")
    s = s:gsub("%s+", " ")
    return Util.Trim(s)
end

function Util.ExtractItemIDs(raw)
    local ids = {}
    if not raw then return ids end
    for id in raw:gmatch("|Hitem:(%d+)") do
        ids[#ids + 1] = tonumber(id)
    end
    return ids
end

-- Full item links, not just ids, so we can quote back exactly what someone
-- linked at us.
function Util.ExtractItemLinks(raw)
    local out = {}
    if not raw then return out end
    for link in raw:gmatch("|c%x+|Hitem:.-|h.-|h|r") do
        local id = tonumber(link:match("|Hitem:(%d+)"))
        if id then out[#out + 1] = { id = id, link = link } end
    end
    return out
end

-- "Do you have veiled pyrestone cut?" deserves an answer. "why are so many
-- cuts cheaper than [Crimson Spinel]" does not: it is someone thinking out
-- loud, and replying to it is talking over the user. A question mark plus an
-- availability phrase separates the two.
function Util.IsAvailabilityQuestion(raw, norm, phrases, isDirect)
    if not raw or not raw:find("?", 1, true) then return false end

    -- A shift-clicked gem link with a trailing "?" and no typed words at all
    -- ("[Shifting Shadowsong Amethyst]?") is as direct a question as it gets.
    -- Requiring a phrase from the list would miss it entirely, which is
    -- exactly what happened: the link itself IS the question.
    if raw:find("|Hitem:", 1, true) and raw:match("%?%s*$") then
        return true
    end

    -- In a WHISPER the phrase list stops earning its keep. It exists to tell a
    -- real request from someone musing in a busy channel, and nobody whispers
    -- a stranger to muse about gem prices. Every phrasing that went unanswered
    -- was a customer asking us plainly -- "Able to make X?", "X by chance?" --
    -- and each time the answer was to add one more phrase, which only ever
    -- covered that one wording. A question mark in a whisper is the question.
    --
    -- This does not open the floodgates: the caller still only replies when
    -- the message named a gem or family we recognise, so "hey whats up?" gets
    -- nothing because there is nothing to answer, not because of the wording.
    if isDirect then return true end

    for _, p in ipairs(phrases or {}) do
        if Util.HasPhrase(norm, p) then return true end
    end
    return false
end

-- Unlike StripEscapes, this removes the LINK'S DISPLAY TEXT too, not just the
-- colour codes around it. "LF JC [Purified Shadow Pearl]" normalizes to
-- "lf jc purified shadow pearl" for loose matching, and "purified"+"pearl"
-- from that link's own name then falsely matched an unrelated known gem,
-- Purified Jaggal Pearl, that the customer never mentioned. Loose matching
-- must only ever see the customer's own typed words.
function Util.StripLinkText(raw)
    if not raw then return "" end
    return (raw:gsub("|c%x%x%x%x%x%x%x%x|H.-|h%[.-%]|h|r", " "))
end

function Util.HasPhrase(norm, phrase)
    if not norm or not phrase or phrase == "" then return false end
    return (" " .. norm .. " "):find(" " .. phrase .. " ", 1, true) ~= nil
end

function Util.EscapePattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

function Util.Tokenize(norm)
    local t = {}
    if not norm then return t end
    for w in norm:gmatch("%S+") do
        t[#t + 1] = w
    end
    return t
end
