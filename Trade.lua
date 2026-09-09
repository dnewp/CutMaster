local addonName, ns = ...

ns.Trade = ns.Trade or {}
local Trade = ns.Trade

-- Slots 1 to 6 are traded. Slot 7 is the "will not be traded" slot.
local TRADE_SLOTS = 6

local function ReadSide(getLink, getInfo)
    local items, links = {}, {}
    for i = 1, TRADE_SLOTS do
        local link = getLink(i)
        if link then
            local id = tonumber(link:match("|Hitem:(%d+)"))
            local _, _, qty = getInfo(i)
            if id then
                items[id] = (items[id] or 0) + (qty or 1)
                links[id] = link
            end
        end
    end
    return items, links
end

function Trade.Snapshot()
    local incoming, inLinks = ReadSide(GetTradeTargetItemLink, GetTradeTargetItemInfo)
    local outgoing, outLinks = ReadSide(GetTradePlayerItemLink, GetTradePlayerItemInfo)
    return {
        partner = Trade.partner,
        incoming = incoming, incomingLinks = inLinks,
        outgoing = outgoing, outLinks = outLinks,
        theirMoney = GetTargetTradeMoney and GetTargetTradeMoney() or 0,
        ourMoney = GetPlayerTradeMoney and GetPlayerTradeMoney() or 0,
    }
end

-- Pure. Splits a snapshot's incoming items into raw reagents for this order
-- and finished cuts, so we can tell a mats handoff from a delivery.
function Trade.Classify(snapshot, book)
    local rawMats, cuts = {}, {}
    for id, qty in pairs(snapshot.incoming) do
        if book[id] then cuts[id] = qty else rawMats[id] = qty end
    end
    local deliveredCuts = {}
    for id, qty in pairs(snapshot.outgoing) do
        if book[id] then deliveredCuts[id] = qty end
    end
    return rawMats, cuts, deliveredCuts
end

local function Commit(snapshot)
    if not ns.Enabled() then return end
    local now = GetServerTime and GetServerTime() or time()
    local player = snapshot.partner
    if not player then return end

    local net = (snapshot.theirMoney or 0) - (snapshot.ourMoney or 0)
    local order = ns.Orders.Open(player)

    local rawMats, _, delivered = ns.Trade.Classify(snapshot, ns.db.book)

    local anyRaw = next(rawMats) ~= nil
    local anyDelivered = next(delivered) ~= nil

    if not order then
        if anyRaw or anyDelivered or net > 0 then
            ns.Print(string.format(
                "|cffffcc00%s traded with you and has no open order.|r "
                .. "Use /cm order add %s to start one.", player, player))
        end
        if net ~= 0 then ns.Ledger.Record(player, nil, net, delivered, now) end
        return
    end

    -- Mats in: quantities come from what actually landed in the window.
    if anyRaw then
        for id, qty in pairs(rawMats) do
            order.matsReceived[id] = (order.matsReceived[id] or 0) + qty
        end
        local needsSplit, added, unclear = ns.Orders.InferQuantities(
            order, order.matsReceived, ns.db.book)

        if ns.db.settings.orders.autoAdvanceMats and order.status ~= "done" then
            ns.Orders.SetStatus(order, "mats", now)
        end

        ns.Print(string.format("order #%d: mats received. %s",
            order.id, ns.Orders.Summarise(order)))
        if #added > 0 then
            ns.Print("  |cffffcc00added a cut they did not originally ask for.|r")
        end
        if needsSplit then
            ns.Print("  |cffff9900ambiguous: those mats fit more than one cut "
                .. "they asked for. Set the split in the Orders tab.|r")
        end
        for _, rawID in ipairs(unclear) do
            local raw = GetItemInfo and select(2, GetItemInfo(rawID))
            ns.Print(string.format(
                "  |cffff9900they traded %s but never named a cut you know for "
                .. "it. Ask which one they want, then add it in the Orders "
                .. "tab.|r", raw or ("item " .. rawID)))
        end
    end

    if net ~= 0 then
        order.copperIn = (order.copperIn or 0) + net
        ns.Ledger.Record(player, order.id, net, delivered, now)
        ns.Print(string.format("order #%d: received %s",
            order.id, ns.Ledger.Money(net)))
    end

    -- Handing finished cuts over is a delivery, so offer to close the order.
    if anyDelivered and ns.db.settings.orders.promptOnDone then
        ns.Print(string.format(
            "|cff44ff44order #%d looks delivered.|r /cm order done %d to close it.",
            order.id, order.id))
    end

    order.updatedAt = now
