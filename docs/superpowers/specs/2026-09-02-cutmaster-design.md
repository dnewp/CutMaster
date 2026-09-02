# CutMaster Design Spec

Date: 2026-09-02
Author: Dezedin
Status: Approved pending review

## 1. Purpose

A Jewelcrafting business addon for WoW TBC Anniversary that does five things:

1. Learns which gem cuts you actually know by scanning your live tradeskill window, so it never goes stale when new patterns are released.
2. Watches Trade chat and auto-invites players requesting a cut you know, while deliberately not inviting competing jewelcrafters advertising their own services.
3. Periodically barks your services to Trade chat on an adjustable timer, linking the actual gem items rather than spelling out pattern names.
4. Tracks what every customer asked for so nothing is forgotten, deriving quantities from the mats they actually hand you.
5. Records income per order so you know what the business is making.

## 2. Why not just use TradeBarker

TradeBarker stores every craftable in static Lua tables (`ProfessionData.lua`). Every new patch of patterns requires an addon update, which is exactly the failure the user hit. CutMaster ships with zero gem data. The book is derived at runtime from the tradeskill window. This is the central design decision and everything else follows from it.

## 3. Non-goals

Explicitly out of scope for v1:

- Professions other than Jewelcrafting
- Localization beyond enUS
- Cross-character or cross-account book and order sharing
- Auction house integration or mat cost accounting (income is tracked gross, not net of mats)
- Automating the trade window itself (reading it is in scope, filling it is not)

## 4. Environment and hard constraints

| Constraint | Value | Consequence |
|---|---|---|
| Client | TBC Anniversary, Interface 20505 / 20506 | Old tradeskill API (`GetNumTradeSkills`), not `C_TradeSkillUI` |
| Chat message cap | 255 characters | Roughly 3 to 4 item links per bark, hence rotation |
| `CastSpellByName` | Protected | Cannot open the JC window from insecure code |
| `GetNumTradeSkills` | Returns 0 when window closed | Scanning requires the window open |
| Tradeskill list | Filtered by the window's active filters | Filters must be cleared before scanning or the book is partial |
| Trade window | Readable, not writable, by addons | Order state is inferred from trade contents, never injected |
| Lua interpreter | Not installed on dev machine | Tests run in game via `/cm test` |

### 4.1 The scan-trigger constraint

An addon cannot open the Jewelcrafting window on its own. `CastSpellByName` and `CastSpell` are protected and produce `ADDON_ACTION_BLOCKED`. Precedent in the user's own AddOns folder: `Enchantrix/EnxAutoDisenchant.lua:723` builds a `SecureActionButtonTemplate` with `type="spell"` because it cannot cast Disenchant directly either.

Mitigation is a three-layer stack that makes scanning effectively invisible:

1. **Auto-scan on `TRADE_SKILL_SHOW`** (primary). Any time the JC window opens for any reason, scan and merge silently.
2. **Secure "Open and Scan" button** in the UI. A real click is a hardware event, so it is permitted. Opens JC, scan fires, window closes.
3. **`/cm scan`** fallback. Scans immediately if the window is open; otherwise surfaces the secure button.

Additionally `SetBindingClick` allows binding the secure button to a key, and `/click CutMasterScanBtn` works from a macro, since both are hardware events.

**Auto-close rule:** the window is closed after scanning only when CutMaster initiated the open. If the user opened JC themselves, the scan is silent and the window is left alone. Tracked with an `initiatedByUs` flag cleared on `TRADE_SKILL_CLOSE`.

## 5. Architecture

