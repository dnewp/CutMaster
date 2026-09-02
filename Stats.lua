local addonName, ns = ...

-- Shows what a gem actually does instead of what it is called, so you can find
-- "+8 Agility" in the Jewelcrafting window without memorising which cut name
-- maps to which stat.

ns.Stats = ns.Stats or {}
local Stats = ns.Stats

local GEM_CLASS = 3
local cache = {}

local scanTip = CreateFrame("GameTooltip", "CutMasterScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Works in any locale: "+8 Agility" always starts with a plus and a digit,
-- green is the game's universal colour for an equip effect, and a white line
-- with a percentage is a proc description.
local function IsStatLine(text, r, g, b)
    if not text or text == "" then return false end
    if text:match("^%+%d") then return true end
    if g > 0.9 and r < 0.2 and b < 0.2 then return true end
    if text:find("%%") and r > 0.9 and g > 0.9 and b > 0.9 then return true end
    return false
end

function Stats.For(link)
    if not link then return nil end
    local itemID = link:match("|Hitem:(%d+)")
    if not itemID then return nil end
    if cache[itemID] ~= nil then
        return cache[itemID] or nil
    end

    local classID = select(12, GetItemInfo(link))
    if classID ~= GEM_CLASS then
        cache[itemID] = false
        return nil
    end

    scanTip:ClearLines()
    scanTip:SetHyperlink(link)

    local lines, firstLine = {}, nil
    for i = 2, scanTip:NumLines() do
        local left = _G["CutMasterScanTipTextLeft" .. i]
        local text = left and left:GetText()
        if text then
            text = strtrim(text)
            if text ~= "" then
                firstLine = firstLine or text
                local r, g, b = left:GetTextColor()
                -- Meta gem requirement lines are noise, not an effect.
                if IsStatLine(text, r, g, b)
                    and not text:find("Requires at least", 1, true) then
                    lines[#lines + 1] = text
                end
            end
        end
    end

    -- Some gems state their effect in plain white with no plus sign; line 2 of
    -- a gem tooltip is always the effect, so fall back to it.
    if #lines == 0 and firstLine then lines[1] = firstLine end

    local result = #lines > 0 and table.concat(lines, ", ") or false
    cache[itemID] = result
    return result or nil
end

-- Fill in stats for the whole book, so the Book tab and the tracker can show
-- them too. Cheap: the tooltip scan is cached per item.
function Stats.Annotate(book)
    local n = 0
    for itemID, e in pairs(book) do
        if e.classID == GEM_CLASS and e.link and not e.stats then
            local s = Stats.For(e.link)
            if s then e.stats = s; n = n + 1 end
        end
    end
    return n
end

--------------------------------------------------------------------------------
-- Tradeskill window
--------------------------------------------------------------------------------

local hooked = false

local function Repaint()
    if not ns.db.settings.gemStats then return end
    if not TradeSkillFrame or not TradeSkillFrame:IsShown() then return end
    if not ns.Scanner.IsJewelcrafting() then return end

    local offset = FauxScrollFrame_GetOffset(TradeSkillListScrollFrame) or 0
    local numSkills = GetNumTradeSkills() or 0
    local shown = TRADE_SKILLS_DISPLAYED or 8

    for i = 1, shown do
        local idx = i + offset
        local button = _G["TradeSkillSkill" .. i]
        if button and idx <= numSkills then
            local _, skillType = GetTradeSkillInfo(idx)
            if skillType ~= "header" then
                local stats = Stats.For(GetTradeSkillItemLink(idx))
                if stats then button:SetText(stats) end
            end
        end
    end
end

function Stats.Hook()
    if hooked then return end
    if type(TradeSkillFrame_Update) ~= "function" then return end
    hooksecurefunc("TradeSkillFrame_Update", Repaint)
    hooked = true
end

local function UpdateButton()
    local b = Stats.button
    if not b then return end
    local on = ns.db.settings.gemStats
    local tex = b:GetNormalTexture()
    if tex then
        tex:SetDesaturated(not on)
        tex:SetAlpha(on and 1 or 0.5)
    end
end

function Stats.Toggle()
    ns.db.settings.gemStats = not ns.db.settings.gemStats
    Stats.Hook()
    UpdateButton()
    if TradeSkillFrame_Update and TradeSkillFrame and TradeSkillFrame:IsShown() then
        -- Repaints from Blizzard's data, which restores the real names when
        -- the feature is switched off.
        TradeSkillFrame_Update()
    end
    ns.Print("gem stats in the Jewelcrafting window "
        .. (ns.db.settings.gemStats and "|cff44ff44on|r" or "|cffff4444off|r"))
end

-- A gem icon on the Jewelcrafting window itself, so switching between stats
-- and names is one click where you are already looking.
function Stats.CreateButton()
    if Stats.button or not TradeSkillFrame then return end

    local b = CreateFrame("Button", "CutMasterStatsToggle", TradeSkillFrame)
    b:SetSize(26, 26)
    b:SetPoint("TOPRIGHT", TradeSkillFrame, "TOPRIGHT", -52, -12)
    b:SetNormalTexture("Interface\\AddOns\\CutMaster\\CutMaster.tga")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    b:SetScript("OnClick", Stats.Toggle)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("CutMaster")
        GameTooltip:AddLine(ns.db.settings.gemStats
            and "|cff44ff44Showing gem stats|r" or "|cffff4444Showing gem names|r")
        GameTooltip:AddLine("|cff888888Click to switch|r")
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    Stats.button = b
    UpdateButton()
end

function Stats.OnTradeSkillShow()
    Stats.Hook()
    Stats.CreateButton()
    if Stats.button then
        -- Only meaningful for Jewelcrafting; hide it for other professions.
        Stats.button:SetShown(ns.Scanner.IsJewelcrafting())
        UpdateButton()
    end
end
