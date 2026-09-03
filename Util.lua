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
function Util.IsAvailabilityQuestion(raw, norm, phrases)
    if not raw or not raw:find("?", 1, true) then return false end

    -- A shift-clicked gem link with a trailing "?" and no typed words at all
    -- ("[Shifting Shadowsong Amethyst]?") is as direct a question as it gets.
    -- Requiring a phrase from the list would miss it entirely, which is
    -- exactly what happened: the link itself IS the question.
    if raw:find("|Hitem:", 1, true) and raw:match("%?%s*$") then
        return true
    end

    for _, p in ipairs(phrases or {}) do
        if Util.HasPhrase(norm, p) then return true end
    end
    return false
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
