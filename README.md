# CutMaster

A Jewelcrafting business assistant for World of Warcraft TBC Anniversary.

CutMaster learns your cuts by reading your own Jewelcrafting book, watches for customers, invites the real ones while ignoring competing jewelcrafters, advertises your gems in Trade chat, tracks what everyone ordered, and records what you earned.

**It ships with zero gem data.** Your book comes from scanning the live tradeskill window, so new patterns work the day you learn them and nothing goes stale between patches.

---

## Install

Copy the `CutMaster` folder into:

```
World of Warcraft/_anniversary_/Interface/AddOns/
```

Restart the client (WoW only finds new addon folders at launch) and tick **CutMaster** in the AddOns list.

---

## Quick start

1. Open your Jewelcrafting window once. CutMaster scans it silently.
2. `/cm` opens the main window. The **Book** tab lists everything you know.
3. Pick what to advertise: the **Epic**, **Rare+**, **All** and **None** buttons do it in bulk, or tick individual gems.
4. Set a key for **Send bark to Trade** under Esc, Key Bindings, CutMaster.
5. `/cm bark 180` turns on the bark reminder.

That is the whole setup. Everything else runs on its own.

---

## What it does

### Knows your cuts

Scanning reads every recipe in your Jewelcrafting window along with its **reagents**, item **quality**, and whether it is **Bind on Pickup**. Rescanning merges: your advertise and match choices and any custom aliases survive.

Scanning happens automatically when you open Jewelcrafting, but only when it could learn something (empty book, you gained a skill, or the book is over 6 hours old). It clears the window's filters to read the full list, so it does not do that every time you open the window to craft.

`/cm scan` forces one.

### Finds customers

CutMaster watches Trade chat, whispers, and party chat. It matches gem requests four ways:

- **Item links** that someone shift-clicked
- **Full names** typed out
- **Shorthand** like `bold ruby` for Bold Living Ruby
- **Your own aliases**, added per gem in the Book tab

It also understands `LF JC` and similar, where nobody names a gem at all.

### Ignores your competition

Every gem-related message is scored. Some phrases are hard vetoes and never invite: `LFW`, `JC LFW`, `LF work`, `WTS`, `selling`, `will cut`, `i cut`.

Beyond that, seller signals (`all cuts`, `full book`, price-per-cut patterns, three or more gem links in one message, a linked `Design:` recipe) are weighed against buyer signals (`WTB`, `need`, `have mats`, `will tip`, a trailing question mark). The verdict uses the **net** of the two, so a genuine customer can outweigh a phrase that merely looks like an advert.

Two signals need no keywords at all. A player who posts the same gem message twice inside your bark window gets flagged as a competitor for the session, and a message shaped like a broadcast scores as one.

Everything is tunable in the **Filter** tab and every decision is recorded in the **Log** tab with the exact signals that fired.

### Talks to customers

| They say | CutMaster replies |
|---|---|
| Names a cut you have | Invites them, whispers that it is on the way |
| `LF JC` with no gem named | Invites, asks what they need, waits for the answer |
| Names a cut you lack | "Sorry, I don't have that cut." No alternatives pitched. |
| Names several, you have some | "I can do [X], but I don't have [Y]." |
| Types half a gem name | "Did you mean one of these? [links]" |
| Chats about gem prices | Nothing. It is not a question. |

Every one of those messages is editable in the **Invite** tab, with a Reset per line. **Leave a line empty and nothing is sent for that case.**

Turn on **whisper-only mode** (Invite tab, or `/cm invite whisperonly`) to keep all of the above exactly as it is but skip the "Invites them" part everywhere it appears — CutMaster still detects and replies, you decide when to actually invite.

### Tracks orders

An order opens when someone asks, and counts as *open* only once they actually join your group. Quantities come from **the mats they hand you**, not from what they typed, because customers say "bold living ruby" and then trade you three.

