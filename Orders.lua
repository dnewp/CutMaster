local addonName, ns = ...

ns.Orders = ns.Orders or {}
local Orders = ns.Orders

Orders.STATUS = { "pending", "grouped", "mats", "done", "cancelled" }

--------------------------------------------------------------------------------
-- Creation and lookup
--------------------------------------------------------------------------------

-- Case-insensitive on purpose. A manually typed name ("wokenough") and the
-- live trade partner's actual casing ("Wokenough") are the same player, but
-- an exact match missed that: the order sat un-credited while the payment
-- landed only in the global ledger, with no orderID and no confirmation
-- print. The stored casing is left as-is; only the comparison is folded.
function Orders.Open(player)
    if not player then return nil end
    local key = player:lower()
    for _, o in ipairs(ns.db.orders) do
        if o.player and o.player:lower() == key
            and o.status ~= "done" and o.status ~= "cancelled" then
            return o
        end
    end
    return nil
end

function Orders.Create(player, source, requestText, matched, now, status)
    local o = {
        id = ns.db.nextOrderID,
        player = player,
        source = source,
        requestText = ns.Util.StripEscapes(requestText or ""),
        createdAt = now,
        updatedAt = now,
        status = status or "pending",
        items = {},
        matsReceived = {},
        needsSplit = false,
        copperIn = 0,
        transcript = {},
        notes = "",
    }
    ns.db.nextOrderID = ns.db.nextOrderID + 1

    for _, h in ipairs(matched or {}) do
        o.items[#o.items + 1] = {
            itemID = h.itemID,
            qty = h.qtyHint or 1,
            qtySource = h.qtyHint and "text" or "default",
        }
    end

    table.insert(ns.db.orders, 1, o)
    return o
end

-- A repeat request from someone with an order already open updates it rather
-- than creating a second one.
function Orders.Record(player, source, text, matched, now)
    local o = Orders.Open(player)
    if not o then
        o = Orders.Create(player, source, text, matched, now)
        ns.Print(string.format("|cff44ff44order #%d opened|r for %s: %s",
            o.id, player, Orders.Summarise(o)))
        -- Refresh, do not auto-show: a pending order is somebody who has not
        -- turned up yet, so popping the tracker for it is premature.
        if ns.Tracker then ns.Tracker.Refresh() end
        return o, true
    end

    local added = false
    for _, h in ipairs(matched or {}) do
        local found = false
        for _, it in ipairs(o.items) do
            if it.itemID == h.itemID then found = true break end
        end
        if not found then
            o.items[#o.items + 1] = {
                itemID = h.itemID,
                qty = h.qtyHint or 1,
                qtySource = h.qtyHint and "text" or "default",
            }
            added = true
        end
    end
    o.updatedAt = now
    if added then
        ns.Print(string.format("order #%d updated: %s", o.id, Orders.Summarise(o)))
    end
    return o, false
end

