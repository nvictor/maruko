# Maruko

Format and move your browser bookmarks.

Maruko is a macOS app that cleans up bookmarks in the browsers you already use. It works together with a small companion Chrome extension: Maruko analyzes your bookmarks and previews the cleanup, the extension applies the change through Chrome's own `chrome.bookmarks` API. No exporting, no importing, and it works with Chrome running and Sync on, so the cleanup propagates to your other devices too.

![Maruko Screenshot](docs/demo.png)

## What it does

- **Removes duplicates.** Bookmarks pointing at the same page (trailing slashes, fragments, query order, host case) are collapsed into one.
- **Cleans up titles.** User-editable regex rules normalize messy bookmark titles (for example, turning a raw GitHub URL into `github owner/repo`). Maruko can also refresh the current HTML titles of up to 20 bookmarks in your **Recent** folder directly from their webpages.
- **Surfaces what you actually use.** Bookmarks you opened recently (per your Chrome history) move to the top of their folder, most recent first. Everything else keeps its order, and the bookmark bar's own row is never reordered. Those icons stay exactly where you put them.

Each step can be switched on or off in the Format Options menu (including webpage-title refresh and how far back "recently" reaches), and the regex title rules are fully editable. Webpage-title refresh is off by default.

## How it works

1. In Maruko, select **Chrome Extension** in the sidebar and follow the one-time setup (Maruko installs the extension for you).
2. In Chrome, click the Maruko icon and press **Send Bookmarks**. The extension sends the live bookmark tree and recent history to Maruko.
3. Maruko analyzes it and shows a preview of what would change.
4. Click **Apply via Extension** and confirm. The extension applies the change via `chrome.bookmarks`, so Chrome Sync journals it like any ordinary edit.

See [docs/extension-setup.md](docs/extension-setup.md) for the full setup and day-to-day flow.

## Safety

- Before applying anything, Maruko saves a **snapshot of the tree it received** (last 10 kept) for manual recovery.
- Individual operation failures don't abort the run. They're collected and reported in the summary.
- Enterprise-managed bookmarks are never touched.

## Building

Open `Maruko/Maruko.xcodeproj` in Xcode and run the `Maruko` scheme, or:

```sh
cd Maruko
xcodebuild -scheme Maruko -configuration Debug build   # build
xcodebuild -scheme Maruko test                         # run the tests
```