If the mats fit two cuts they asked for, CutMaster **refuses to guess** and asks you to set the split in the Orders tab.

The **Tracker** is a slim window you can leave on screen: open orders, a tick box per gem, and a count of what is left to cut. Ticking the last gem closes the order. Right-click a name to cancel it.

### Fills the trade window

Open a trade with someone who has an open order and CutMaster puts their finished cuts in for you. Only gems on that person's order, never soulbound, and it re-checks each bag slot immediately before adding.

### Records income

Gold from completed trades is logged per order and per customer. The **Income** tab shows all-time, last 24 hours, last 7 days, average per gem, and your top customers. Income is gross: mat costs are not deducted.

### Shows gem stats

In the Jewelcrafting window, gem names are replaced with what they do (`+8 Agility` instead of `Delicate Living Ruby`). The gem icon in the window's top-right toggles it, or `/cm stats`.

---

## What the client will not let it do

Three limits are imposed by WoW itself, not by CutMaster. They are worth knowing so the behaviour does not look like a bug.

**Barking cannot be fully automatic.** `SendChatMessage` to a public channel is protected and only works during a hardware event. A timer callback is not one. So the interval **reminds** you, and a key press or button click sends. This is also why TradeBarker only ever had a manual Send button. Simulating a hardware event from Lua is not possible.

**It cannot open your Jewelcrafting window.** Casting a profession is protected too. Hence scanning on window open, rather than on demand.

**Trade completion is inferred.** There is no unambiguous "trade succeeded" event. CutMaster snapshots the contents when both parties have accepted and commits when the window closes. A trade cancelled in that instant could be recorded wrongly, so everything it applies is editable and closing an order is prompted rather than automatic.

---

## Commands

`/cm` or `/cutmaster`.

### General
| Command | Effect |
|---|---|
| `/cm disable` | Turn everything off: no invites, whispers, barks, order creation or trade filling |
| `/cm enable` | Turn it all back on, exactly as it was |
| `/cm` | Open or close the main window |
| `/cm config` | Same |
| `/cm status` | Every toggle, book age, buffer counts |
| `/cm help` | List commands |
| `/cm out [n]` | Send CutMaster's output to a different chat window |

### Book
| Command | Effect |
|---|---|
| `/cm scan` | Scan the open Jewelcrafting window |
| `/cm book` | Recipe and gem counts |
| `/cm adv` | List what is being advertised |
| `/cm adv epic\|rare\|all\|none` | Bulk select what to advertise |
| `/cm adv +text` / `/cm adv -text` | Add or remove by name match |
| `/cm stats` | Toggle gem stats in the JC window |

### Barking
| Command | Effect |
|---|---|
| `/cm bark` | Toggle barking |
| `/cm bark <seconds>` | Set the reminder interval (30 to 600) and enable |
| `/cm send` | Send a bark now |
| `/cm preview` | Show the next bark without sending it |

### Customers
| Command | Effect |
|---|---|
| `/cm invite` | Toggle auto-invite from Trade chat |
| `/cm invite whisperonly` | Toggle whisper-only mode: still detects and replies, never auto-invites |
| `/cm log` | Recent decisions with score breakdowns |
| `/cm clearflags` | Clear the auto competitor flag from everyone |

### Orders
| Command | Effect |
|---|---|
| `/cm orders` | List orders |
| `/cm order add <player>` | Open one manually |
| `/cm order done <id>` | Close it |
| `/cm order cancel <id>` | Cancel it |
| `/cm order reopen <id>` | Undo a close or cancel |
| `/cm tracker` | Toggle the slim tracker window |
| `/cm income` | Earnings summary |

An order starts **pending** the moment someone is invited, and only counts as open work once they join the group. It still shows up in the Tracker as its own greyed-out row while it waits — right-click it to cancel by hand. If they never join — missed the invite, declined it, or just wandered off — it auto-cancels after 5 minutes on its own. Declining outright closes it immediately, no need to wait out the timeout.

