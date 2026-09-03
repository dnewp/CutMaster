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

-- Below this length a base word is too common to match on its own.
local MIN_TOKEN_LEN = 7

-- Cut prefixes run shorter than family words ("jagged" is 6, not 7+), and
-- the risk of a false positive is lower here: a prefix hit is only ever
-- surfaced locally (see PrefixNearMiss), never sent to the customer, so a
-- slightly looser gate just means an occasional extra line in the user's
-- own chat rather than a wrong reply going out.
local PREFIX_MIN_LEN = 6

local WORDNUM = {
    one = 1, two = 2, three = 3, four = 4, five = 5,
    six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
}

function Matcher.BuildIndex(book)
    local index = { byID = {}, names = {}, aliases = {}, loose = {},
                    bases = {}, baseTokens = {}, prefixOnly = {} }
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

                -- Single distinctive words, so "Shifting Shadowsong?" is
                -- recognisable without the customer finishing the name.
                -- Length gate keeps out common words like "star" or "ruby"
                -- that would fire on ordinary chat.
                for _, tok in ipairs(bases) do
                    if #tok >= MIN_TOKEN_LEN then
                        index.baseTokens[tok] = index.baseTokens[tok] or {}
                        local tl = index.baseTokens[tok]
                        tl[#tl + 1] = itemID
                    end
                end

                -- The cut prefix itself ("jagged", "bold"). Unlike a base
                -- word, a shared prefix does NOT mean these are tiers of one
                -- gem: "Jagged Seaspray Emerald" and "Jagged Deep Peridot"
                -- are unrelated gems that happen to share a tier adjective.
                -- Kept separate from baseTokens/bases for that reason; see
                -- Matcher.PrefixNearMiss, which surfaces this for the user
                -- to act on rather than guessing which one to reply about.
                if #toks[1] >= PREFIX_MIN_LEN then
                    index.prefixOnly[toks[1]] = index.prefixOnly[toks[1]] or {}
                    local pl = index.prefixOnly[toks[1]]
                    pl[#pl + 1] = itemID
                end
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

-- Call only when Match found nothing. Returns the gem family named, the cuts
-- of it we know, and whether the family name was COMPLETE.
--
-- Complete ("veiled pyrestone") means they finished naming a cut and it is not
-- ours. Incomplete ("shifting shadowsong", missing "amethyst") means they are
-- part way through and we should ask which one they meant.
function Matcher.NearMiss(norm, index)
    local bestKey, bestLen
    for baseKey in pairs(index.bases) do
        if baseKey ~= "" and Util.HasPhrase(norm, baseKey) then
            if not bestLen or #baseKey > bestLen then
                bestKey, bestLen = baseKey, #baseKey
            end
        end
    end
    if bestKey then return bestKey, index.bases[bestKey], true end

    -- Fall back to a single distinctive word from a gem family.
    for tok, ids in pairs(index.baseTokens or {}) do
        if Util.HasPhrase(norm, tok) then return tok, ids, false end
    end
    return nil
end

-- Call only when both Match and NearMiss found nothing. A cut prefix mentioned
-- with none of its base words present ("looking for jagged...") tells us they
-- mean one of the cuts sharing that prefix, but not which: "Jagged Seaspray
-- Emerald" and "Jagged Deep Peridot" are unrelated gems, not tiers of one.
-- Returns the prefix word and every itemID sharing it, or nil.
function Matcher.PrefixNearMiss(norm, index)
    local toks = Util.Tokenize(norm)
    for _, tok in ipairs(toks) do
        local ids = index.prefixOnly and index.prefixOnly[tok]
        if ids and #ids > 0 then
            return tok, ids
        end
    end
    return nil
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