end

--------------------------------------------------------------------------------
-- Auto fill
--------------------------------------------------------------------------------

-- Container API moved into C_Container on newer clients. Resolve at call time
-- so this works either way, the same shim Gargul uses. getInfo additionally
-- returns the stack count: a gem stack is usually more than one, and earlier
-- code assumed one unit per bag slot, undercounting every stacked cut.
local function Container()
    local numSlots = GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots)
    local useItem = UseContainerItem or (C_Container and C_Container.UseContainerItem)
    local getInfo
    if C_Container and C_Container.GetContainerItemInfo then
        getInfo = function(bag, slot)
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if not info then return nil, 0 end
            return info.hyperlink, info.stackCount or 1, info.isLocked
        end
    elseif GetContainerItemInfo then
        getInfo = function(bag, slot)
            local _, count, locked, _, _, _, link = GetContainerItemInfo(bag, slot)
            return link, count or 1, locked
        end
    end
    return numSlots, useItem, getInfo
end

local function FreeTradeSlots()
    local used = 0
    for i = 1, TRADE_SLOTS do
        if GetTradePlayerItemLink(i) then used = used + 1 end
    end
    return TRADE_SLOTS - used
end

-- What is ACTUALLY sitting in "you will give" right now, per item.
local function OutgoingCounts()
    return (ReadSide(GetTradePlayerItemLink, GetTradePlayerItemInfo))
end

-- What the customer has put in, per item, while the window is still open.
local function IncomingCounts()
    return (ReadSide(GetTradeTargetItemLink, GetTradeTargetItemInfo))
end

-- Pure. The order's quantities, raised to match the mats actually sitting in
-- the window. Mats are only folded into the order when the trade CLOSES, but
-- the fill runs when it OPENS, so a customer who hands over three stones and
-- takes their cuts in one trade was filled for the order's default of one.
-- Since the mats are what say how many cuts they want, reading them live
-- fixes the count without waiting for the trade to end.
--
-- Only raised, never lowered: the order may legitimately be for more than
-- this trade's stones, e.g. mats handed over earlier in a separate trade.
function Trade.WantedWithMats(wanted, incoming, order, book)
    local out = {}
    for id, q in pairs(wanted) do out[id] = q end

    for rawID, count in pairs(incoming or {}) do
        local only, n = nil, 0
        for _, it in ipairs(order.items or {}) do
            local e = book[it.itemID]
            if e and e.reagents and e.reagents[rawID] then
                only, n = it.itemID, n + 1
            end
        end
        -- Two cuts of theirs take the same stone: we cannot know the split,
        -- and guessing means cutting the wrong gems. InferQuantities flags
        -- that case at the trade window; here we simply leave it alone.
        if n == 1 then
            local per = book[only].reagents[rawID] or 1
            local implied = per > 0 and math.floor(count / per) or 0
            if implied > (out[only] or 0) then out[only] = implied end
        end
    end

    return out
end

-- Pure. What is still owed, measured against the trade window rather than
-- against our own record of what we think we already moved. Two separate
-- one-count stacks of the same gem used to deliver only one of them: the
-- first use() worked, the second did nothing, and the fill loop subtracted
-- for it anyway and declared the order complete. Counting the real window
-- means a use() that quietly does nothing is seen instead of assumed away.
function Trade.StillWanted(wanted, outgoing)
    local left = {}
    for id, qty in pairs(wanted) do
        local short = qty - (outgoing[id] or 0)
        if short > 0 then left[id] = short end
    end
    return left
