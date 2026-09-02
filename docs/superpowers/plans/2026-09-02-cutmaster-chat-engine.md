# CutMaster Chat Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the headless chat engine for CutMaster: scan the Jewelcrafting book at runtime, auto-invite genuine customers from Trade chat while rejecting competing jewelcrafters, and bark rotating gem links on a timer.

**Architecture:** A WoW addon namespace shared across small single-responsibility files. The risky logic (normalization, matching, classification, bark fitting) lives in pure modules that take plain tables and call no WoW API, so they are driven by an in-game fixture harness via `/cm test`. Impure adapters (scanner, inviter, event wiring) are thin and wrap the pure core.

**Tech Stack:** Lua 5.1 as shipped in WoW TBC Anniversary client (Interface 20505). No external libraries in this plan. No build step. Files load in `.toc` order.

**Spec:** `docs/superpowers/specs/2026-09-02-cutmaster-design.md`

## Global Constraints

- Target client: WoW TBC Anniversary, `## Interface: 20505` (also accepts 20506).
- Lua 5.1 only. No `goto`, no bitwise operators, no integer division operator. `unpack` is global, not `table.unpack`.
- Saved variables: `SavedVariablesPerCharacter: CutMasterDB`. Never use account-wide saved variables.
- Addon folder is `Interface/AddOns/CutMaster/`. All paths in this plan are relative to that folder.
- Pure modules (`Util`, `Matcher`, `Classifier`, `Barker.Fit`, `Players.Observe`) MUST NOT call any WoW API function. This is what makes them testable. A WoW API call in a pure module is a review rejection.
- Chat output is prefixed `|cff33ff99CutMaster|r: ` via `ns.Print`. Never call bare `print`.
- Trade chat hard cap is 255 characters per `SendChatMessage` call.
- Every task ends with a commit. Commit messages use Conventional Commits (`feat:`, `test:`, `fix:`).
- Tests run in game with `/cm test` after `/reload`. There is no offline Lua interpreter on this machine.
- No em dashes in any user-facing string.

---

## File Structure

| File | Responsibility |
|---|---|
| `CutMaster.toc` | Manifest and load order |
| `Core.lua` | Namespace, `ns.Print`, defaults table, saved-var init, event frame, slash router |
| `Util.lua` | Pure text helpers: escape stripping, normalization, phrase matching, item ID extraction |
| `Tests.lua` | Fixture harness, assertions, `/cm test` runner |
| `Scanner.lua` | Tradeskill window to recipe book, including reagents. Pure `MergeBook` |
| `Matcher.lua` | Pure. Index building, three-tier matching, quantity hints |
| `Players.lua` | Pure `Observe` for repeat-bark detection, plus player state accessors |
| `Classifier.lua` | Pure. Veto checks, weighted scoring, net verdict |
| `Log.lua` | Decision ring buffer, capped at 100 |
| `Inviter.lua` | Impure. Guarded invite, cooldown, whisper |
| `Barker.lua` | Pure `Fit`, plus impure ticker and channel resolution |
| `Events.lua` | Impure. `CHAT_MSG_CHANNEL` wiring that joins the modules |

Load order in the `.toc` matters: `Core` first (creates the namespace), then `Util`, then pure modules, then impure ones, then `Events`, then `Tests` last so it can reference everything.

---

### Task 1: Addon skeleton and test harness

The harness comes first because every later task is TDD'd through it. Setup, manifest, and namespace fold into this task since nothing is testable without them.

**Files:**
- Create: `CutMaster.toc`
- Create: `Core.lua`
- Create: `Util.lua`
- Create: `Tests.lua`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `ns.Print(msg)` prints a prefixed line to the default chat frame
  - `ns.Tests.Case(name, fn)` registers a fixture
  - `ns.Tests.Eq(actual, expected, label)` asserts equality, throws on mismatch
  - `ns.Tests.Run()` runs all cases, prints pass/fail per failure and a summary
  - `ns.Util.Trim(s)` returns `s` with leading and trailing whitespace removed

- [ ] **Step 1: Write the failing test**

Create `Tests.lua`:

```lua
local addonName, ns = ...

ns.Tests = ns.Tests or {}
local T = ns.Tests
T.cases = {}

function T.Case(name, fn)
    T.cases[#T.cases + 1] = { name = name, fn = fn }
end

function T.Eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected [%s], got [%s]",
            tostring(label or "value"), tostring(expected), tostring(actual)), 2)
    end
end

function T.Run()
    local pass, fail = 0, 0
    for _, c in ipairs(T.cases) do
        local ok, err = pcall(c.fn)
        if ok then
            pass = pass + 1
        else
            fail = fail + 1
            ns.Print("|cffff4444FAIL|r " .. c.name .. " => " .. tostring(err))
        end
    end
    ns.Print(string.format("Tests: |cff44ff44%d passed|r, %s%d failed|r",
        pass, fail > 0 and "|cffff4444" or "|cff44ff44", fail))
    return pass, fail
end

T.Case("Util.Trim strips surrounding whitespace", function()
    T.Eq(ns.Util.Trim("  bold ruby  "), "bold ruby", "trim")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Create `CutMaster.toc`:

```
## Interface: 20505
## Title: CutMaster
## Notes: Jewelcrafting business assistant: book scanning, trade chat auto-invite, and barking.
## Author: Dezedin
## Version: 0.1.0
## SavedVariablesPerCharacter: CutMasterDB

Core.lua
Util.lua
Tests.lua
```

Create `Core.lua` with the namespace and slash router but NO `Util.Trim` yet:

```lua
local addonName, ns = ...

ns.Util = ns.Util or {}

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CutMaster|r: " .. tostring(msg))
end

local function HandleSlash(input)
    local cmd = ns.Util.Trim((input or ""):lower())
    if cmd == "test" then
        ns.Tests.Run()
    else
        ns.Print("Commands: /cm test")
    end
end

SLASH_CUTMASTER1 = "/cm"
SLASH_CUTMASTER2 = "/cutmaster"
SlashCmdList["CUTMASTER"] = HandleSlash
```

Create an empty `Util.lua`:

```lua
local addonName, ns = ...
ns.Util = ns.Util or {}
```

In game: `/reload`, then run `/cm test`

Expected: a Lua error, or `FAIL Util.Trim strips surrounding whitespace => attempt to call field 'Trim' (a nil value)`. The failure must be observed before proceeding.

- [ ] **Step 3: Write minimal implementation**

Replace `Util.lua`:

```lua
local addonName, ns = ...

ns.Util = ns.Util or {}
local Util = ns.Util

function Util.Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `CutMaster: Tests: 1 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add CutMaster.toc Core.lua Util.lua Tests.lua
git commit -m "feat: addon skeleton with in-game test harness"
```

---

### Task 2: Text normalization and link extraction

**Files:**
- Modify: `Util.lua`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: `ns.Util.Trim`
- Produces:
  - `ns.Util.StripEscapes(s)` returns `s` with WoW color, hyperlink, texture and atlas escapes removed, keeping hyperlink display text
  - `ns.Util.Normalize(s)` returns a lowercase, punctuation-stripped, single-spaced string
  - `ns.Util.ExtractItemIDs(raw)` returns an array of numeric item IDs found in `|Hitem:` links
  - `ns.Util.HasPhrase(norm, phrase)` returns true when `phrase` appears in `norm` on word boundaries
  - `ns.Util.EscapePattern(s)` returns `s` with Lua pattern magic characters escaped
  - `ns.Util.Tokenize(norm)` returns an array of whitespace-separated tokens

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
local RUBY_LINK = "|cffa335ee|Hitem:24033:0:0:0:0:0:0:0|h[Bold Living Ruby]|h|r"

T.Case("StripEscapes keeps link display text", function()
    T.Eq(ns.Util.StripEscapes(RUBY_LINK), "[Bold Living Ruby]", "stripped")
end)

T.Case("Normalize lowercases and strips punctuation", function()
    T.Eq(ns.Util.Normalize("WTB  Bold Living Ruby!!  "), "wtb bold living ruby", "normalized")
end)

T.Case("Normalize handles a link the same as plain text", function()
    T.Eq(ns.Util.Normalize("WTB " .. RUBY_LINK), "wtb bold living ruby", "normalized link")
end)

