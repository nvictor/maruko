# Maruko

Format and move your browser bookmarks.

Maruko is a macOS app that cleans and formats bookmarks directly inside the browsers you already use. Pick a browser profile, preview the cleanup, and apply it with one click — no exporting, no importing.

![Maruko Screenshot](docs/demo.png)

## What it does

- **Detects your browsers.** Chrome, Brave, Edge, and Arc profiles are found automatically. Safari and Firefox are coming later.
- **Removes duplicates.** Bookmarks pointing at the same page (trailing slashes, fragments, query order, host case) are collapsed into one.
- **Rewrites titles.** User-editable regex rules clean up messy titles — for example, turning a raw GitHub URL into `github > owner > repo`.
- **Surfaces what you actually use.** Bookmarks you opened recently (per the browser's own history) move to the top of their folder, most recent first. Everything else keeps its order, and the bookmark bar's own row is never reordered — those icons stay exactly where you put them.

Each step can be switched on or off in the Format Options menu (including how far back "recently" reaches), and the title rewrite rules are fully editable.

## Safety

Maruko edits the browser's own `Bookmarks` file, so it is careful:

- Formatting is **blocked while the browser is running** — Chromium browsers rewrite the file from memory, which would silently revert changes.
- A **timestamped backup** is saved before every write (the last 10 per profile are kept).
- Writes are **atomic**, and node ids, guids, dates, and sync metadata are preserved so browser sync treats the cleanup as ordinary edits.
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
