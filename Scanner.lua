local addonName, ns = ...

ns.Scanner = ns.Scanner or {}
local Scanner = ns.Scanner

local JEWELCRAFTING = "Jewelcrafting"

-- Pure. Folds a fresh scan into the stored book without losing user choices.
function Scanner.MergeBook(oldBook, scanned)
    oldBook = oldBook or {}
    local newBook = {}
    local seen = {}
    local added = 0

    for _, s in ipairs(scanned) do
        seen[s.itemID] = true
        local prev = oldBook[s.itemID]
        local entry = {
            itemID = s.itemID,
            name = s.name,
            link = s.link,
            header = s.header,
            classID = s.classID,
            quality = s.quality,
            bindType = s.bindType,
            reagents = s.reagents or {},
        }
        if prev then
            entry.advertise = prev.advertise
            entry.match = prev.match
            entry.aliases = prev.aliases or {}
            if entry.advertise == nil then entry.advertise = true end
            if entry.match == nil then entry.match = true end
        else
            entry.advertise = true
            entry.match = true
            entry.aliases = {}
            added = added + 1
        end
        newBook[s.itemID] = entry
    end

    for itemID, prev in pairs(oldBook) do
        if not seen[itemID] then
            local kept = {}
            for k, v in pairs(prev) do kept[k] = v end
            kept.stale = true
            newBook[itemID] = kept
        end
    end

    return newBook, added
end

-- Pure. Auto-scan clears the tradeskill window's filters as a side effect, so
-- it only earns that disruption when it might actually learn something.
function Scanner.ShouldAutoScan(bookCount, dirty, scannedAt, now, staleSec)
    if bookCount == 0 then return true end
    if dirty then return true end
    return (now - (scannedAt or 0)) > staleSec
end

function Scanner.IsJewelcrafting()
    if not GetTradeSkillLine then return false end
    local line = GetTradeSkillLine()
    return line == JEWELCRAFTING
end

local function SaveFilters()
    return {
        makeable = TradeSkillFrame and TradeSkillFrame.filterTbl
            and TradeSkillFrame.filterTbl.hasMaterials or false,
    }
end

-- The tradeskill list only reports rows passing the window's active filters, so
-- a leftover subclass filter or search term silently yields a partial book.
local function ClearFilters()
    if SetTradeSkillSubClassFilter then SetTradeSkillSubClassFilter(0, 1, 1) end
    if SetTradeSkillInvSlotFilter then SetTradeSkillInvSlotFilter(0, 1, 1) end
    if TradeSkillOnlyShowMakeable then TradeSkillOnlyShowMakeable(false) end
    if TradeSkillOnlyShowSkillUps then TradeSkillOnlyShowSkillUps(false) end
    if SetTradeSkillItemNameFilter then SetTradeSkillItemNameFilter("") end
    if ExpandTradeSkillSubClass then ExpandTradeSkillSubClass(0) end
end

local function RestoreFilters(saved)
    if TradeSkillOnlyShowMakeable and saved and saved.makeable then
        TradeSkillOnlyShowMakeable(true)
    end
end

local function ReadReagents(idx)
    local reagents = {}
    local n = GetTradeSkillNumReagents and GetTradeSkillNumReagents(idx) or 0
    for r = 1, n do
        local link = GetTradeSkillReagentItemLink(idx, r)
        local _, _, required = GetTradeSkillReagentInfo(idx, r)
        if link then
            local id = tonumber(link:match("|Hitem:(%d+)"))
            if id then reagents[id] = required or 1 end
        end
    end
    return reagents
end

local function CollectRows()
    local rows, failed = {}, {}
    local header = nil
    local count = GetNumTradeSkills() or 0

    for idx = 1, count do
        local skillName, skillType = GetTradeSkillInfo(idx)
        if skillType == "header" then
            header = skillName
        else
            local link = GetTradeSkillItemLink(idx)
            local itemID = link and tonumber(link:match("|Hitem:(%d+)"))
            if itemID then
                local name, _, quality, _, _, _, _, _, _, _, _, classID,
                      _, bindType = GetItemInfo(link)
                rows[#rows + 1] = {
                    itemID = itemID,
                    name = name or skillName,
                    link = link,
                    header = header or "Other",
                    classID = classID,
                    quality = quality,
                    bindType = bindType,
                    reagents = ReadReagents(idx),
                }
            else
                failed[#failed + 1] = idx
            end
        end
    end

    return rows, failed
end

function Scanner.Scan(opts)
    opts = opts or {}

    if not Scanner.IsJewelcrafting() then
        if not opts.silent then
            ns.Print("open your Jewelcrafting window first, then run /cm scan.")
        end
        return 0, 0, 0
    end

    local saved = SaveFilters()
    ClearFilters()

    local rows, failed = CollectRows()

    local function commit(finalRows, finalFailed)
        local book, added = Scanner.MergeBook(ns.db.book, finalRows)
        ns.db.book = book
        ns.db.bookScannedAt = GetServerTime and GetServerTime() or time()
        ns.db.bookPartial = #finalFailed > 0
        ns.db.bookDirty = false

        if ns.Events then ns.Events.RebuildIndex() end
        if ns.Stats then ns.Stats.Annotate(book) end

        RestoreFilters(saved)

        if not opts.silent then
            local gems = 0
            for _, e in pairs(book) do
                if e.classID == 3 and not e.stale then gems = gems + 1 end
            end
            ns.Print(string.format("scanned %d recipes (%d gems), %d new since last scan.",
                #finalRows, gems, added))
            if #finalFailed > 0 then
                ns.Print(string.format(
                    "|cffff9900%d rows could not be read (item data not cached). Run /cm scan again.|r",
                    #finalFailed))
            end
        end

        if Scanner.initiatedByUs then
            Scanner.initiatedByUs = false
            if CloseTradeSkill then CloseTradeSkill() end
        end

        return added, #finalRows, #finalFailed
    end

    -- Uncached items return nil links on the first pass. Give them one retry.
    if #failed > 0 then
        C_Timer.After(0.5, function()
            if Scanner.IsJewelcrafting() then
                local retryRows, retryFailed = CollectRows()
                commit(retryRows, retryFailed)
            else
                commit(rows, failed)
            end
        end)
        return 0, #rows, #failed
    end

    return commit(rows, failed)
end
