local addonName, ns = ...

ns.Matcher = ns.Matcher or {}
local Matcher = ns.Matcher
local Util = ns.Util

local TIER_RANK = { link = 4, name = 3, alias = 2, loose = 1 }
local LOOSE_WINDOW = 3

-- Filler words carry no identity. "Band of Natural Fire" splitting into
-- prefix "band" plus base "of" matched a raid ad reading "band of karabor".
local STOPWORDS = {
    ["of"] = true, ["the"] = true, ["a"] = true, ["an"] = true,
    ["and"] = true, ["to"] = true, ["for"] = true, ["in"] = true,
}

-- Loose shorthand is a gem-cut convention: people write "bold ruby" for Bold
-- Living Ruby. Nobody shortens a ring called "Band of Natural Fire", and
-- jewelry names are ordinary English phrases that collide with normal chat.
-- Class 3 is Gem.
local GEM_CLASS = 3

local WORDNUM = {
    one = 1, two = 2, three = 3, four = 4, five = 5,
    six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
}

function Matcher.BuildIndex(book)
    local index = { byID = {}, names = {}, aliases = {}, loose = {}, bases = {} }
    for itemID, e in pairs(book or {}) do
        -- Bind on pickup cannot be delivered, so never invite for one. Leaving
        -- it out of the index also lets NearMiss suggest the cuts we can
        -- actually hand over from the same gem family.
        if e.bindType == nil and GetItemInfo then
            local bind = select(14, GetItemInfo(itemID))
            if bind ~= nil then e.bindType = bind end
        end
        if e.match and not e.stale and e.bindType ~= 1 then
            index.byID[itemID] = true

            local norm = Util.Normalize(e.name)
            index.names[#index.names + 1] = { itemID = itemID, name = norm }

            -- "Bold Living Ruby" splits into prefix "bold" and bases
            -- {"living", "ruby"} so shorthand like "bold ruby" still resolves.
            local toks = Util.Tokenize(norm)
            if #toks >= 2 and e.classID == GEM_CLASS then
                local bases = {}
                for i = 2, #toks do
                    if not STOPWORDS[toks[i]] then bases[#bases + 1] = toks[i] end
                end
                if #bases > 0 then
                index.loose[#index.loose + 1] = {
                    itemID = itemID, prefix = toks[1], bases = bases,
                }

                -- "Bold Living Ruby" -> base "living ruby". Lets us recognise a
                -- request for a cut we do NOT know but whose gem family we do,
                -- e.g. someone asking for Shifting Shadowsong Amethyst when we
                -- can cut Balanced, Glowing and Infused Shadowsong Amethyst.
                local baseKey = table.concat(bases, " ")
                index.bases[baseKey] = index.bases[baseKey] or {}
                local list = index.bases[baseKey]
                list[#list + 1] = itemID
                end
            end

            for _, a in ipairs(e.aliases or {}) do
                index.aliases[#index.aliases + 1] = {
                    itemID = itemID, alias = Util.Normalize(a),
                }
            end
        end
    end
    return index
end

function Matcher.QtyHint(norm, phrase)
    if not norm or not phrase then return nil end
    local p = Util.EscapePattern(phrase)

    local n = norm:match("(%d+)%s*x?%s+" .. p)
    if n then return tonumber(n) end

    n = norm:match(p .. "%s*x%s*(%d+)")
    if n then return tonumber(n) end

    local w = norm:match("(%a+)%s+" .. p)
    if w and WORDNUM[w] then return WORDNUM[w] end

    return nil
end

-- Call only when Match found nothing. Returns the gem family named in the
-- message and the cuts of it we do know, or nil.
function Matcher.NearMiss(norm, index)
    local bestKey, bestLen
    for baseKey in pairs(index.bases) do
        if baseKey ~= "" and Util.HasPhrase(norm, baseKey) then
            if not bestLen or #baseKey > bestLen then
                bestKey, bestLen = baseKey, #baseKey
            end
        end
    end
    if not bestKey then return nil end
    return bestKey, index.bases[bestKey]
end

function Matcher.Match(raw, norm, index)
    local best = {}

    local function add(itemID, tier, qtyHint)
        local prev = best[itemID]
        if prev and TIER_RANK[prev.tier] >= TIER_RANK[tier] then
            if qtyHint and not prev.qtyHint then prev.qtyHint = qtyHint end
            return
        end
        best[itemID] = {
            itemID = itemID,
            tier = tier,
            qtyHint = qtyHint or (prev and prev.qtyHint),
        }
    end

    for _, id in ipairs(Util.ExtractItemIDs(raw)) do
        if index.byID[id] then add(id, "link", nil) end
    end

    for _, n in ipairs(index.names) do
        if Util.HasPhrase(norm, n.name) then
            add(n.itemID, "name", Matcher.QtyHint(norm, n.name))
        end
    end

    for _, a in ipairs(index.aliases) do
        if a.alias ~= "" and Util.HasPhrase(norm, a.alias) then
            add(a.itemID, "alias", Matcher.QtyHint(norm, a.alias))
        end
    end

    local toks = Util.Tokenize(norm)
    local pos = {}
    for i, w in ipairs(toks) do
        pos[w] = pos[w] or {}
        pos[w][#pos[w] + 1] = i
    end

    for _, l in ipairs(index.loose) do
        local pi = pos[l.prefix]
        if pi then
            local matched = false
            for _, base in ipairs(l.bases) do
                local bi = pos[base]
                if bi then
                    for _, a in ipairs(pi) do
                        for _, b in ipairs(bi) do
                            if a ~= b and math.abs(a - b) <= LOOSE_WINDOW then
                                matched = true
                            end
                        end
                    end
                end
            end
            if matched then add(l.itemID, "loose", nil) end
        end
    end

    local out = {}
    for _, hit in pairs(best) do out[#out + 1] = hit end
    table.sort(out, function(x, y)
        if TIER_RANK[x.tier] ~= TIER_RANK[y.tier] then
            return TIER_RANK[x.tier] > TIER_RANK[y.tier]
        end
        return x.itemID < y.itemID
    end)
    return out
end
