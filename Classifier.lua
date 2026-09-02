local addonName, ns = ...

ns.Classifier = ns.Classifier or {}
local Classifier = ns.Classifier
local Util = ns.Util

local MANY_LINKS = 3
local GUARDED_CAN_CUT_WEIGHT = 3
local QUESTION_WEIGHT = 1

-- "can cut" is a seller phrase in "I can cut that" but a buyer phrase in
-- "anyone who can cut this?". Look back two tokens to tell them apart.
local function CanCutIsGuarded(norm, guards)
    local toks = Util.Tokenize(norm)
    for i = 1, #toks - 1 do
        if toks[i] == "can" and toks[i + 1] == "cut" then
            for back = 1, 2 do
                local w = toks[i - back]
                if w then
                    for _, g in ipairs(guards) do
                        if w == g then return true end
                    end
                end
            end
        end
    end
    return false
end

function Classifier.Evaluate(ctx)
    local filter = ctx.filter
    local result = {
        sellerScore = 0, sellerHits = {},
        buyerScore = 0, buyerHits = {},
        netScore = 0,
    }

    local function seller(key, weight)
        result.sellerScore = result.sellerScore + weight
        result.sellerHits[key] = weight
    end

    local function buyer(key, weight)
        result.buyerScore = result.buyerScore + weight
        result.buyerHits[key] = weight
    end

    -- Operational state ("invites off", "cooldown", "group full") is recorded
    -- but must NOT decide the content verdict. Conflating them meant that with
    -- invites disabled every message returned "invites disabled" and nothing
    -- was ever scored, so the addon could not explain itself while idle.
    result.blocked = ctx.blocked

    if not ctx.matched or #ctx.matched == 0 then
        result.verdict = "lowscore"
        result.reason = "no gem match"
        return result
    end

    for phrase, weight in pairs(filter.sellerWords) do
        if Util.HasPhrase(ctx.norm, phrase) then seller(phrase, weight) end
    end

    if Util.HasPhrase(ctx.norm, "can cut") then
        if CanCutIsGuarded(ctx.norm, filter.canCutGuards) then
            buyer("can cut (guarded)", GUARDED_CAN_CUT_WEIGHT)
        else
            seller("canCut", filter.weights.canCut)
        end
    end

    -- Vocabulary-free signals. These catch competitors who word ads carefully.
    if (ctx.linkCount or 0) >= MANY_LINKS then
        seller("manyLinks", filter.weights.manyLinks)
    end

    if ctx.hasDesignLink then
        seller("designLink", filter.weights.designLink)
    end

    if ctx.isRepeat then
        seller("repeatBark", filter.weights.repeatBark)
    end

    local hasQuestion = ctx.raw and ctx.raw:find("?", 1, true) ~= nil
    if (ctx.linkCount or 0) >= 2 and not hasQuestion and result.sellerScore > 0 then
        seller("shapeMatch", filter.weights.shapeMatch)
    end

    for phrase, weight in pairs(filter.buyerWords) do
        if Util.HasPhrase(ctx.norm, phrase) then buyer(phrase, weight) end
    end

    if hasQuestion then buyer("question", QUESTION_WEIGHT) end

    -- Content vetoes are applied after scoring so the log still shows which
    -- signals were present, rather than an unexplained rejection.
    if ctx.playerState and ctx.playerState.neverInvite then
        result.verdict = "vetoed"
        result.reason = "never invite"
        return result
    end

    if ctx.playerState and ctx.playerState.flaggedSeller then
        result.verdict = "vetoed"
        result.reason = "flagged seller"
        return result
    end

    for _, word in ipairs(filter.vetoWords) do
        if Util.HasPhrase(ctx.norm, word) then
            result.verdict = "vetoed"
            result.reason = word
            return result
        end
    end

    -- Net, not raw. A raw seller threshold would make buyer evidence
    -- decorative and any heavy signal an unconditional block.
    result.netScore = result.sellerScore - result.buyerScore

    if result.netScore >= filter.netThreshold then
        result.verdict = "lowscore"
        result.reason = "seller score"
        return result
    end

    if filter.requireBuyerSignal and result.buyerScore < 1 then
        result.verdict = "lowscore"
        result.reason = "no buyer signal"
        return result
    end

    result.verdict = "invite"
    result.reason = "matched"
    return result
end
