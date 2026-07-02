# Maruko

Format and move your browser bookmarks.

Maruko is a macOS app that cleans and formats bookmarks directly inside the browsers you already use. Pick a browser profile, preview the cleanup, and apply it with one click — no exporting, no importing.

![Maruko Screenshot](docs/demo.png)

## What it does

- **Detects your browsers.** Chrome, Brave, Edge, and Arc profiles are found automatically. Safari and Firefox are coming later.
- **Removes duplicates.** Bookmarks pointing at the same page (trailing slashes, fragments, query order, host case) are collapsed into one.
- **Rewrites titles.** User-editable rules clean up messy titles. Rules come in two kinds: **regex** (for example, turning a raw GitHub URL into `github > owner > repo`) and **AI** — plain-language instructions like "remove trailing site names" carried out by Apple's on-device model. AI rules apply to recently opened bookmarks, run entirely on your Mac (Apple Intelligence required), and cache their results so re-analysis is instant.
- **Surfaces what you actually use.** Bookmarks you opened recently (per the browser's own history) move to the top of their folder, most recent first. Everything else keeps its order, and the bookmark bar's own row is never reordered — those icons stay exactly where you put them.

Each step can be switched on or off in the Format Options menu (including how far back "recently" reaches), and the title rewrite rules are fully editable.

## Safety

Maruko edits the browser's own `Bookmarks` file, so it is careful:

- Formatting is **blocked while the browser is running** — Chromium browsers rewrite the file from memory, which would silently revert changes.
- Formatting is **blocked while the profile syncs bookmarks** — Chromium treats outside edits to a synced profile as corrupt sync state and restores the server's copy, undoing the cleanup. Turn off bookmark sync for the profile first (Settings → Sync → Manage what you sync). Note that re-enabling sync later merges the server's old copy back over the cleanup unless you clear the browser's synced data first.
- A **timestamped backup** is saved before every write (the last 10 per profile are kept).
- Writes are **atomic**, and node ids, guids, and dates are preserved.
- **Undo Last Change** restores the previous state at any time; undoing twice reapplies.

## Setup

On first launch, grant Maruko access to `~/Library/Application Support` when prompted. That one grant lets it find and format every Chromium browser profile.

## Building

Open `Maruko/Maruko.xcodeproj` in Xcode and run the `Maruko` scheme, or:

```sh
cd Maruko
xcodebuild -scheme Maruko -configuration Debug build   # build
xcodebuild -scheme Maruko test                         # run the tests
```
