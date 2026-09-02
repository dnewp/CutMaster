local addonName, ns = ...

ns.Ledger = ns.Ledger or {}
local Ledger = ns.Ledger

local MAX_ENTRIES = 500

function Ledger.Record(player, orderID, copper, gems, now)
    if not copper or copper == 0 then return end

    ns.db.ledger.entries = ns.db.ledger.entries or {}
    table.insert(ns.db.ledger.entries, 1, {
        at = now, player = player, orderID = orderID, copper = copper, gems = gems,
    })
    for i = #ns.db.ledger.entries, MAX_ENTRIES + 1, -1 do
        table.remove(ns.db.ledger.entries, i)
    end

    ns.db.ledger.allTimeCopper = (ns.db.ledger.allTimeCopper or 0) + copper

    local count = 0
    for _, q in pairs(gems or {}) do count = count + q end
    ns.db.ledger.allTimeGems = (ns.db.ledger.allTimeGems or 0) + count

    local st = ns.Players.Get(ns.db, player)
    st.lifetimeCopper = (st.lifetimeCopper or 0) + copper
    st.lifetimeOrders = (st.lifetimeOrders or 0) + 1
end

-- Pure. Sums entries newer than `since`.
function Ledger.SumSince(entries, since)
    local copper, gems, n = 0, 0, 0
    for _, e in ipairs(entries or {}) do
        if (e.at or 0) >= since then
            copper = copper + (e.copper or 0)
            n = n + 1
            for _, q in pairs(e.gems or {}) do gems = gems + q end
        end
    end
    return copper, gems, n
end

function Ledger.Money(copper)
    if GetCoinTextureString then return GetCoinTextureString(copper or 0) end
    return string.format("%dg", math.floor((copper or 0) / 10000))
end

function Ledger.TopCustomers(limit)
    local list = {}
    for name, st in pairs(ns.db.players) do
        if (st.lifetimeCopper or 0) > 0 then
            list[#list + 1] = { name = name, copper = st.lifetimeCopper,
                orders = st.lifetimeOrders or 0 }
        end
    end
    table.sort(list, function(a, b) return a.copper > b.copper end)
    while #list > (limit or 10) do table.remove(list) end
    return list
end

function Ledger.Report()
    local L = ns.db.ledger
    local now = GetServerTime and GetServerTime() or time()
    local dayCopper, dayGems = Ledger.SumSince(L.entries, now - 86400)
    local weekCopper = Ledger.SumSince(L.entries, now - 604800)

    ns.Print("income:")
    ns.Print(string.format("  all time  %s over %d gems",
        Ledger.Money(L.allTimeCopper or 0), L.allTimeGems or 0))
    ns.Print(string.format("  last 24h  %s over %d gems", Ledger.Money(dayCopper), dayGems))
    ns.Print(string.format("  last 7d   %s", Ledger.Money(weekCopper)))

    local avg = (L.allTimeGems or 0) > 0
        and math.floor((L.allTimeCopper or 0) / L.allTimeGems) or 0
    ns.Print("  per gem   " .. Ledger.Money(avg))

    local top = Ledger.TopCustomers(5)
    if #top > 0 then
        ns.Print("top customers:")
        for _, c in ipairs(top) do
            ns.Print(string.format("  %s  %s over %d orders",
                c.name, Ledger.Money(c.copper), c.orders))
        end
    end
end