### Testing and tuning
| Command | Effect |
|---|---|
| `/cm match <text>` | Which gems a piece of text matches |
| `/cm try <message>` | Run a Trade message through the classifier. Sends nothing. |
| `/cm trywhisper <message>` | Same, as a whisper |
| `/cm tryparty <message>` | Same, as party chat |
| `/cm debug` | Print every decision as it happens |
| `/cm capture` | Record every Trade message and its verdict |
| `/cm clearcapture` | Empty the capture buffer |
| `/cm lastfill` | Replay what the last trade fill saw, tick by tick |
| `/cm test` | Run the self test |

---

## Key bindings

Esc, Key Bindings, **CutMaster**:

- **Send bark to Trade**. Worth setting, since this is the only way a bark actually sends.
- **Toggle CutMaster window**

---

## Minimap

- **Left click** opens CutMaster
- **Right click** sends a bark
- **Middle click** toggles the tracker

It uses LibDBIcon, so button collectors like MinimapButtonButton pick it up.

---

## Tuning it

Everything lives in `CutMasterDB`, per character, editable in game.

If it invites someone it should not, open the **Log** tab. Every decision shows the signals that fired and their weights, so you can see whether the matcher or the classifier was at fault. Add a word to the veto list in the **Filter** tab and it will not happen again.

If it misses a real customer, `/cm capture` records every Trade message including the ones it ignored, which is the only way to see what it never noticed.

If the trade window fills wrongly, `/cm lastfill` replays the last one tick by tick: what was in the window, what was in your bags, what it still thought it owed, and where it stopped. A trade happens too fast to watch and leaves nothing behind, so this is the only way to tell an item that would not move from one it never tried.

The settings most worth knowing:

- `filter.requireBuyerSignal` (default on) means a Trade message needs some sign of buying, not just a gem name. Turning it off will invite anyone who mentions a gem.
- `filter.netThreshold` (default 3) is how much net seller evidence blocks an invite.
- `invite.whisper.autoSuggest` (default off) offers alternatives when you lack a cut. Off because it reads as a sales pitch.
- `orders.autoFillTrade` (default on) loads the trade window for you.
- `enabled` (default on) is the master switch behind `/cm disable`.

`/cm disable` is the quickest way to go quiet without losing your setup. It flips a single flag and stops the bark timer; every other setting is left alone, so `/cm enable` restores exactly what you had. While disabled the UI, scanning, gem stats and the `/cm try` commands still work, and the window, minimap tooltip and a login message all say so, since a silent addon and a broken one look identical otherwise.

---

## Testing

`/cm test` runs the built-in suite in game. Failures are written to SavedVariables as well as printed, so they can be read from `CutMaster.lua` after a `/reload`.

The pure modules (`Util`, `Matcher`, `Classifier`, `Players`, `Orders.InferQuantities`, `Barker.Fit`) call no WoW API, which is what makes them testable this way.

---

## Disclaimer

**You are responsible for the content and frequency of everything this addon sends in your name.**

- Automated advertising, invites and whispers must comply with the World of Warcraft Terms of Service and Code of Conduct.
- Excessive use of Trade chat or unsolicited whispers may result in penalties from Blizzard Entertainment.
- The defaults are deliberately conservative: barking off, a 180 second interval, a 30 second floor, per-player invite and whisper cooldowns, and a warning after 60 whispers in a session.
- Unsolicited suggestion whispers are off by default on purpose.

Use it to run a shop, not to spam.

---

## Credits

Written for Dezedin on Dreamscythe.

Behavioural reference was taken from **TradeBarker** (message building and the 255 character split), **ProEnchanters** (invite handling and cooldowns), **JewelcrafterPro** (reading gem stats off a scanning tooltip) and **Gargul** (filling the trade window with `UseContainerItem`).

Embeds LibStub, CallbackHandler-1.0, LibDataBroker-1.1 and LibDBIcon-1.0.