T.Case("ExtractItemIDs pulls every item id", function()
    local ids = ns.Util.ExtractItemIDs(RUBY_LINK .. " and " .. RUBY_LINK:gsub("24033", "24028"))
    T.Eq(#ids, 2, "count")
    T.Eq(ids[1], 24033, "first")
    T.Eq(ids[2], 24028, "second")
end)

T.Case("ExtractItemIDs returns empty for plain text", function()
    T.Eq(#ns.Util.ExtractItemIDs("wtb bold living ruby"), 0, "count")
end)

T.Case("HasPhrase respects word boundaries", function()
    T.Eq(ns.Util.HasPhrase("jc lfw all cuts", "lfw"), true, "lfw present")
    T.Eq(ns.Util.HasPhrase("lfwork available", "lfw"), false, "lfw not inside lfwork")
    T.Eq(ns.Util.HasPhrase("who can cut this", "can cut"), true, "multi word")
end)

T.Case("Tokenize splits on whitespace", function()
    local t = ns.Util.Tokenize("wtb bold living ruby")
    T.Eq(#t, 4, "count")
    T.Eq(t[2], "bold", "second token")
end)
```

- [ ] **Step 2: Run test to verify it fails**

In game: `/reload`, then `/cm test`

Expected: 6 failures, each `attempt to call field ... (a nil value)`. The Trim case still passes.

- [ ] **Step 3: Write minimal implementation**

Append to `Util.lua`:

```lua
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
```

Add `Util.lua` is already in the `.toc`. No manifest change needed.

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 7 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add Util.lua Tests.lua
git commit -m "feat: text normalization and item link extraction"
```

---

### Task 3: Defaults and saved variable initialization

**Files:**
- Modify: `Core.lua`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: `ns.Util.Trim`
- Produces:
  - `ns.Defaults` a table matching spec section 6, minus the order and ledger keys which belong to plan 3
  - `ns.DeepCopy(t)` returns a recursive copy of a plain table
  - `ns.ApplyDefaults(target, defaults)` fills missing keys in `target` recursively and returns `target`
  - `CutMasterDB` populated on `ADDON_LOADED`, with `ns.db` pointing at it

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
T.Case("ApplyDefaults fills missing nested keys", function()
    local defaults = { a = 1, nested = { x = 10, y = 20 } }
    local target = { nested = { x = 99 } }
    ns.ApplyDefaults(target, defaults)
    T.Eq(target.a, 1, "top level filled")
    T.Eq(target.nested.x, 99, "existing value preserved")
    T.Eq(target.nested.y, 20, "nested value filled")
end)

T.Case("ApplyDefaults does not share table references", function()
    local defaults = { nested = { x = 1 } }
    local a, b = {}, {}
    ns.ApplyDefaults(a, defaults)
    ns.ApplyDefaults(b, defaults)
    a.nested.x = 42
    T.Eq(b.nested.x, 1, "b unaffected")
    T.Eq(defaults.nested.x, 1, "defaults unaffected")
end)

T.Case("Defaults carry the veto and weight tables", function()
    T.Eq(type(ns.Defaults.settings.filter.vetoWords), "table", "vetoWords")
    T.Eq(ns.Defaults.settings.filter.netThreshold, 3, "netThreshold")
    T.Eq(ns.Defaults.settings.bark.intervalSec, 180, "interval")
end)
```

- [ ] **Step 2: Run test to verify it fails**

In game: `/reload`, then `/cm test`

Expected: 3 failures referencing `ns.ApplyDefaults` and `ns.Defaults` being nil.

- [ ] **Step 3: Write minimal implementation**

Append to `Core.lua`, above the slash router:

```lua
function ns.DeepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = ns.DeepCopy(v)
    end
    return out
end

function ns.ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            ns.ApplyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end

ns.Defaults = {
    version = 1,
    book = {},
    bookScannedAt = 0,
    bookPartial = false,
    players = {},
    log = {},
    settings = {
        bark = {
            enabled = false,
            intervalSec = 180,
            perBark = 4,
            template = "WTS JC cuts: {gems} and more! /w me",
            cursor = 1,
            onlyInCity = true,
            pauseCombat = true,
            pauseInstance = true,
        },
        invite = {
            enabled = true,
            maxParty = 5,
            playerCooldownSec = 600,
            whisper = {
                enabled = true,
                template = "Invited you for {gem}, accept and trade me the mats + tip!",
                cooldownSec = 600,
            },
        },
        filter = {
            requireBuyerSignal = true,
            netThreshold = 3,
            repeatWindowSec = 600,
            vetoWords = {
                "lfw", "jc lfw", "lf work", "looking for work",
                "wts", "selling", "will cut", "i cut", "cutting for",
            },
            sellerWords = {
                ["all cuts"] = 3, ["any cut"] = 2, ["full book"] = 3,
                ["most cuts"] = 3, ["every cut"] = 3, ["mats tip"] = 2,
                ["free cuts"] = 2, ["tips appreciated"] = 2, ["no charge"] = 2,
            },
            buyerWords = {
                ["wtb"] = 3, ["want to buy"] = 3, ["buying"] = 2, ["need"] = 2,
                ["anyone cut"] = 3, ["who can cut"] = 3, ["any jc"] = 2,
                ["lfjc"] = 3, ["lf jc"] = 3, ["have mats"] = 2, ["got mats"] = 2,
                ["have the mats"] = 2, ["will tip"] = 2, ["paying"] = 2, ["pay for"] = 2,
            },
            canCutGuards = { "who", "anyone", "any1", "anybody", "someone", "jc" },
            weights = {
                manyLinks = 3, designLink = 4, repeatBark = 5, shapeMatch = 2, canCut = 4,
            },
        },
        debug = false,
    },
}
```

Note on `mats tip`: normalization strips the `+` from `mats + tip`, so the stored phrase is `mats tip`. This is deliberate and matches what `Util.Normalize` produces.

Replace the slash router section of `Core.lua` with a version that initializes the database:

```lua
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        CutMasterDB = CutMasterDB or {}
        ns.ApplyDefaults(CutMasterDB, ns.Defaults)
        ns.db = CutMasterDB
        ns.Print("loaded. /cm help for commands.")
    end
end)
ns.frame = frame

local function HandleSlash(input)
    local cmd = ns.Util.Trim((input or ""):lower())
    if cmd == "test" then
        ns.Tests.Run()
    else
        ns.Print("Commands: /cm test")
    end
end

SLASH_CUTMASTER1 = "/cm"
SLASH_CUTMASTER2 = "/cutmaster"
SlashCmdList["CUTMASTER"] = HandleSlash
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 10 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add Core.lua Tests.lua
git commit -m "feat: defaults table and saved variable initialization"
```

---

### Task 4: Book merge logic

Merge is separated from scanning because merge is pure and carries the requirement that user settings survive a rescan. Scanning itself is impure and covered in Task 5.

**Files:**
- Create: `Scanner.lua`
- Modify: `CutMaster.toc`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `ns.Scanner.MergeBook(oldBook, scanned)` returns `newBook, addedCount`. `scanned` is an array of `{ itemID, name, link, header, classID, reagents }`. Preserves `advertise`, `match`, `aliases` from `oldBook`; defaults them to `true, true, {}` for new entries; marks entries absent from `scanned` as `stale = true` without deleting them.

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
local function scannedEntry(itemID, name, header)
    return {
        itemID = itemID, name = name, header = header or "Red",
        link = "|cffa335ee|Hitem:" .. itemID .. ":0:0:0:0:0:0:0|h[" .. name .. "]|h|r",
        classID = 3, reagents = { [23436] = 1 },
    }
end

T.Case("MergeBook adds new entries with defaults on", function()
    local book, added = ns.Scanner.MergeBook({}, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(added, 1, "added count")
    T.Eq(book[24033].name, "Bold Living Ruby", "name")
    T.Eq(book[24033].advertise, true, "advertise default")
    T.Eq(book[24033].match, true, "match default")
    T.Eq(type(book[24033].aliases), "table", "aliases default")
    T.Eq(book[24033].reagents[23436], 1, "reagents captured")
end)

T.Case("MergeBook preserves user settings across a rescan", function()
    local old = { [24033] = {
        itemID = 24033, name = "Bold Living Ruby", advertise = false,
        match = false, aliases = { "bold ruby" },
    } }
    local book, added = ns.Scanner.MergeBook(old, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(added, 0, "nothing new")
    T.Eq(book[24033].advertise, false, "advertise preserved")
    T.Eq(book[24033].match, false, "match preserved")
    T.Eq(book[24033].aliases[1], "bold ruby", "aliases preserved")
end)

T.Case("MergeBook flags missing entries stale without deleting", function()
    local old = { [24028] = { itemID = 24028, name = "Solid Star of Elune", advertise = true } }
    local book = ns.Scanner.MergeBook(old, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(book[24028] ~= nil, true, "kept")
    T.Eq(book[24028].stale, true, "flagged stale")
    T.Eq(book[24033].stale, nil, "present entry not stale")
end)

T.Case("MergeBook clears stale when a recipe returns", function()
    local old = { [24033] = { itemID = 24033, name = "Bold Living Ruby", stale = true } }
    local book = ns.Scanner.MergeBook(old, { scannedEntry(24033, "Bold Living Ruby") })
    T.Eq(book[24033].stale, nil, "stale cleared")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `Scanner.lua` to `CutMaster.toc` after `Util.lua`:

```
## Interface: 20505
## Title: CutMaster
## Notes: Jewelcrafting business assistant: book scanning, trade chat auto-invite, and barking.
## Author: Dezedin
## Version: 0.1.0
## SavedVariablesPerCharacter: CutMasterDB

Core.lua
Util.lua
Scanner.lua
Tests.lua
```

Create `Scanner.lua` as a stub:

```lua
local addonName, ns = ...
ns.Scanner = ns.Scanner or {}
```

In game: `/reload`, then `/cm test`

Expected: 4 failures, `attempt to call field 'MergeBook' (a nil value)`.

- [ ] **Step 3: Write minimal implementation**

Replace `Scanner.lua`:

```lua
local addonName, ns = ...

ns.Scanner = ns.Scanner or {}
local Scanner = ns.Scanner

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
            prev.stale = true
            newBook[itemID] = prev
        end
    end

    return newBook, added
end
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 14 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add Scanner.lua CutMaster.toc Tests.lua
git commit -m "feat: book merge preserving user settings across rescans"
```

---

### Task 5: Tradeskill scanner

This task is impure and cannot be unit tested. It ends with a manual verification step in game instead of an automated one.

**Files:**
- Modify: `Scanner.lua`
- Modify: `Core.lua`

**Interfaces:**
- Consumes: `ns.Scanner.MergeBook`, `ns.Print`, `ns.db`
- Produces:
  - `ns.Scanner.IsJewelcrafting()` returns true when the open tradeskill window is Jewelcrafting
  - `ns.Scanner.Scan(opts)` scans the open window and writes `ns.db.book`. `opts.silent` suppresses the summary print. Returns `added, total, failedCount`.
  - `ns.Scanner.initiatedByUs` boolean flag, set by the UI in plan 2, read here to decide whether to close the window

- [ ] **Step 1: Write the scan implementation**

Append to `Scanner.lua`:

```lua
local JEWELCRAFTING = "Jewelcrafting"

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
                local name, _, _, _, _, _, _, _, _, _, _, classID = GetItemInfo(link)
                rows[#rows + 1] = {
                    itemID = itemID,
                    name = name or skillName,
                    link = link,
                    header = header or "Other",
                    classID = classID,
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
        local book, added = ns.Scanner.MergeBook(ns.db.book, finalRows)
        ns.db.book = book
        ns.db.bookScannedAt = GetServerTime and GetServerTime() or time()
        ns.db.bookPartial = #finalFailed > 0

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
```

- [ ] **Step 2: Wire the event and slash command**

In `Core.lua`, register `TRADE_SKILL_SHOW` and `TRADE_SKILL_CLOSE` on the existing frame, and extend the slash router. Replace the `SetScript("OnEvent", ...)` block and `HandleSlash` with:

```lua
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_CLOSE")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        CutMasterDB = CutMasterDB or {}
        ns.ApplyDefaults(CutMasterDB, ns.Defaults)
        ns.db = CutMasterDB
        ns.Print("loaded. /cm help for commands.")
    elseif event == "TRADE_SKILL_SHOW" then
        C_Timer.After(0.2, function()
            if ns.Scanner.IsJewelcrafting() then
                ns.Scanner.Scan({ silent = not ns.Scanner.initiatedByUs })
            end
        end)
    elseif event == "TRADE_SKILL_CLOSE" then
        ns.Scanner.initiatedByUs = false
    end
end)

local function HandleSlash(input)
    local cmd = ns.Util.Trim((input or ""):lower())
    if cmd == "test" then
        ns.Tests.Run()
    elseif cmd == "scan" then
        ns.Scanner.Scan()
    elseif cmd == "book" then
        local n, gems = 0, 0
        for _, e in pairs(ns.db.book) do
            if not e.stale then
                n = n + 1
                if e.classID == 3 then gems = gems + 1 end
            end
        end
        ns.Print(string.format("book holds %d recipes (%d gems).", n, gems))
    else
        ns.Print("Commands: /cm scan, /cm book, /cm test")
    end
end
```

The `C_Timer.After(0.2, ...)` delay on `TRADE_SKILL_SHOW` exists because `GetNumTradeSkills` returns 0 for a frame or two immediately after the event fires.

- [ ] **Step 3: Verify manually in game**

1. `/reload`
2. Open Jewelcrafting. Nothing should print, because the auto-scan is silent.
3. Run `/cm book`. Expected: a count matching roughly the number of recipes you know.
4. Close Jewelcrafting, run `/cm scan`. Expected: `open your Jewelcrafting window first, then run /cm scan.`
5. Open Jewelcrafting, set the subclass filter to a single color and tick "Have Materials", then run `/cm scan`. Expected: the reported recipe count matches the full book, not the filtered view. This is the filter-clearing requirement from spec section 7 step 2.
6. Run `/cm scan` twice in a row. Expected: the second reports `0 new`.

Record the recipe count you observed. It is the baseline for later tasks.

- [ ] **Step 4: Commit**

```bash
git add Scanner.lua Core.lua
git commit -m "feat: tradeskill scanner with filter clearing and reagent capture"
```

---

### Task 6: Matcher

**Files:**
- Create: `Matcher.lua`
- Modify: `CutMaster.toc`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: `ns.Util.Normalize`, `ns.Util.ExtractItemIDs`, `ns.Util.HasPhrase`, `ns.Util.Tokenize`, `ns.Util.EscapePattern`
- Produces:
  - `ns.Matcher.BuildIndex(book)` returns `{ byID = {[itemID]=true}, names = {{itemID, name}}, aliases = {{itemID, alias}}, loose = {{itemID, prefix, bases}} }`, including only entries where `match` is true and `stale` is falsy
  - `ns.Matcher.QtyHint(norm, phrase)` returns a number or nil
  - `ns.Matcher.Match(raw, norm, index)` returns an array of `{ itemID, tier, qtyHint }` where `tier` is `"link"`, `"name"`, `"alias"` or `"loose"`, deduplicated by itemID, most confident tier winning

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
local function fixtureBook()
    return {
        [24033] = { itemID = 24033, name = "Bold Living Ruby", match = true, aliases = {} },
        [24048] = { itemID = 24048, name = "Runed Living Ruby", match = true, aliases = {} },
        [24028] = { itemID = 24028, name = "Solid Star of Elune", match = true, aliases = {} },
        [23096] = { itemID = 23096, name = "Great Golden Draenite", match = true, aliases = {} },
        [99999] = { itemID = 99999, name = "Hidden Cut Gem", match = false, aliases = {} },
    }
end

local function matchIDs(text, book)
    local index = ns.Matcher.BuildIndex(book or fixtureBook())
    local hits = ns.Matcher.Match(text, ns.Util.Normalize(text), index)
    local ids = {}
    for _, h in ipairs(hits) do ids[h.itemID] = h.tier end
    return ids, hits
end

T.Case("Matcher hits an item link exactly", function()
    local ids = matchIDs("wtb " .. RUBY_LINK)
    T.Eq(ids[24033], "link", "link tier")
end)

T.Case("Matcher hits a full plain text name", function()
    local ids = matchIDs("wtb bold living ruby please")
    T.Eq(ids[24033], "name", "name tier")
end)

T.Case("Matcher hits loose shorthand", function()
    T.Eq(matchIDs("wtb bold ruby")[24033], "loose", "bold ruby")
    T.Eq(matchIDs("need a runed ruby")[24048], "loose", "runed ruby")
    T.Eq(matchIDs("lf great draenite")[23096], "loose", "great draenite")
end)

T.Case("Matcher does not fire on a bare cut prefix", function()
    T.Eq(matchIDs("boldly going where no one has gone")[24033], nil, "boldly")
    T.Eq(matchIDs("bold move friend")[24033], nil, "bold alone")
end)

T.Case("Matcher ignores entries with match disabled", function()
    T.Eq(matchIDs("wtb hidden cut gem")[99999], nil, "excluded")
end)

T.Case("Matcher respects user aliases", function()
    local book = fixtureBook()
    book[24033].aliases = { "brb gem" }
    T.Eq(matchIDs("wtb brb gem", book)[24033], "alias", "alias tier")
end)

T.Case("Matcher prefers the link tier over loose", function()
    local ids = matchIDs("wtb bold ruby " .. RUBY_LINK)
    T.Eq(ids[24033], "link", "link wins")
end)

T.Case("QtyHint reads leading and trailing counts", function()
    T.Eq(ns.Matcher.QtyHint("wtb 3 bold living ruby", "bold living ruby"), 3, "leading digit")
    T.Eq(ns.Matcher.QtyHint("wtb 2x bold living ruby", "bold living ruby"), 2, "leading 2x")
    T.Eq(ns.Matcher.QtyHint("wtb bold living ruby x4", "bold living ruby"), 4, "trailing x4")
    T.Eq(ns.Matcher.QtyHint("wtb two bold living ruby", "bold living ruby"), 2, "word number")
    T.Eq(ns.Matcher.QtyHint("wtb bold living ruby", "bold living ruby"), nil, "no hint")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `Matcher.lua` to `CutMaster.toc` after `Scanner.lua`. Create the stub:

```lua
local addonName, ns = ...
ns.Matcher = ns.Matcher or {}
```

In game: `/reload`, then `/cm test`

Expected: 8 failures on `BuildIndex` and `QtyHint` being nil.

- [ ] **Step 3: Write minimal implementation**

Replace `Matcher.lua`:

```lua
local addonName, ns = ...

ns.Matcher = ns.Matcher or {}
local Matcher = ns.Matcher
local Util = ns.Util

local TIER_RANK = { link = 4, name = 3, alias = 2, loose = 1 }
local LOOSE_WINDOW = 3

local WORDNUM = {
    one = 1, two = 2, three = 3, four = 4, five = 5,
    six = 6, seven = 7, eight = 8, nine = 9, ten = 10,
}

function Matcher.BuildIndex(book)
    local index = { byID = {}, names = {}, aliases = {}, loose = {} }
    for itemID, e in pairs(book or {}) do
        if e.match and not e.stale then
            index.byID[itemID] = true

            local norm = Util.Normalize(e.name)
            index.names[#index.names + 1] = { itemID = itemID, name = norm }

            local toks = Util.Tokenize(norm)
            if #toks >= 2 then
                local bases = {}
                for i = 2, #toks do bases[#bases + 1] = toks[i] end
                index.loose[#index.loose + 1] = {
                    itemID = itemID, prefix = toks[1], bases = bases,
                }
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

function Matcher.Match(raw, norm, index)
    local best = {}

    local function add(itemID, tier, qtyHint)
        local prev = best[itemID]
        if prev and TIER_RANK[prev.tier] >= TIER_RANK[tier] then
            if qtyHint and not prev.qtyHint then prev.qtyHint = qtyHint end
            return
        end
        best[itemID] = { itemID = itemID, tier = tier, qtyHint = qtyHint or (prev and prev.qtyHint) }
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
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 22 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add Matcher.lua CutMaster.toc Tests.lua
git commit -m "feat: three tier gem matcher with quantity hints"
```

---

### Task 7: Repeat-bark detection

**Files:**
- Create: `Players.lua`
- Modify: `CutMaster.toc`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `ns.Players.Observe(state, norm, now, windowSec)` where `state` is the per-player table (or nil). Returns `newState, isRepeat`. Sets `flaggedSeller = true` on the second near-identical message inside `windowSec`.
  - `ns.Players.Similar(a, b)` returns true when two normalized strings are near-identical, defined as equal after removing digits

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
T.Case("Players.Similar ignores digit differences", function()
    T.Eq(ns.Players.Similar("wts jc cuts 5g", "wts jc cuts 7g"), true, "price change")
    T.Eq(ns.Players.Similar("wts jc cuts", "wtb bold ruby"), false, "different text")
end)

T.Case("Players.Observe flags a repeated ad inside the window", function()
    local msg = "wts jc cuts all cuts avail pst"
    local st, rep = ns.Players.Observe(nil, msg, 1000, 600)
    T.Eq(rep, false, "first sighting")
    T.Eq(st.flaggedSeller, nil, "not yet flagged")

    st, rep = ns.Players.Observe(st, msg, 1100, 600)
    T.Eq(rep, true, "repeat detected")
    T.Eq(st.flaggedSeller, true, "flagged")
end)

T.Case("Players.Observe does not flag outside the window", function()
    local msg = "wts jc cuts all cuts avail pst"
    local st = ns.Players.Observe(nil, msg, 1000, 600)
    local _, rep = ns.Players.Observe(st, msg, 2000, 600)
    T.Eq(rep, false, "too far apart")
end)

T.Case("Players.Observe does not flag differing messages", function()
    local st = ns.Players.Observe(nil, "wtb bold ruby", 1000, 600)
    local st2, rep = ns.Players.Observe(st, "wtb runed ruby too", 1100, 600)
    T.Eq(rep, false, "different message")
    T.Eq(st2.flaggedSeller, nil, "not flagged")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `Players.lua` to `CutMaster.toc` after `Matcher.lua`. Create the stub:

```lua
local addonName, ns = ...
ns.Players = ns.Players or {}
```

In game: `/reload`, then `/cm test`

Expected: 4 failures on `Similar` and `Observe` being nil.

- [ ] **Step 3: Write minimal implementation**

Replace `Players.lua`:

```lua
local addonName, ns = ...

ns.Players = ns.Players or {}
local Players = ns.Players

function Players.Similar(a, b)
    if not a or not b then return false end
    local ca = a:gsub("%d+", "")
    local cb = b:gsub("%d+", "")
    return ca == cb
end

function Players.Observe(state, norm, now, windowSec)
    state = state or {}
    local isRepeat = false

    if state.lastMsg and state.lastMsgAt
        and (now - state.lastMsgAt) <= windowSec
        and Players.Similar(state.lastMsg, norm) then
        isRepeat = true
        state.repeats = (state.repeats or 0) + 1
        state.flaggedSeller = true
    end

    state.lastMsg = norm
    state.lastMsgAt = now
    return state, isRepeat
end

function Players.Get(db, name)
    db.players = db.players or {}
    db.players[name] = db.players[name] or {}
    return db.players[name]
end
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 26 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add Players.lua CutMaster.toc Tests.lua
git commit -m "feat: repeat bark detection for competitor flagging"
```

---

### Task 8: Classifier

The heart of the addon. Implements spec sections 9.1 through 9.4.

**Files:**
- Create: `Classifier.lua`
- Modify: `CutMaster.toc`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: `ns.Util.HasPhrase`, `ns.Util.Tokenize`
- Produces:
  - `ns.Classifier.Evaluate(ctx)` returns a result table `{ verdict, reason, sellerScore, sellerHits, buyerScore, buyerHits, netScore }` where `verdict` is `"invite"`, `"vetoed"` or `"lowscore"`.
  - `ctx` fields: `norm` (string), `raw` (string), `matched` (array from Matcher), `linkCount` (number), `hasDesignLink` (boolean), `isRepeat` (boolean), `playerState` (table or nil), `blocked` (string or nil, a caller-supplied hard block reason such as `"cooldown"` or `"group full"`), `filter` (the `settings.filter` table)

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
local function classify(text, over)
    over = over or {}
    local book = over.book or fixtureBook()
    local index = ns.Matcher.BuildIndex(book)
    local norm = ns.Util.Normalize(text)
    local matched = ns.Matcher.Match(text, norm, index)
    local ctx = {
        norm = norm,
        raw = text,
        matched = matched,
        linkCount = #ns.Util.ExtractItemIDs(text),
        hasDesignLink = over.hasDesignLink or false,
        isRepeat = over.isRepeat or false,
        playerState = over.playerState,
        blocked = over.blocked,
        filter = over.filter or ns.DeepCopy(ns.Defaults.settings.filter),
    }
    return ns.Classifier.Evaluate(ctx)
end

T.Case("Classifier vetoes JC LFW", function()
    local r = classify("JC LFW all cuts pst " .. RUBY_LINK)
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "lfw", "reason")
end)

T.Case("Classifier vetoes a WTS advertisement", function()
    local r = classify("WTS " .. RUBY_LINK .. " 5g")
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "wts", "reason")
end)

T.Case("Classifier vetoes LF work", function()
    T.Eq(classify("LF work jewelcrafter all cuts avail " .. RUBY_LINK).verdict, "vetoed", "verdict")
end)

T.Case("Classifier blocks can cut advertisements by score", function()
    local r = classify("Can cut any cut, mats + tip " .. RUBY_LINK)
    T.Eq(r.verdict, "lowscore", "not a veto")
    T.Eq(r.sellerScore >= 3, true, "seller score at or above threshold")
end)

T.Case("Classifier invites when can cut is guarded by anyone", function()
    local r = classify("anyone who can cut " .. RUBY_LINK .. "? have mats")
    T.Eq(r.verdict, "invite", "verdict")
end)

T.Case("Classifier invites a plain WTB", function()
    T.Eq(classify("WTB bold ruby have mats").verdict, "invite", "verdict")
end)

T.Case("Classifier invites a question form request", function()
    T.Eq(classify("any jc able to cut " .. RUBY_LINK .. "?").verdict, "invite", "verdict")
end)

T.Case("Classifier invites LF plus will tip", function()
    T.Eq(classify("LF " .. RUBY_LINK .. " will tip").verdict, "invite", "verdict")
end)

T.Case("Classifier withholds an invite for a bare link", function()
    local r = classify(RUBY_LINK)
    T.Eq(r.verdict, "lowscore", "verdict")
    T.Eq(r.buyerScore, 0, "no buyer signal")
end)

T.Case("Classifier invites a bare link when requireBuyerSignal is off", function()
    local filter = ns.DeepCopy(ns.Defaults.settings.filter)
    filter.requireBuyerSignal = false
    T.Eq(classify(RUBY_LINK, { filter = filter }).verdict, "invite", "verdict")
end)

T.Case("Classifier scores manyLinks against three or more links", function()
    local three = RUBY_LINK .. " " .. RUBY_LINK:gsub("24033", "24048")
        .. " " .. RUBY_LINK:gsub("24033", "23096")
    local r = classify("gems available " .. three)
    T.Eq(r.sellerHits.manyLinks, 3, "manyLinks weight applied")
end)

T.Case("Classifier scores a design link heavily", function()
    local r = classify("check these out " .. RUBY_LINK, { hasDesignLink = true })
    T.Eq(r.sellerHits.designLink, 4, "designLink weight applied")
end)

T.Case("Classifier applies the repeat bark weight", function()
    local r = classify("gems here " .. RUBY_LINK, { isRepeat = true })
    T.Eq(r.sellerHits.repeatBark, 5, "repeatBark weight applied")
end)

T.Case("Classifier vetoes a previously flagged seller", function()
    local r = classify("WTB bold ruby have mats", { playerState = { flaggedSeller = true } })
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "flagged seller", "reason")
end)

T.Case("Classifier honours a caller supplied block", function()
    local r = classify("WTB bold ruby have mats", { blocked = "cooldown" })
    T.Eq(r.verdict, "vetoed", "verdict")
    T.Eq(r.reason, "cooldown", "reason")
end)

T.Case("Classifier does not fire without a gem match", function()
    local r = classify("WTB a mount have gold")
    T.Eq(r.verdict, "lowscore", "verdict")
    T.Eq(r.reason, "no gem match", "reason")
end)

T.Case("Classifier does not match boldly as a gem", function()
    T.Eq(classify("boldly going where no one has gone before").reason, "no gem match", "reason")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `Classifier.lua` to `CutMaster.toc` after `Players.lua`. Create the stub:

```lua
local addonName, ns = ...
ns.Classifier = ns.Classifier or {}
```

In game: `/reload`, then `/cm test`

Expected: 17 failures on `Evaluate` being nil.

- [ ] **Step 3: Write minimal implementation**

Replace `Classifier.lua`:

```lua
local addonName, ns = ...

ns.Classifier = ns.Classifier or {}
local Classifier = ns.Classifier
local Util = ns.Util

local MANY_LINKS = 3

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

local function HasCanCut(norm)
    return Util.HasPhrase(norm, "can cut")
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

    if ctx.blocked then
        result.verdict = "vetoed"
        result.reason = ctx.blocked
        return result
    end

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

    if not ctx.matched or #ctx.matched == 0 then
        result.verdict = "lowscore"
        result.reason = "no gem match"
        return result
    end

    for phrase, weight in pairs(filter.sellerWords) do
        if Util.HasPhrase(ctx.norm, phrase) then seller(phrase, weight) end
    end

    if HasCanCut(ctx.norm) then
        if CanCutIsGuarded(ctx.norm, filter.canCutGuards) then
            buyer("can cut (guarded)", 3)
        else
            seller("canCut", filter.weights.canCut)
        end
    end

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

    if hasQuestion then buyer("question", 1) end

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
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 43 passed, 0 failed`

If `Classifier blocks can cut advertisements by score` fails, check that `Util.Normalize` turns `mats + tip` into `mats tip`, matching the `sellerWords` key set in Task 3.

- [ ] **Step 5: Commit**

```bash
git add Classifier.lua CutMaster.toc Tests.lua
git commit -m "feat: net scored buyer and seller classifier"
```

---

### Task 9: Decision log

**Files:**
- Create: `Log.lua`
- Modify: `CutMaster.toc`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `ns.Log.Push(log, entry)` prepends `entry` and truncates to 100, returns `log`
  - `ns.Log.Add(player, msg, matched, result, now)` writes to `ns.db.log`
  - `ns.Log.Recent(n)` returns the newest `n` entries
  - `ns.Log.Describe(entry)` returns a one-line human readable summary string

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
T.Case("Log.Push caps the buffer at 100 entries", function()
    local log = {}
    for i = 1, 120 do
        ns.Log.Push(log, { id = i })
    end
    T.Eq(#log, 100, "capped")
    T.Eq(log[1].id, 120, "newest first")
    T.Eq(log[100].id, 21, "oldest retained")
end)

T.Case("Log.Describe summarises a verdict", function()
    local line = ns.Log.Describe({
        player = "Bob", verdict = "vetoed", reason = "lfw",
        sellerScore = 0, buyerScore = 0, msg = "JC LFW",
    })
    T.Eq(line:find("Bob", 1, true) ~= nil, true, "names the player")
    T.Eq(line:find("lfw", 1, true) ~= nil, true, "gives the reason")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `Log.lua` to `CutMaster.toc` after `Classifier.lua`. Create the stub:

```lua
local addonName, ns = ...
ns.Log = ns.Log or {}
```

In game: `/reload`, then `/cm test`

Expected: 2 failures on `Push` and `Describe` being nil.

- [ ] **Step 3: Write minimal implementation**

Replace `Log.lua`:

```lua
local addonName, ns = ...

ns.Log = ns.Log or {}
local Log = ns.Log

local MAX_ENTRIES = 100

local VERDICT_COLOR = {
    invite = "|cff44ff44",
    vetoed = "|cffff4444",
    lowscore = "|cffffcc00",
}

function Log.Push(log, entry)
    table.insert(log, 1, entry)
    for i = #log, MAX_ENTRIES + 1, -1 do
        table.remove(log, i)
    end
    return log
end

function Log.Add(player, msg, matched, result, now)
    local ids = {}
    for _, h in ipairs(matched or {}) do ids[#ids + 1] = h.itemID end

    return Log.Push(ns.db.log, {
        at = now,
        player = player,
        msg = msg,
        matched = ids,
        verdict = result.verdict,
        reason = result.reason,
        sellerScore = result.sellerScore,
        sellerHits = result.sellerHits,
        buyerScore = result.buyerScore,
        buyerHits = result.buyerHits,
    })
end

function Log.Recent(n)
    local out = {}
    for i = 1, math.min(n, #ns.db.log) do
        out[i] = ns.db.log[i]
    end
    return out
end

function Log.Describe(entry)
    local color = VERDICT_COLOR[entry.verdict] or "|cffffffff"
    return string.format("%s%s|r %s (s%d/b%d, %s): %s",
        color, entry.verdict, entry.player or "?",
        entry.sellerScore or 0, entry.buyerScore or 0,
        entry.reason or "?", entry.msg or "")
end
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 45 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add Log.lua CutMaster.toc Tests.lua
git commit -m "feat: decision log ring buffer"
```

---

### Task 10: Inviter

Impure. Verified manually plus one pure eligibility test.

**Files:**
- Create: `Inviter.lua`
- Modify: `CutMaster.toc`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: `ns.Print`, `ns.db`
- Produces:
  - `ns.Inviter.BlockReason(playerState, now, groupSize, settings)` pure, returns a string reason or nil
  - `ns.Inviter.Invite(name, matched)` performs the invite and optional whisper, records `lastInviteAt`
  - `ns.Inviter.whisperCount` running session counter

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
T.Case("BlockReason reports the invite cooldown", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    local r = ns.Inviter.BlockReason({ lastInviteAt = 1000 }, 1100, 1, s)
    T.Eq(r, "cooldown", "reason")
end)

T.Case("BlockReason clears once the cooldown expires", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    T.Eq(ns.Inviter.BlockReason({ lastInviteAt = 1000 }, 2000, 1, s), nil, "cleared")
end)

T.Case("BlockReason reports a full group", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    T.Eq(ns.Inviter.BlockReason({}, 5000, 5, s), "group full", "reason")
end)

T.Case("BlockReason reports auto invite disabled", function()
    local s = ns.DeepCopy(ns.Defaults.settings.invite)
    s.enabled = false
    T.Eq(ns.Inviter.BlockReason({}, 5000, 1, s), "invites disabled", "reason")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `Inviter.lua` to `CutMaster.toc` after `Log.lua`. Create the stub:

```lua
local addonName, ns = ...
ns.Inviter = ns.Inviter or {}
```

In game: `/reload`, then `/cm test`

Expected: 4 failures on `BlockReason` being nil.

- [ ] **Step 3: Write minimal implementation**

Replace `Inviter.lua`:

```lua
local addonName, ns = ...

ns.Inviter = ns.Inviter or {}
local Inviter = ns.Inviter

Inviter.whisperCount = 0

local WHISPER_WARN_AT = 60
local WHISPER_DELAY = 1.5

function Inviter.BlockReason(playerState, now, groupSize, settings)
    if not settings.enabled then return "invites disabled" end
    if groupSize >= settings.maxParty then return "group full" end
    if playerState and playerState.lastInviteAt
        and (now - playerState.lastInviteAt) < settings.playerCooldownSec then
        return "cooldown"
    end
    return nil
end

local function DoInvite(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    elseif InviteUnit then
        InviteUnit(name)
    else
        ns.Print("|cffff4444no invite API available on this client.|r")
    end
end

function Inviter.Invite(name, matched)
    local short = name:gsub("%-.*", "")
    local settings = ns.db.settings.invite
    local now = GetServerTime and GetServerTime() or time()

    DoInvite(short)

    local state = ns.Players.Get(ns.db, short)
    state.lastInviteAt = now

    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.MAP_PING) end

    local gemLink = nil
    if matched and matched[1] then
        local entry = ns.db.book[matched[1].itemID]
        gemLink = entry and (entry.link or entry.name)
    end
    ns.Print(string.format("invited %s for %s", short, gemLink or "a cut"))

    if settings.whisper.enabled then
        local last = state.lastWhisperAt or 0
        if (now - last) >= settings.whisper.cooldownSec then
            state.lastWhisperAt = now
            C_Timer.After(WHISPER_DELAY, function()
                local text = settings.whisper.template
                    :gsub("{gem}", gemLink or "your cut")
                    :gsub("{player}", short)
                SendChatMessage(text, "WHISPER", nil, short)
                Inviter.whisperCount = Inviter.whisperCount + 1
                if Inviter.whisperCount == WHISPER_WARN_AT then
                    ns.Print("|cffff9900" .. WHISPER_WARN_AT ..
                        " whispers sent this session. Watch the game whisper throttle.|r")
                end
            end)
        end
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 49 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add Inviter.lua CutMaster.toc Tests.lua
git commit -m "feat: guarded auto invite with cooldown and whisper"
```

---

### Task 11: Chat event wiring

Joins Matcher, Players, Classifier, Log and Inviter into the live pipeline.

**Files:**
- Create: `Events.lua`
- Modify: `CutMaster.toc`
- Modify: `Core.lua`

**Interfaces:**
- Consumes: everything from tasks 6 through 10
- Produces:
  - `ns.Events.OnTradeMessage(text, author)` runs the full pipeline for one message and returns the classifier result. Callable directly, which is what makes it testable by hand.
  - `ns.Events.index` cached matcher index, rebuilt on scan

- [ ] **Step 1: Write the implementation**

Create `Events.lua`:

```lua
local addonName, ns = ...

ns.Events = ns.Events or {}
local Events = ns.Events

local DESIGN_PATTERNS = { "|Henchant:", "|Hspell:" }

local function HasDesignLink(raw)
    for _, p in ipairs(DESIGN_PATTERNS) do
        if raw:find(p, 1, true) then return true end
    end
    return raw:find("Design:", 1, true) ~= nil
end

function Events.RebuildIndex()
    Events.index = ns.Matcher.BuildIndex(ns.db.book)
    return Events.index
end

function Events.OnTradeMessage(text, author)
    if not ns.db then return end
    if not Events.index then Events.RebuildIndex() end

    local short = (author or ""):gsub("%-.*", "")
    if short == "" then return end

    local playerName = UnitName("player")
    local norm = ns.Util.Normalize(text)
    local now = GetServerTime and GetServerTime() or time()

    local state = ns.Players.Get(ns.db, short)
    local _, isRepeat = ns.Players.Observe(
        state, norm, now, ns.db.settings.filter.repeatWindowSec)

    local matched = ns.Matcher.Match(text, norm, Events.index)

    local blocked = nil
    if short == playerName then
        blocked = "self"
    elseif UnitInParty(short) or UnitInRaid(short) then
        blocked = "already grouped"
    else
        blocked = ns.Inviter.BlockReason(
            state, now, GetNumGroupMembers() or 0, ns.db.settings.invite)
    end

    local result = ns.Classifier.Evaluate({
        norm = norm,
        raw = text,
        matched = matched,
        linkCount = #ns.Util.ExtractItemIDs(text),
        hasDesignLink = HasDesignLink(text),
        isRepeat = isRepeat,
        playerState = state,
        blocked = blocked,
        filter = ns.db.settings.filter,
    })

    if result.reason ~= "no gem match" then
        ns.Log.Add(short, text, matched, result, now)
        if ns.db.settings.debug then
            ns.Print(ns.Log.Describe(ns.db.log[1]))
        end
    end

    if result.verdict == "invite" then
        ns.Inviter.Invite(short, matched)
    end

    return result
end
```

- [ ] **Step 2: Register the event and extend the slash router**

Add `Events.lua` to `CutMaster.toc` after `Inviter.lua` and before `Tests.lua`.

In `Core.lua`, register the chat event and route it. Add to the frame registration block:

```lua
frame:RegisterEvent("CHAT_MSG_CHANNEL")
```

Add to the `OnEvent` handler, before the closing `end`:

```lua
    elseif event == "CHAT_MSG_CHANNEL" then
        local text, author, _, _, _, _, _, _, channelName = ...
        if channelName and channelName:find("Trade", 1, true) then
            ns.Events.OnTradeMessage(text, author)
        end
```

The `OnEvent` function signature must change to accept varargs. Replace the opening line with:

```lua
frame:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...
```

After a scan completes, the matcher index is stale. In `Scanner.Scan`, inside `commit`, immediately after `ns.db.book = book`, add:

```lua
        if ns.Events then ns.Events.RebuildIndex() end
```

Replace `HandleSlash` in `Core.lua` with the full router:

```lua
local function HandleSlash(input)
    local raw = ns.Util.Trim(input or "")
    local cmd, rest = raw:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "test" then
        ns.Tests.Run()
    elseif cmd == "scan" then
        ns.Scanner.Scan()
    elseif cmd == "book" then
        local n, gems = 0, 0
        for _, e in pairs(ns.db.book) do
            if not e.stale then
                n = n + 1
                if e.classID == 3 then gems = gems + 1 end
            end
        end
        ns.Print(string.format("book holds %d recipes (%d gems).", n, gems))
    elseif cmd == "invite" then
        local s = ns.db.settings.invite
        s.enabled = not s.enabled
        ns.Print("auto invite " .. (s.enabled and "on" or "off"))
    elseif cmd == "log" then
        local entries = ns.Log.Recent(10)
        if #entries == 0 then
            ns.Print("log is empty.")
        end
        for i = #entries, 1, -1 do
            ns.Print(ns.Log.Describe(entries[i]))
        end
    elseif cmd == "debug" then
        ns.db.settings.debug = not ns.db.settings.debug
        ns.Print("debug " .. (ns.db.settings.debug and "on" or "off"))
    elseif cmd == "try" then
        local result = ns.Events.OnTradeMessage(rest, "TestDummy")
        if result then
            ns.Print(string.format("verdict %s (%s), seller %d buyer %d",
                result.verdict, result.reason, result.sellerScore or 0, result.buyerScore or 0))
        end
    else
        ns.Print("Commands: /cm scan, /cm book, /cm invite, /cm log, /cm debug, /cm try <message>, /cm test")
    end
end
```

`/cm try` runs a message through the live pipeline against your real book without waiting for someone to post it. This is the primary manual verification tool.

- [ ] **Step 3: Verify manually in game**

1. `/reload`, open Jewelcrafting to populate the book, close it.
2. `/cm try WTB bold living ruby have mats` (substitute a cut you actually know). Expected: `verdict invite`, and an invite is sent to a nonexistent player `TestDummy`, which the server rejects harmlessly.
3. `/cm try JC LFW all cuts pst`. Expected: `verdict vetoed (lfw)`.
4. `/cm try WTS bold living ruby 5g`. Expected: `verdict vetoed (wts)`.
5. `/cm try anyone who can cut bold living ruby? have mats`. Expected: `verdict invite`.
6. Run step 2 twice in a row. Expected: the second reports `verdict vetoed (cooldown)`.
7. `/cm log`. Expected: the last ten decisions with scores and reasons.
8. Stand in a capital city with Trade chat visible for a few minutes with `/cm debug` on. Confirm real messages are being scored and that no competing jewelcrafter gets invited.

- [ ] **Step 4: Commit**

```bash
git add Events.lua Core.lua Scanner.lua CutMaster.toc
git commit -m "feat: trade chat pipeline wiring matcher through inviter"
```

---

### Task 12: Barker

**Files:**
- Create: `Barker.lua`
- Modify: `CutMaster.toc`
- Modify: `Core.lua`
- Modify: `Tests.lua`

**Interfaces:**
- Consumes: `ns.db`, `ns.Print`
- Produces:
  - `ns.Barker.Fit(entries, cursor, template, maxLen, perBark)` pure, returns `msg, nextCursor, usedCount`. `entries` is an ordered array of `{ itemID, link }`. Returns nil when `entries` is empty or the template has no `{gems}`.
  - `ns.Barker.AdvertisedEntries()` returns the ordered array from `ns.db.book`
  - `ns.Barker.TradeChannel()` returns the numeric trade channel index or nil
  - `ns.Barker.Tick()` sends one bark if the guards allow
  - `ns.Barker.Start()` / `ns.Barker.Stop()` manage the ticker

- [ ] **Step 1: Write the failing test**

Append to `Tests.lua`:

```lua
local function barkEntries(n)
    local out = {}
    for i = 1, n do
        local id = 24000 + i
        out[i] = { itemID = id,
            link = "|cffa335ee|Hitem:" .. id .. ":0:0:0:0:0:0:0|h[Bold Living Ruby]|h|r" }
    end
    return out
end

T.Case("Barker.Fit stays within the 255 character cap", function()
    local msg = ns.Barker.Fit(barkEntries(40), 1, "WTS JC cuts: {gems} and more! /w me", 255, 4)
    T.Eq(msg ~= nil, true, "message built")
    T.Eq(#msg <= 255, true, "within cap, got " .. #msg)
end)

T.Case("Barker.Fit advances the cursor by the number used", function()
    local _, nextCursor, used = ns.Barker.Fit(
        barkEntries(40), 1, "WTS JC cuts: {gems} and more! /w me", 255, 4)
    T.Eq(used >= 2, true, "at least two links fit")
    T.Eq(nextCursor, 1 + used, "cursor advanced by used")
end)

T.Case("Barker.Fit wraps at the end of the list", function()
    local entries = barkEntries(5)
    local _, nextCursor, used = ns.Barker.Fit(
        entries, 4, "WTS JC cuts: {gems} and more! /w me", 255, 4)
    T.Eq(used > 0, true, "something was used")
    T.Eq(nextCursor <= #entries, true, "cursor wrapped into range, got " .. nextCursor)
end)

T.Case("Barker.Fit honours perBark", function()
    local _, _, used = ns.Barker.Fit(
        barkEntries(40), 1, "WTS JC cuts: {gems} and more! /w me", 255, 2)
    T.Eq(used, 2, "capped at perBark")
end)

T.Case("Barker.Fit rejects a template without the gems placeholder", function()
    T.Eq(ns.Barker.Fit(barkEntries(5), 1, "WTS JC cuts, no placeholder", 255, 4), nil, "rejected")
end)

T.Case("Barker.Fit returns nil for an empty list", function()
    T.Eq(ns.Barker.Fit({}, 1, "WTS JC cuts: {gems}", 255, 4), nil, "nil")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Add `Barker.lua` to `CutMaster.toc` after `Events.lua`. Create the stub:

```lua
local addonName, ns = ...
ns.Barker = ns.Barker or {}
```

In game: `/reload`, then `/cm test`

Expected: 6 failures on `Fit` being nil.

- [ ] **Step 3: Write minimal implementation**

Replace `Barker.lua`:

```lua
local addonName, ns = ...

ns.Barker = ns.Barker or {}
local Barker = ns.Barker

local MAX_LEN = 255

function Barker.Fit(entries, cursor, template, maxLen, perBark)
    if not entries or #entries == 0 then return nil end
    if not template or not template:find("{gems}", 1, true) then return nil end

    maxLen = maxLen or MAX_LEN
    cursor = cursor or 1
    if cursor < 1 or cursor > #entries then cursor = 1 end

    local shell = template:gsub("{gems}", "")
    local budget = maxLen - #shell

    local picked = {}
    local used = 0
    local idx = cursor
    local length = 0

    for _ = 1, math.min(perBark, #entries) do
        local link = entries[idx].link
        local addition = #link + (used > 0 and 1 or 0)
        if length + addition > budget then break end
        picked[#picked + 1] = link
        length = length + addition
        used = used + 1
        idx = idx + 1
        if idx > #entries then idx = 1 end
    end

    if used == 0 then return nil end

    local msg = template:gsub("{gems}", table.concat(picked, " "), 1)
    return msg, idx, used
end

function Barker.AdvertisedEntries()
    local list = {}
    for itemID, e in pairs(ns.db.book) do
        if e.advertise and not e.stale and e.link then
            list[#list + 1] = { itemID = itemID, link = e.link, header = e.header or "", name = e.name or "" }
        end
    end
    table.sort(list, function(a, b)
        if a.header ~= b.header then return a.header < b.header end
        return a.name < b.name
    end)
    return list
end

function Barker.TradeChannel()
    local channels = { GetChannelList() }
    for i = 1, #channels, 3 do
        local id, name = channels[i], channels[i + 1]
        if type(name) == "string" and name:find("Trade", 1, true) then
            return id
        end
    end
    return nil
end

function Barker.BlockReason()
    local s = ns.db.settings.bark
    if not s.enabled then return "disabled" end
    if s.pauseCombat and (InCombatLockdown() or UnitAffectingCombat("player")) then
        return "in combat"
    end
    if s.pauseInstance and IsInInstance() then return "in an instance" end
    if s.onlyInCity and not Barker.TradeChannel() then return "no trade channel" end
    return nil
end

function Barker.Tick(force)
    local s = ns.db.settings.bark

    if not force then
        local blocked = Barker.BlockReason()
        if blocked then return false, blocked end
    end

    local channel = Barker.TradeChannel()
    if not channel then return false, "no trade channel" end

    local entries = Barker.AdvertisedEntries()
    local msg, nextCursor, used = Barker.Fit(entries, s.cursor, s.template, MAX_LEN, s.perBark)
    if not msg then return false, "nothing to advertise" end

    SendChatMessage(msg, "CHANNEL", nil, channel)
    s.cursor = nextCursor
    return true, used
end

function Barker.Stop()
    if Barker.ticker then
        Barker.ticker:Cancel()
        Barker.ticker = nil
    end
end

function Barker.Start()
    Barker.Stop()
    local interval = ns.db.settings.bark.intervalSec
    Barker.ticker = C_Timer.NewTicker(interval, function() Barker.Tick() end)
end
```

Note the guard order in `Tick`: a blocked tick returns before `s.cursor` is written, which satisfies the spec requirement that skipped ticks do not advance the rotation.

- [ ] **Step 4: Add slash commands**

In `Core.lua`, add these branches to `HandleSlash` before the final `else`:

```lua
    elseif cmd == "bark" then
        local s = ns.db.settings.bark
        local secs = tonumber(rest)
        if secs then
            if secs < 30 then secs = 30 end
            if secs > 600 then secs = 600 end
            s.intervalSec = secs
            s.enabled = true
            ns.Barker.Start()
            ns.Print(string.format("barking every %d seconds.", secs))
        else
            s.enabled = not s.enabled
            if s.enabled then ns.Barker.Start() else ns.Barker.Stop() end
            ns.Print("barking " .. (s.enabled and "on" or "off"))
        end
    elseif cmd == "send" then
        local ok, info = ns.Barker.Tick(true)
        if not ok then ns.Print("bark skipped: " .. tostring(info)) end
```

In the `ADDON_LOADED` branch of the `OnEvent` handler, after `ns.db = CutMasterDB`, add:

```lua
        if ns.db.settings.bark.enabled then ns.Barker.Start() end
```

Update the fallback help line to:

```lua
        ns.Print("Commands: /cm scan, /cm book, /cm bark [seconds], /cm send, /cm invite, /cm log, /cm debug, /cm try <message>, /cm test")
```

- [ ] **Step 5: Run test to verify it passes**

In game: `/reload`, then `/cm test`

Expected: `Tests: 55 passed, 0 failed`

- [ ] **Step 6: Verify manually in game**

1. Stand outside a capital city. Run `/cm send`. Expected: `bark skipped: no trade channel`.
2. Enter a capital city. Run `/cm send`. Expected: a Trade chat message with 3 or 4 clickable gem links, under 255 characters.
3. Run `/cm send` repeatedly. Expected: different gems each time, wrapping back to the start after the list is exhausted.
4. Run `/cm bark 30`, wait, and confirm automatic barks fire. Then `/cm bark` to turn it off.
5. Enter combat and run `/cm send`. Expected: it still sends, because `force` is true. Wait for a scheduled tick during combat and confirm it is skipped instead.

- [ ] **Step 7: Commit**

```bash
git add Barker.lua Core.lua CutMaster.toc Tests.lua
git commit -m "feat: rotating gem link barker with city and combat guards"
```

---

### Task 13: README and disclaimer

**Files:**
- Create: `README.md`
- Modify: `CutMaster.toc`

**Interfaces:**
- Consumes: nothing
- Produces: user-facing documentation

- [ ] **Step 1: Write the README**

Create `README.md` documenting: what the addon does, installation, every slash command from Task 12's help line, how the classifier decides (vetoes, weights, net score), how to tune it by editing `CutMasterDB.settings.filter`, and the scan behaviour including the fact that opening the Jewelcrafting window is required because the client blocks addons from casting the profession spell.

Include the disclaimer required by spec section 19, covering: the user is responsible for message content and frequency, automated advertising and invites must comply with the Terms of Service and Code of Conduct, and excessive Trade chat use may draw penalties.

- [ ] **Step 2: Bump the version**

In `CutMaster.toc`, change `## Version: 0.1.0` to `## Version: 1.0.0` and add `## X-Category: Professions`.

- [ ] **Step 3: Run the full suite one final time**

In game: `/reload`, then `/cm test`

Expected: `Tests: 55 passed, 0 failed`

- [ ] **Step 4: Commit**

```bash
git add README.md CutMaster.toc
git commit -m "docs: README, usage guide and disclaimer"
```

---

## Self-Review

**Spec coverage check.**

| Spec section | Covered by |
|---|---|
| 4.1 scan triggers (auto-scan, slash) | Task 5. The secure button is plan 2 UI work; `Scanner.initiatedByUs` is already wired for it. |
| 5 architecture, purity boundary | Tasks 1 through 12, file per module |
| 6 data model (book, players, log, settings) | Task 3 defaults, Task 4 book shape |
| 6 orders and ledger keys | Deferred to plan 3, deliberately absent from `ns.Defaults` |
| 7 scanner including reagent capture | Task 5 |
| 8 matcher three tiers | Task 6 |
| 8.1 quantity hints | Task 6 `QtyHint` |
| 9.1 hard vetoes | Task 8 |
| 9.2 seller weights, `can cut` guard | Task 8 |
| 9.3 buyer weights | Task 8 |
| 9.4 net verdict | Task 8 |
| 10 inviter, cooldown, whisper, throttle warning | Task 10 |
| 11 barker, fit, guards, cursor | Task 12 |
| 12 through 15 orders, trade, ledger, UI | Plans 2 and 3 |
| 16 slash commands | Tasks 5, 11, 12. `/cm config`, `/cm orders`, `/cm income`, `/cm tracker`, `/cm order add` belong to plans 2 and 3. |
| 17.1 classifier fixtures | Task 8, all thirteen cases present |
| 17.2 quantity inference fixtures | Plan 3, since `Orders.InferQuantities` does not exist yet |
| 17.3 barker fixtures | Task 12 |
| 19 disclaimer | Task 13 |

**Gap found and closed:** the spec lists `shapeMatch` as "multiple links plus a service verb plus no question mark". Task 8 implements it as "two or more links, no question mark, and at least one other seller signal already scored". Using an existing seller hit as the service-verb proxy avoids a second hardcoded verb list that would drift from `sellerWords`. This is a deliberate narrowing and is noted here rather than left as a silent difference.

**Placeholder scan:** no TBD, TODO, "handle edge cases", or "similar to Task N" instances. Every code step carries runnable code. Every test step carries the actual assertions.

**Type consistency check:**
- `Matcher.Match` returns `{ itemID, tier, qtyHint }`. Consumed with those exact field names in Task 8 tests, Task 9 `Log.Add`, Task 10 `Inviter.Invite`, Task 11 `Events.OnTradeMessage`. Consistent.
- `Classifier.Evaluate` returns `verdict`, `reason`, `sellerScore`, `sellerHits`, `buyerScore`, `buyerHits`, `netScore`. Read with those names in Task 9 `Log.Add` and Task 11. Consistent.
- `Inviter.BlockReason(playerState, now, groupSize, settings)` is called with exactly that argument order in Task 11. Consistent.
- `Barker.Fit(entries, cursor, template, maxLen, perBark)` returns `msg, nextCursor, used` and is called with that arity in `Barker.Tick`. Consistent.
- `ns.Players.Get(db, name)` is defined in Task 7 and called in Tasks 10 and 11. Consistent.
- `Scanner.MergeBook(oldBook, scanned)` returns `newBook, added` and is called that way in `Scanner.Scan`. Consistent.

**Running test count:** 1, 7, 10, 14, 22, 26, 43, 45, 49, 55. Each task's expected count is the previous total plus that task's new cases.

---

## Follow-on Plans

**Plan 2, Interface.** Main frame with Book, Bark, Filter, Log and Invite tabs, the secure Open-and-Scan button that sets `Scanner.initiatedByUs`, LibDBIcon minimap button, and `/cm config`. Depends on the interfaces above being stable.

**Plan 3, Order book.** `Orders.lua` with `InferQuantities`, `Trade.lua` trade window watcher, `Ledger.lua`, `Tracker.lua` compact in-group frame, and the Orders and Income tabs. Depends on `book[id].reagents` from Task 5.