```
CutMaster/
  CutMaster.toc          Interface 20505, SavedVariablesPerCharacter: CutMasterDB
  Libs/
    LibStub/
    CallbackHandler-1.0/
    LibDataBroker-1.1/
    LibDBIcon-1.0/
  Core.lua               namespace, defaults, saved-var init, event frame, slash router
  Scanner.lua            tradeskill window -> recipe book, including reagents
  Matcher.lua            alias generation, message -> matched gems, quantity hints
  Classifier.lua         buyer/seller scoring, repeat-bark detection, verdict
  Inviter.lua            invite + whisper, cooldowns, party cap
  Barker.lua             rotation cursor, message build, 255-char fit, guards
  Orders.lua             order records, quantity inference, status lifecycle
  Trade.lua              trade window watcher: partner, contents, money
  Ledger.lua             income entries, aggregation, formatting
  Log.lua                decision ring buffer + review actions
  Minimap.lua            LDB launcher + LibDBIcon registration
  UI.lua                 main frame with seven tabs
  Tracker.lua            compact in-group order tracker frame
  Tests.lua              fixture-driven self test for the pure modules
```

Thirteen small modules, each with one responsibility. TradeBarker's single 1446-line file is the anti-pattern being avoided.

Libs are embedded copies (BigWigs' current versions are the reference). LibDBIcon is required rather than a hand-rolled minimap button because the user runs MBBe / MinimapButtonButton, which collects LibDBIcon buttons. A bespoke button would be stranded on the minimap edge.

### 5.1 Purity boundary

`Matcher`, `Classifier`, `Barker.Fit`, and `Orders.InferQuantities` are written as pure functions taking plain tables and returning values, with no WoW API calls inside. This is what makes `/cm test` possible and keeps the risky logic reviewable. `Trade.lua` is the thin impure adapter that reads the game state and hands plain tables to `Orders`.

## 6. Data model

Saved per character (`SavedVariablesPerCharacter: CutMasterDB`).

```lua
CutMasterDB = {
  version = 1,

  book = {
    [24033] = {
      name      = "Bold Living Ruby",
      link      = "|cffa335ee|Hitem:24033:0:0:0:0:0:0:0|h[Bold Living Ruby]|h|r",
      header    = "Red",      -- tradeskill category row this sat under
      classID   = 3,          -- 3 = Gem
      advertise = true,       -- included in bark rotation
      match     = true,       -- triggers invites
      aliases   = { "bold ruby" },     -- user-added only; generated ones are runtime
      reagents  = { [23436] = 1 },     -- raw itemID -> count required, powers mats mapping
    },
  },
  bookScannedAt = 0,          -- GetServerTime()
  bookPartial   = false,      -- true if any index failed to resolve

  orders = {
    [1] = {
      id          = 1,
      player      = "Bob",
      createdAt   = 0,
      updatedAt   = 0,
      status      = "pending",   -- pending / grouped / mats / done / cancelled
      source      = "trade",     -- trade / whisper / manual
      requestText = "WTB bold living ruby have mats",
      items = {
        { itemID = 24033, qty = 1, qtySource = "default" },  -- default / text / mats / manual
      },
      matsReceived = { [23436] = 3 },   -- raw itemID -> count actually handed over
      needsSplit   = false,             -- ambiguous mats mapping, user must resolve
      copperIn     = 0,
      copperOut    = 0,
      transcript   = { { at = 0, dir = "in", text = "" } },
      notes        = "",
    },
  },
  nextOrderID = 2,

  ledger = {
    entries = {   -- append-only
      { at = 0, player = "Bob", orderID = 1, copper = 300000, gems = { [24033] = 3 } },
    },
    allTimeCopper = 0,
    allTimeGems   = 0,
  },

  settings = {
    bark = {
      enabled     = false,
      intervalSec = 180,      -- slider 30..600
      perBark     = 4,        -- max links attempted per message
      template    = "WTS JC cuts: {gems} and more! /w me",
      cursor      = 1,
      onlyInCity  = true,
      pauseCombat = true,
      pauseInstance = true,
    },
    invite = {
      enabled           = true,
      maxParty          = 5,
      playerCooldownSec = 600,
      whisper = {
        enabled  = true,
        template = "Invited you for {gem}, accept and trade me the mats + tip!",
        cooldownSec = 600,
      },
      confirmOnJoin = false,   -- user declined the group-join confirmation whisper
    },
    filter = {
      requireBuyerSignal = true,
      netThreshold       = 3,    -- verdict compares (sellerScore - buyerScore)
      vetoWords   = { },   -- see 9.1
      sellerWords = { },   -- weighted map, see 9.2
      buyerWords  = { },   -- weighted map, see 9.3
      weights = {
        manyLinks = 3, designLink = 4, repeatBark = 5, shapeMatch = 2, canCut = 4,
      },
    },
    orders = {
      autoFromInvite  = true,
      autoFromWhisper = true,
      captureTranscript = true,
      autoAdvanceMats = true,   -- trade of raw reagents advances pending -> mats
      promptOnDone    = true,   -- delivery trade prompts to close the order
      keepDoneDays    = 30,
    },
    tracker = { enabled = true, hidden = false, point = nil },
    minimap = { hide = false, minimapPos = 220 },   -- owned by LibDBIcon
    debug = false,
  },

  players = {
    ["Bob"] = {
      lastMsg = "", lastMsgAt = 0, repeats = 0,
      flaggedSeller = false, neverInvite = false, lastInviteAt = 0,
      lifetimeCopper = 0, lifetimeOrders = 0,
    },
  },

  log = {   -- ring buffer, newest first, capped at 100
    -- { at, player, msg, matched = {itemIDs}, sellerScore, sellerHits = {},
    --   buyerScore, buyerHits = {}, verdict = "invited"/"vetoed"/"lowscore", reason }
  },
}
```

Rescanning **merges**. `advertise`, `match`, and user `aliases` survive a rescan. New recipes arrive defaulted to `advertise = true, match = true`. Recipes no longer known are kept but flagged `stale` rather than deleted, so unlearning and relearning does not lose settings.

## 7. Scanner

Entry points: `TRADE_SKILL_SHOW` event, secure button, `/cm scan`.

Sequence:

1. Confirm a tradeskill window is open and `GetTradeSkillLine()` reports Jewelcrafting. If a different profession is open, abort silently (do not clobber the book).
2. **Save and clear all active filters.** This is the gotcha that silently produces partial books:
   - `SetTradeSkillSubClassFilter(0, 1, 1)` (All)
   - `SetTradeSkillInvSlotFilter(0, 1, 1)` (All)
   - `TradeSkillOnlyShowMakeable(false)` and `TradeSkillOnlyShowSkillUps(false)`
   - Clear the name filter if `SetTradeSkillItemNameFilter` exists on this client (guarded call)
   - `ExpandTradeSkillSubClass(0)` to expand every collapsed header
3. Walk `1..GetNumTradeSkills()`, tracking the most recent `skillType == "header"` row as the current category.
4. For each non-header row: `GetTradeSkillItemLink(idx)`, extract `itemID` via `Hitem:(%d+)`, resolve name/quality/classID with `GetItemInfo`.
5. **Capture reagents** for that row: `GetTradeSkillNumReagents(idx)`, then per reagent `GetTradeSkillReagentItemLink(idx, r)` for the itemID and `GetTradeSkillReagentInfo(idx, r)` for the required count. Store as `reagents[rawItemID] = count`.
6. Rows returning nil are uncached. Collect them, retry once after `C_Timer.After(0.5)`, then set `bookPartial = true` and report any that still failed so the user can rescan.
7. Restore the saved filter state.
8. Print a summary: `CutMaster: scanned 91 recipes (56 gems), 12 new since last scan.`
9. If `initiatedByUs`, call `CloseTradeSkill()`.

Scope is **everything in the JC window**, not gems only. Rings, necks, trinkets, figurines and statues all enter the book, tagged by their category header. The user toggles off what they do not want per row in the Book tab.

Step 5 exists solely to serve order quantity inference (section 12.2). Without reagent data the mats-to-cut mapping degrades to name-substring guessing.

## 8. Matcher

Normalization applied to every incoming message before matching: strip WoW color and hyperlink escape codes, lowercase, strip punctuation, collapse whitespace. Item links are extracted from the **raw** message before stripping.

Three tiers, most confident first:

1. **Item link.** Every `Hitem:(%d+)` in the raw message, checked against `book` keys. Exact and unambiguous. This is the shift-click case.
2. **Full name.** Normalized substring match against the full cut name.
3. **Loose shorthand.** Each cut name splits into a cut prefix (first token, e.g. `Bold`) and gem base tokens (remaining tokens, e.g. `Living`, `Ruby`). A match requires the prefix **and** at least one base token present within a window of 3 tokens of each other. So `bold ruby`, `bold living`, `great draenite`, `runed ornate` all hit.

A bare cut prefix alone (`bold`, `great`, `solid`) never matches on its own. Those words are common English and would be a false-positive generator.

User-defined aliases in `book[id].aliases` are matched as exact normalized substrings, giving an escape hatch for anything the generator misses.

### 8.1 Quantity hints

The matcher also returns a quantity **hint** per matched gem, parsed from `(%d+)%s*x?%s*<gem>`, `<gem>%s*x%s*(%d+)`, and the number words one through ten. This is only a hint. Section 12.2 explains why mats override it.

## 9. Classifier

Input: normalized message, raw message, author, matched gem list, player history. Output: verdict plus a full audit trail of which signals fired.

### 9.1 Hard vetoes

No scoring, no appeal. Verdict is immediately negative:

- `lfw`, `jc lfw`, `lf work`, `looking for work`
- `wts`, `selling`, `will cut`, `i cut`, `cutting for`
- Author is the player
- Author is already in the group
- Player flagged `neverInvite` or auto-flagged `flaggedSeller`
- Player invited within `playerCooldownSec`
- Group already at `maxParty`

`LFW` is explicitly called out by the user: it means "looking for work", so the poster is a competing jewelcrafter selling their own services. It is a veto, not a weight.

Veto matching is word-boundary aware so `lfw` does not fire inside another word.

### 9.2 Seller weights

`all cuts`, `any cut`, `full book`, `most cuts`, `every cut`, `mats + tip`, `mats+tip`, `free cuts`, `tips appreciated`, `no charge`, price-per-cut patterns matched by pattern rather than literal (`%d+g%s*/?%s*cut`, `%d+g per`, `%d+ gold per`).

**`can cut` is a weighted signal, not a veto** (weight 4), because a buyer can legitimately write "anyone who can cut this". Two protections make it safe:

1. **Context guard.** If `can cut` is preceded within two tokens by `who`, `anyone`, `any1`, `anybody`, `someone`, or `any jc`, it does not score as a seller signal at all. It scores as a *buyer* signal instead, since that phrasing is a request.
2. **Net scoring.** Even when it does fire as a seller signal, buyer evidence subtracts from it (see 9.4), so a message with real buying signals can outvote it.

Plus signals requiring no vocabulary at all, which is what catches competitors who word their ads cleverly:

- **`manyLinks`** (weight 3): three or more gem item links in a single message. A buyer requesting a cut links one or two gems. An advertisement lists many.
- **`designLink`** (weight 4): the message contains a linked `Design:` recipe item or an enchant/spell link. Buyers do not link recipes, sellers show off patterns.
- **`repeatBark`** (weight 5): the same player posted a near-identical message inside the bark rotation window. Sellers post on a timer; buyers do not repost the same string every three minutes. Similarity is measured on the normalized message; two hits inside the window set `flaggedSeller = true` for the rest of the session, which upgrades them to a veto going forward.
- **`shapeMatch`** (weight 2): multiple links plus a service verb plus no question mark reads structurally like an advertisement.

### 9.3 Buyer weights

`wtb`, `want to buy`, `buying`, `need`, `anyone cut`, `who can cut`, `any jc`, `lfjc`, `lf jc`, `have mats`, `got mats`, `have the mats`, `will tip`, `paying`, `pay for`, plus `lf` immediately preceding a matched gem, plus a trailing `?`, plus a context-guarded `can cut` per 9.2.

### 9.4 Verdict

```
netScore = sellerScore - buyerScore

invite  <=>  matched  AND  no veto
             AND netScore < settings.filter.netThreshold
             AND (buyerScore >= 1 OR not settings.filter.requireBuyerSignal)
```

The verdict is a **net** score rather than a raw seller score. This matters: with a raw threshold, any heavily weighted seller signal blocks unconditionally and buyer evidence is decorative. Netting means a message carrying genuine buying signals can outvote a moderate seller signal, which is what makes weights like `can cut` safe to use at all. Hard vetoes in 9.1 bypass scoring entirely and remain absolute.

`requireBuyerSignal` defaults **on**. With it on, a bare `[Bold Living Ruby]` with no words does not trigger an invite, because that shape is as likely to be a seller showcasing as a buyer asking. It lands in the log for manual review instead.

Every word list, weight, and threshold lives in saved variables and is editable in the Filter tab, so tuning happens in game and does not require an addon change.

## 10. Inviter

- `C_PartyInfo.InviteUnit(name)` with a fallback to the global `InviteUnit(name)`, guarded, since availability differs across Classic clients.
- Strips any realm suffix from the author name before inviting.
- Refuses if `GetNumGroupMembers() >= settings.invite.maxParty`.
- Records `lastInviteAt` for the per-player cooldown.
- Whisper is sent after a short delay (invite first, then explanation), rate-limited per player by `whisper.cooldownSec`. Template placeholder `{gem}` resolves to the first matched gem's link, `{player}` to their name.
- A running whisper counter warns at 60 whispers in a session, mirroring ProEnchanters' guard against tripping the game's whisper throttle.
- No confirmation whisper is sent on group join. The user declined that; status advances silently.

Note on the guard selections: barking continues when the party is full, because that was left unchecked deliberately. Invites still stop at the cap, since `InviteUnit` would simply fail. That is a functional limit, not a preference.

## 11. Barker

- Rotation cursor over every book entry with `advertise = true`, in stable order (category, then name).
- Each tick builds a message from `template`, substituting `{gems}`. Links are appended greedily while total length stays at or under 255. The cursor advances by however many actually fit, wrapping at the end.
- Guards, checked before sending. A skipped tick does **not** advance the cursor, so nothing silently drops out of the rotation:
  - `onlyInCity`: resolved by scanning `GetChannelList()` for a channel whose base name starts with `Trade`, which is locale-safe and handles both `Trade` and `Trade - City`. Nil means not in a city, so skip.
  - `pauseCombat`: `InCombatLockdown()` or `UnitAffectingCombat("player")`
  - `pauseInstance`: `IsInInstance()`
- Timer via `C_Timer.NewTicker`, recreated when the interval changes.
- `{gems}` is the only required placeholder; the template is rejected if it is missing.

Rotation has an incidental anti-throttle benefit: consecutive barks differ, which avoids the game's repeated-identical-message suppression.

## 12. Orders

### 12.1 Creation

An order is created from any of four sources, each individually toggleable:

- **Auto on invite.** Every auto-invite creates a pending order seeded with the matched gems and the original trade-chat message.
- **Auto on matching whisper.** An incoming whisper that matches a gem creates an order even if the player never appeared in trade chat. This is a common path and must not be missed.
- **Manual add.** An Add Order button and `/cm order add <player>`, for walk-ups.
- **At the trade window.** If a trade completes with someone who has no open order, CutMaster offers to create one retroactively from the trade contents.

Duplicate suppression: a new request from a player with an existing open order updates that order rather than creating a second one.

### 12.2 Quantity inference

This is the subtle part and the reason the scanner captures reagents.

Customers rarely state a quantity. The normal flow is: they ask for "bold living ruby", then hand over three Living Ruby and expect all three cut that way. So:

- **Text quantity is a hint only**, recorded with `qtySource = "text"` and shown as provisional in the UI.
- **Mats are authoritative.** On a completed trade, for each raw item received, look up which of the customer's requested cuts consumes that raw item via `book[cutID].reagents`. Set that line item's `qty` to the received count divided by the per-craft requirement, and set `qtySource = "mats"`.
- **Unrequested mats add a line item.** If they hand over mats for a cut they never mentioned, add it as a new requested item. Customers change their mind at the trade window constantly.
- **Ambiguity is surfaced, not guessed.** If a received raw item maps to more than one of that customer's requested cuts (they asked for both Bold and Runed Living Ruby, then handed over three Living Ruby), the order is flagged `needsSplit` and the Orders tab shows a splitter row so the user allocates the count. CutMaster never silently picks one.
- **Fallback.** If reagent data is missing (book scanned before this feature, or a partial scan), fall back to matching the raw gem name as a substring of the cut name, which works for the standard TBC naming scheme but is not guaranteed.

`Orders.InferQuantities(order, matsReceived, book)` is a pure function and is directly covered by the test fixtures.

### 12.3 Status lifecycle

`pending -> grouped -> mats -> done`, plus `cancelled` from any state.

- `grouped` advances automatically on `GROUP_ROSTER_UPDATE` when the player actually joins.
- `mats` advances automatically when a completed trade delivers raw reagents matching their order (`autoAdvanceMats`).
- `done` is **prompted, never automatic** (`promptOnDone`). A trade where the user hands over finished cut gems pops a confirm prefilled with the order summary and the gold received. This is deliberate: a trade may be the mats handoff rather than delivery, and silently closing an order the user still owes work on is the worst possible failure for a tool whose job is "so I do not forget".
- Completed orders archive rather than delete, pruned after `keepDoneDays`.

### 12.4 Transcript

When `captureTranscript` is on, whispers both directions with a player holding an open order are appended to that order with a timestamp and direction. This gives a scrollback of exactly what was agreed without relying on the chat frame's own history.

### 12.5 Compact tracker

A separate small draggable frame, `Tracker.lua`, showing open orders **only for players currently in your group**. Each row is the player name plus their pending cuts with quantities, and a tick box per line to check off as you cut. Auto-hides when no group member has an open order, so it costs nothing when idle. Toggle with `/cm tracker`.

## 13. Trade watcher

`Trade.lua` is the impure adapter around the trade window. It reads only; it never fills a trade slot.

Events: `TRADE_SHOW`, `TRADE_ACCEPT_UPDATE`, `TRADE_PLAYER_ITEM_CHANGED`, `TRADE_TARGET_ITEM_CHANGED`, `TRADE_MONEY_CHANGED`, `PLAYER_TRADE_MONEY`, `TRADE_CLOSED`.

1. On `TRADE_SHOW`, record the partner via `UnitName("NPC")` and look up their open order.
2. Snapshot contents when `TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted)` reports both sides accepted, since that is the last moment the contents are guaranteed readable:
   - Incoming items: `GetTradeTargetItemLink(i)` and `GetTradeTargetItemInfo(i)` for slots 1 to 6, giving itemID and stack quantity. Slot 7 is the "will not be traded" slot and is ignored.
   - Outgoing items: `GetTradePlayerItemLink(i)` and `GetTradePlayerItemInfo(i)`.
   - Money: `GetTargetTradeMoney()` and `GetPlayerTradeMoney()`, in copper.
3. Commit the snapshot on the following `TRADE_CLOSED`.

**Completion detection caveat.** `TRADE_CLOSED` fires on cancellation as well as success, and there is no unambiguous success event in this client. The mitigation is that a snapshot is only committed when both parties had accepted immediately prior to the close. This is the same inference other trade-logging addons rely on. It is correct in the overwhelming majority of cases and can be wrong if a trade is cancelled in the instant between both-accept and close. The Orders tab therefore allows editing or reverting any auto-applied trade result, and `done` is prompted rather than automatic.

Outcome routing:

- Incoming raw reagents for their order, and `autoAdvanceMats` on, advances status to `mats` and runs `Orders.InferQuantities`.
- Outgoing finished cuts matching their order prompts to close the order.
- Net money (`GetTargetTradeMoney() - GetPlayerTradeMoney()`) is added to `order.copperIn` and written to the ledger.
- No open order for this partner triggers the retroactive-order offer from 12.1.

## 14. Ledger

`Ledger.lua` maintains an append-only entry list. Every committed trade with a nonzero net money value writes `{ at, player, orderID, copper, gems }`.

The Income tab presents:

- Total earned all time, today, and this session
- Gems cut, and average copper per gem cut
- Top customers by lifetime gold, from `players[name].lifetimeCopper`
- A recent-entries list

All values are stored as integer copper and rendered with `GetCoinTextureString` so formatting matches the game. Income is **gross**: mat costs are not deducted, per the non-goals.

## 15. UI

One draggable frame, styled to match TradeBarker's flat dark theme so the two look like a set. Seven tabs:

| Tab | Contents |
|---|---|
| **Book** | Scrollable list of scanned recipes grouped by category. Per row: gem link, `advertise` checkbox, `match` checkbox, alias editor. Header row shows scan age and a warning if `bookPartial`. Contains the secure Open-and-Scan button. |
| **Bark** | Enable toggle, interval slider (30 to 600s), template editor with live preview and character counter, guard checkboxes, Send Now button. |
| **Orders** | Open orders list with player, requested cuts and quantities, status, mats received, and gold. Per row: status dropdown, splitter when `needsSplit`, notes field, transcript expander, Complete and Cancel buttons. Add Order button. Archived orders behind a toggle. |
| **Income** | Totals, averages, top customers, recent entries, per section 14. |
| **Filter** | `requireBuyerSignal` toggle, net threshold slider, and editable lists for veto / seller / buyer words with their weights. |
| **Log** | Last 100 scored messages. Per row: player, message, matched gems, seller score with the signals that fired, buyer score with its signals, verdict. Buttons: Invite anyway, Never invite this player, Clear flag. |
| **Invite** | Enable toggle, max party size, per-player cooldown, whisper toggle and template. |

The Log tab is what makes the classifier improve over time. It shows exactly why a competitor slipped through or why a real customer was skipped, so the user adds one word to a list rather than filing a bug.

### 15.1 Minimap button

LibDataBroker launcher object registered with LibDBIcon-1.0.

- Left click: toggle the CutMaster window
- Right click: toggle barking on and off
- Tooltip: bark on/off with time to next bark, book size, scan age, open order count, gold earned today
- Position and hidden state persisted in `settings.minimap`, owned by LibDBIcon
- Because it is a LibDBIcon button, MBBe collects it automatically

## 16. Slash commands

`/cm` and `/cutmaster`:

| Command | Effect |
|---|---|
| `/cm` | Toggle the main window |
| `/cm config` | Open the main window (same as the minimap left click) |
| `/cm scan` | Scan now if JC is open, otherwise surface the secure button |
| `/cm bark` | Toggle barking |
| `/cm bark <seconds>` | Set the interval and enable |
| `/cm send` | Send one bark immediately, ignoring the timer |
| `/cm invite` | Toggle auto-invite |
| `/cm orders` | Open the Orders tab |
| `/cm order add <player>` | Create a manual order |
| `/cm tracker` | Toggle the compact in-group tracker |
| `/cm income` | Open the Income tab |
| `/cm log` | Open the Log tab |
| `/cm test` | Run the self test |
| `/cm debug` | Toggle verbose decision printing to chat |
| `/cm help` | List commands |

## 17. Testing

No Lua interpreter is installed on the dev machine, so tests run in game against the real runtime via `/cm test`. `Matcher`, `Classifier`, `Barker.Fit`, and `Orders.InferQuantities` are pure, so they can be driven from fixtures with no game state.

### 17.1 Classifier fixtures

| Fixture | Expected |
|---|---|
| `JC LFW all cuts pst` | veto, `lfw` |
| `WTS [Bold Living Ruby] [Runed Living Ruby] [Great Golden Draenite] 5g` | veto, `wts`, plus `manyLinks` |
| `LF work, jewelcrafter, all cuts avail` | veto, `lf work` |
| `Can cut any gem, mats + tip` | no invite: `can cut` 4 + `any cut` 2 + `mats + tip` 2, no buyer signal |
| `anyone who can cut [Bold Living Ruby]? have mats` | invite: context guard turns `can cut` into a buyer signal |
| `LF someone who can cut this, will tip` | invite: guarded `can cut`, plus `will tip` |
| `WTB bold ruby have mats` | invite |
| `any jc able to cut [Bold Living Ruby]?` | invite |
| `LF [Runed Living Ruby] will tip` | invite |
| `[Bold Living Ruby]` alone | no invite while `requireBuyerSignal` is on, logged for review |
| `need a bold cut on this ruby` | invite |
| Same ad posted twice inside the window | second is `repeatBark`, player auto-flagged |
| `boldly going where no one has gone` | no match, `bold` alone must not fire |

### 17.2 Quantity inference fixtures

| Fixture | Expected |
|---|---|
| Requested Bold Living Ruby, no stated qty, received 3x Living Ruby | Bold Living Ruby qty 3, `qtySource = "mats"` |
| Requested `2x bold living ruby`, received 3x Living Ruby | qty 3, mats override the text hint |
| Requested Bold and Runed Living Ruby, received 3x Living Ruby | `needsSplit = true`, no silent allocation |
| Requested Bold Living Ruby, received 2x Star of Elune | new line item added for the matching Star of Elune cut |
| Requested Bold Living Ruby, received 3x Living Ruby and 20g | qty 3 and `copperIn = 200000` |
| Reagent data missing from book | name-substring fallback still resolves Living Ruby to Bold Living Ruby |

### 17.3 Barker fixtures

40 advertised gems against the 255-char cap: `Barker.Fit` returns 3 or 4 links, the cursor advances by exactly that count, and wraps correctly at the end of the list.

### 17.4 Manual in-game checklist

Covers what cannot be unit tested: scan with filters active, scan with an uncached item, secure button open-and-close, auto-scan leaving a manually opened window alone, bark in a city versus outside one, invite at party cap, minimap button collected by MBBe, a real two-trade order from invite through mats to delivery, and a cancelled trade not committing a snapshot.

## 18. Risks and edge cases

| Risk | Handling |
|---|---|
| Partial scan from active filters | Filters explicitly saved, cleared, restored. `bookPartial` flag plus UI warning. |
| Uncached items return nil links | One retry after 0.5s, then report by index. |
| `C_PartyInfo.InviteUnit` missing on this client | Guarded fallback to global `InviteUnit`. |
| Secure attributes cannot change in combat | Secure button attributes set once at creation, never mutated. |
| Chat throttle from barking | Rotation varies each message; minimum interval floored at 30s. |
| Whisper throttle | Per-player cooldown plus a session counter that warns at 60. |
| Stale book after learning new patterns | Auto-scan on `TRADE_SKILL_SHOW` plus a login nudge if the book is empty or older than 7 days. |
| Item link format drift between client builds | Links are stored, but rebuilt from `itemID` via `GetItemInfo` at send time when available, falling back to the stored string. |
| False invite to a competitor | Layered: vetoes, weights, behavioral signals, plus a Never-invite list the user controls from the Log tab. |
| Cancelled trade misread as complete | Snapshot committed only when both sides accepted immediately before close; every auto-applied result is editable and revertible in the Orders tab. |
| Ambiguous mats-to-cut mapping | Surfaced as `needsSplit` for the user to resolve, never guessed. |
| Same-name players across realms | Realm suffix stripped for invites but retained on the order key where available. |
| Orders table growth over months | Completed orders pruned after `keepDoneDays`, default 30. Ledger entries are kept. |

## 19. Disclaimer

Following TradeBarker's precedent, the README will state plainly that the user is responsible for the content and frequency of messages sent, that automated advertising and invites must comply with the game's Terms of Service and Code of Conduct, and that excessive use of Trade chat may draw penalties from Blizzard. Defaults are deliberately conservative: barking off by default, 180s interval, `requireBuyerSignal` on.