function Orders.AddTranscript(player, dir, text, now)
    local o = Orders.Open(player)
    if not o then return end
    o.transcript[#o.transcript + 1] =
        { at = now, dir = dir, text = ns.Util.StripEscapes(text) }
    o.updatedAt = now
end

function Orders.SetStatus(o, status, now)
    o.status = status
    o.updatedAt = now
    if status == "done" then o.completedAt = now end
end

-- There was previously no way to discard one wrong or stale line item
-- without cancelling the whole order, right-clicking the header ("removes
-- the order") or leaving the tracker permanently stuck on an item nobody
-- ever intends to fulfil (nothing to tick, order can never auto-complete).
-- Returns true if something was removed.
function Orders.RemoveItem(o, itemID)
    local removed = false
    for i = #o.items, 1, -1 do
        if o.items[i].itemID == itemID then
            table.remove(o.items, i)
            removed = true
        end
    end
    if removed then
        local stillAmbiguous = false
        for _, it in ipairs(o.items) do
            if it.qtySource == "ambiguous" then stillAmbiguous = true break end
        end
        o.needsSplit = stillAmbiguous
    end
    return removed
end

-- Case-insensitive substring match on the item's name, since a slash command
-- user has the gem's name in front of them, not its itemID.
function Orders.FindItemByName(o, text)
    text = ns.Util.Normalize(text)
    if text == "" then return nil end
    for _, it in ipairs(o.items) do
        local e = ns.db.book[it.itemID]
        if e and e.name and ns.Util.Normalize(e.name):find(text, 1, true) then
            return it.itemID
        end
    end
    return nil
end

function Orders.Summarise(o)
    local parts = {}
    for _, it in ipairs(o.items) do
        local e = ns.db.book[it.itemID]
        local name = e and (e.link or e.name) or tostring(it.itemID)
        parts[#parts + 1] = string.format("%s x%d%s", name, it.qty,
            it.qtySource == "mats" and "" or "?")
    end
    if #parts == 0 then return "(nothing specified yet)" end
    return table.concat(parts, ", ")
end

--------------------------------------------------------------------------------
-- Quantity inference
--------------------------------------------------------------------------------

-- Pure. Customers rarely state a quantity: they ask for "bold living ruby",
-- hand over three Living Ruby, and expect three cut. So the mats are
-- authoritative and any number parsed from the text is only a hint.
--
-- order.items is mutated in place. Returns needsSplit, addedItems.
--
-- book maps cutItemID -> { reagents = { [rawItemID] = countPerCraft } }
function Orders.InferQuantities(order, matsReceived, book)
    local needsSplit = false
    local added = {}

    for rawID, count in pairs(matsReceived) do
        -- Which of the cuts they asked for consume this raw gem?
        local candidates = {}
        for _, it in ipairs(order.items) do
            local entry = book[it.itemID]
            if entry and entry.reagents and entry.reagents[rawID] then
                candidates[#candidates + 1] = it
            end
        end

        if #candidates == 1 then
            local per = book[candidates[1].itemID].reagents[rawID] or 1
            candidates[1].qty = math.floor(count / per)
            candidates[1].qtySource = "mats"
        elseif #candidates > 1 then
            -- They asked for two cuts from the same raw gem. We cannot know
            -- the split, and guessing means cutting the wrong gems.
            needsSplit = true
            for _, it in ipairs(candidates) do
                it.qtySource = "ambiguous"
            end
        else
            -- Mats for something they never asked for. People change their
            -- mind at the trade window constantly, so add it.
            for cutID, entry in pairs(book) do
                if entry.reagents and entry.reagents[rawID] and entry.bindType ~= 1 then
                    local per = entry.reagents[rawID] or 1
                    local item = {
                        itemID = cutID,
                        qty = math.floor(count / per),
                        qtySource = "mats",
                        unrequested = true,
                    }
                    order.items[#order.items + 1] = item
                    added[#added + 1] = item
                    break
                end
            end
        end
    end

    order.needsSplit = needsSplit
    return needsSplit, added
end

--------------------------------------------------------------------------------
-- Maintenance
--------------------------------------------------------------------------------

function Orders.Prune(now, keepDays)
    local cutoff = now - (keepDays * 86400)
    local kept = {}
    for _, o in ipairs(ns.db.orders) do
        if o.status ~= "done" or (o.completedAt or o.updatedAt or now) > cutoff then
            kept[#kept + 1] = o
        end
    end
    ns.db.orders = kept
end

-- "Open" means they actually turned up. A pending order is somebody who asked
-- for a cut and may never join, so counting it as work in progress inflates
-- the queue with people who wandered off.
function Orders.OpenList()
    local out = {}
    for _, o in ipairs(ns.db.orders) do
        if o.status == "grouped" or o.status == "mats" then out[#out + 1] = o end
    end
    return out
end

-- Everything not finished, including pending. For the Orders tab, which is
-- the full picture rather than the working queue.
function Orders.ActiveList()
    local out = {}
    for _, o in ipairs(ns.db.orders) do
        if o.status ~= "done" and o.status ~= "cancelled" then out[#out + 1] = o end
    end
    return out
end

-- Not counted as open work (see OpenList above), but still worth seeing and
-- still cancellable, so the Tracker has something to render for it.
function Orders.PendingList()
    local out = {}
    for _, o in ipairs(ns.db.orders) do
        if o.status == "pending" then out[#out + 1] = o end
    end
    return out
end

function Orders.PendingCount()
    return #Orders.PendingList()
end

function Orders.ByID(id)
    for _, o in ipairs(ns.db.orders) do
        if o.id == id then return o end
    end
    return nil
end

-- A pending order nobody ever joined for is not real work in progress: they
-- may have missed the invite, alt-tabbed, or simply changed their mind. Left
-- alone it sits in the queue forever looking like a live customer. Only
-- "pending" is touched: once someone has actually grouped up, a slow reply
-- is not the same problem and should not be auto-cancelled out from under
-- them.
function Orders.ExpireStale(now, timeoutSec)
    local expired = {}
    for _, o in ipairs(ns.db.orders) do
        if o.status == "pending" and (now - o.createdAt) >= timeoutSec then
            Orders.SetStatus(o, "cancelled", now)
            expired[#expired + 1] = o
        end
    end
    return expired
end

-- Declining is a faster, explicit version of the same thing: no need to wait
-- out the timeout once they have said no outright.
function Orders.CancelPending(player, now)
    local o = Orders.Open(player)
    if o and o.status == "pending" then
        Orders.SetStatus(o, "cancelled", now)
        return o
    end
    return nil
end

-- Promote anyone who has now actually joined the group.
function Orders.PromoteGrouped(now)
    if not ns.Enabled() then return 0 end
    local promoted = 0
    for _, o in ipairs(ns.db.orders) do
        if o.status == "pending" and (UnitInParty(o.player) or UnitInRaid(o.player)) then
            Orders.SetStatus(o, "grouped", now)
            promoted = promoted + 1
            ns.Print(string.format("|cff44ff44%s joined.|r Order #%d is now open: %s",
                o.player, o.id, Orders.Summarise(o)))
        end
    end
    if promoted > 0 and ns.Tracker then ns.Tracker.Notify() end
    return promoted
end

-- Checking every 5 min for a 5 min timeout would let one slip through for
-- nearly double the configured window. A minute is close enough without
-- being wasteful.
local POLL_INTERVAL = 60

function Orders.Poll()
    if not ns.Enabled() then return end
    local timeout = ns.db.settings.orders.pendingTimeoutSec
    if not timeout or timeout <= 0 then return end

    local now = GetServerTime and GetServerTime() or time()
    local expired = Orders.ExpireStale(now, timeout)
    for _, o in ipairs(expired) do
        ns.Print(string.format(
            "|cff888888order #%d for %s expired, never joined within %d min.|r",
            o.id, o.player, math.floor(timeout / 60)))
    end
    if #expired > 0 and ns.Tracker then ns.Tracker.Refresh() end
end

function Orders.StartExpiryTicker()
    if Orders.expiryTicker then Orders.expiryTicker:Cancel() end
    Orders.expiryTicker = C_Timer.NewTicker(POLL_INTERVAL, Orders.Poll)
end