end

-- Pure. Bind on pickup is skipped: it cannot be traded, so never queue one.
function Trade.WantedFromOrder(order, book)
    local wanted = {}
    for _, it in ipairs(order.items or {}) do
        local e = book[it.itemID]
        if not e or e.bindType ~= 1 then
            wanted[it.itemID] = (wanted[it.itemID] or 0) + (it.qty or 1)
        end
    end
    return wanted
end

-- Pure. First bag row (from a fresh scan) matching something still wanted.
-- Re-run against a NEW snapshot every tick rather than reusing one computed
-- before earlier moves: after a slot empties, bags can shift, and trusting
-- stale (bag, slot) coordinates was silently dropping every item after the
-- first one or two once their expected slot no longer held what was queued.
function Trade.NextFillSlot(wanted, bagSnapshot)
    for _, row in ipairs(bagSnapshot) do
        if (wanted[row.itemID] or 0) > 0 then
            return row
        end
    end
    return nil
end

-- A gem placed in the trade window does NOT leave the bag: it stays in its
-- slot, flagged locked, until the trade completes. Listing it anyway is what
-- broke every multi-gem order. The loop would move slot 18, see slot 18 still
-- holding the gem on the next pass, use it again to no effect, and after a
-- few of those give up on that gem entirely -- having delivered exactly one.
-- Locked slots are therefore not candidates: they are already in the window,
-- or mid-move, and either way there is nothing left to send from them.
local function BagSnapshot()
    local numSlots, _, getInfo = Container()
    local rows = {}
    if not numSlots or not getInfo then return rows end
    for bag = 0, 4 do
        for slot = 1, (numSlots(bag) or 0) do
            local link, count, locked = getInfo(bag, slot)
            local id = link and tonumber(link:match("|Hitem:(%d+)"))
            if id and not locked then
                rows[#rows + 1] = { bag = bag, slot = slot, itemID = id,
                                    link = link, count = count or 1 }
            end
        end
    end
    return rows
end

function Trade.StopFill()
    if Trade.fillTicker then
        Trade.fillTicker:Cancel()
        Trade.fillTicker = nil
    end
end

local function NameOf(id)
    local e = ns.db.book[id]
    return e and (e.link or e.name) or tostring(id)
end

local function ReportFill(order, wanted, short, slotsFull, movedAny)
    -- Counted off the trade window itself, so the number reported is what the
    -- customer will actually receive.
    local outgoing = OutgoingCounts()
    local delivered = 0
    for id, qty in pairs(wanted) do
        local got = outgoing[id] or 0
        delivered = delivered + (got < qty and got or qty)
    end
    -- Never claim credit for gems the user dragged in themselves.
    if delivered > 0 and movedAny then
        ns.Print(string.format("added %d gem%s to the trade for order #%d.",
            delivered, delivered == 1 and "" or "s", order.id))
    end

    local list = {}
    for id, q in pairs(short or {}) do
        list[#list + 1] = NameOf(id) .. " x" .. q
    end
    if #list == 0 then return end

    if slotsFull then
        -- WoW's own 6 slot cap on "you will give" items, not a bug: an order
        -- spanning more than 6 distinct gems genuinely needs a second trade.
        ns.Print("|cffff9900more than fits in one trade (6 slot limit): "
            .. table.concat(list, ", ")
            .. ". Complete this trade, then open a new one for the rest.|r")
    else
        ns.Print("|cffff9900still short: " .. table.concat(list, ", ")
            .. ". Add the rest by hand.|r")
    end
end

-- The fill happens over many ticks inside a trade window, where nothing can
-- be observed after the fact. Recording what each tick actually saw is the
-- only way to tell an item that would not move from one the loop never tried,
-- so the last fill is always kept for /cm lastfill to read back.
local function Trace(kind, data)
    local t = ns.db and ns.db.lastFill
    if not t then return end
    if #t.ticks >= 60 then return end
    data = data or {}
    data.n, data.kind = #t.ticks + 1, kind
    t.ticks[#t.ticks + 1] = data
end

local function CountsToString(t)
    local parts = {}
    for id, q in pairs(t or {}) do parts[#parts + 1] = id .. "x" .. q end
    table.sort(parts)
    return table.concat(parts, ",")
end

function Trade.AutoFill()
    Trade.StopFill()
    if not ns.Enabled() then return end
    if not ns.db.settings.orders.autoFillTrade then return end

    local order = Trade.partner and ns.Orders.Open(Trade.partner)

    ns.db.lastFill = {
        at = GetServerTime and GetServerTime() or time(),
        partner = Trade.partner,
        orderID = order and order.id,
        status = order and order.status,
        ticks = {},
    }
    if not order then
        Trace("no order open for partner")
        return
    end

    local baseWanted = Trade.WantedFromOrder(order, ns.db.book)
    ns.db.lastFill.baseWanted = CountsToString(baseWanted)

    local anyWanted = false
    for _, q in pairs(baseWanted) do if q > 0 then anyWanted = true break end end
    if not anyWanted then
        Trace("nothing wanted from the order")
        return
    end

    local warned = {}
    local overWarned = {}
    local movedAny = false

    -- A move takes a server round trip, which is longer than one tick. Only
    -- one is allowed in flight at a time: issuing the next before the last
    -- has left the bag re-used the same slot, and a slot whose item has since
    -- gone holds something else, so the second use could trade the wrong
    -- item entirely. Cut gems never stack, so a four-gem order is four
    -- separate slots and four separate round trips.
    local inFlight = nil
    local skip = {}

    -- Reporting is driven off what is owed, so it is said once per situation
    -- rather than every tick. When mats land and the number owed changes,
    -- the situation is new and worth speaking up about again.
    local lastSig, said = nil, false
    local function Signature(t)
        local parts = {}
        for id, q in pairs(t) do parts[#parts + 1] = id .. "x" .. q end
        table.sort(parts)
        return table.concat(parts, ",")
    end

    -- How many ticks to wait for a move to show up in the window before
    -- giving up on that slot. Generous on purpose: giving up early is the
    -- bug this whole path keeps hitting, and a slow move is far more likely
    -- than an impossible one.
    local MAX_WAIT = 14

    -- One per tick, re-scanning bags fresh each time. Adding items in a
    -- single frame bugs the trade UI, and a stale scan is what caused the
    -- original "stops after 1 or 2" bug.
    Trade.fillTicker = C_Timer.NewTicker(0.15, function()
        if not TradeFrame or not TradeFrame:IsShown() then
            Trace("trade window gone")
            Trade.StopFill()
            return
        end

        local outgoing = OutgoingCounts()

        -- Wait for the move in flight to show up in the window before doing
        -- anything else, so each gem gets its own round trip.
        if inFlight then
            local now = outgoing[inFlight.itemID] or 0
            if now > inFlight.before then
                Trace("landed", { itemID = inFlight.itemID, out = now })
                inFlight = nil
            else
                inFlight.ticks = inFlight.ticks + 1
                if inFlight.ticks < MAX_WAIT then
                    return
                end
                -- That slot will not move. Skip it so the loop moves on to
                -- the next one rather than retrying it forever.
                Trace("gave up on slot", { bag = inFlight.bag,
                                           slot = inFlight.slot,
                                           itemID = inFlight.itemID })
                if not warned[inFlight.itemID] then
                    warned[inFlight.itemID] = true
                    ns.Print(string.format(
                        "|cffff9900%s would not go into the trade. "
                        .. "Drag it in by hand.|r", NameOf(inFlight.itemID)))
                end
                skip[inFlight.bag .. ":" .. inFlight.slot] = true
                inFlight = nil
            end
        end

        -- Recomputed every tick. The customer can drop their stones in at any
        -- point while the window is open, and that is what says how many cuts
        -- they actually want.
        local wanted = Trade.WantedWithMats(baseWanted, IncomingCounts(),
                                            order, ns.db.book)
        local short = Trade.StillWanted(wanted, outgoing)

        local sig = Signature(wanted)
        if sig ~= lastSig then
            lastSig, said = sig, false
        end

        -- A slot that would not move is dropped from consideration, so one
        -- stubborn gem cannot stall the rest of the order.
        local bags = {}
        local held = {}
        for _, r in ipairs(BagSnapshot()) do
            local key = r.bag .. ":" .. r.slot
            if not skip[key] then bags[#bags + 1] = r end
            if wanted[r.itemID] then
                held[#held + 1] = string.format("b%d.s%d=%dx%d%s",
                    r.bag, r.slot, r.itemID, r.count,
                    skip[key] and "(skip)" or "")
            end
        end
        -- Only while something is still owed. Once the order is filled the
        -- loop idles until the window closes, and those ticks would other-
        -- wise flood out the part worth reading.
        if next(short) then
            Trace("tick", {
                outgoing = CountsToString(outgoing),
                incoming = CountsToString(IncomingCounts()),
                wanted = CountsToString(wanted),
                short = CountsToString(short),
                bags = table.concat(held, " "),
                freeSlots = FreeTradeSlots(),
            })
        end

        -- The ticker runs until the window closes rather than stopping at the
        -- first satisfied moment, so mats added later still top the trade up.
        if not next(short) then
            if not said then
                said = true
                Trace("satisfied")
                ReportFill(order, wanted, nil, false, movedAny)
            end
            return
        end

        if FreeTradeSlots() <= 0 then
            if not said then
                said = true
                Trace("trade slots full")
                ReportFill(order, wanted, short, true, movedAny)
            end
            return
        end

        local row = Trade.NextFillSlot(short, bags)
        if not row then
            if not said then
                said = true
                Trace("nothing in bags to fill with")
                ReportFill(order, wanted, short, false, movedAny)
            end
            return
        end

        local _, useItem = Container()
        if useItem then
            local still = short[row.itemID] or 0
            if row.count > still and not overWarned[row.itemID] then
                -- UseContainerItem moves the whole stack; there is no partial
                -- move. Flagged rather than silently over-delivering with no
                -- explanation. Said once, not once per retry.
                overWarned[row.itemID] = true
                ns.Print(string.format(
                    "|cffff9900%s: stack of %d moved, only %d was needed for this order.|r",
                    row.link, row.count, still))
            end

            movedAny = true
            inFlight = {
                itemID = row.itemID, bag = row.bag, slot = row.slot,
                before = outgoing[row.itemID] or 0, ticks = 0,
            }
            Trace("use", { bag = row.bag, slot = row.slot,
                           itemID = row.itemID, count = row.count,
                           had = inFlight.before })
            useItem(row.bag, row.slot)
        else
            Trace("no container use API")
        end
    end)
end

function Trade.OnEvent(event, ...)
    if event == "TRADE_SHOW" then
        Trade.partner = UnitName("NPC") or UnitName("npc")
        Trade.bothAccepted = false
        Trade.pending = nil
        C_Timer.After(0.2, Trade.AutoFill)
    elseif event == "TRADE_ACCEPT_UPDATE" then
        local playerAccepted, targetAccepted = ...
        if playerAccepted == 1 and targetAccepted == 1 then
            -- Last moment the contents are guaranteed readable.
            Trade.bothAccepted = true
            Trade.pending = Trade.Snapshot()
        end
    elseif event == "TRADE_CLOSED" then
        -- TRADE_CLOSED also fires on cancel and there is no unambiguous
        -- success event on this client, so only a snapshot taken while both
        -- sides had accepted is committed. Everything it applies is editable.
        if Trade.bothAccepted and Trade.pending then
            Commit(Trade.pending)
        end
        Trade.bothAccepted = false
        Trade.pending = nil
        Trade.partner = nil
        Trade.StopFill()
    end
end
