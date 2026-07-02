# Formatting through the Chrome extension

Chrome Sync treats outside edits to a synced profile's `Bookmarks` file as corrupt sync state and restores the server's copy — which silently undoes Maruko's formatting. The Maruko Companion extension solves this by applying the changes **through Chrome itself** (the `chrome.bookmarks` API) while Chrome runs, so sync journals every edit like one you made by hand. Use this path when the profile syncs bookmarks, or whenever you don't want to quit Chrome.

Maruko stays in charge: it analyzes the bookmarks the extension sends, shows the usual preview, and only after you confirm does the extension apply anything.

## One-time setup

Everything starts from **Chrome Extension** in Maruko's sidebar. The setup checklist there mirrors these steps:

1. **Install Extension…** — Maruko copies the bundled extension to a folder and reveals it in Finder. (Use *Export to Folder…* if you'd rather keep it somewhere you choose.)
2. In Chrome, open `chrome://extensions` (the checklist has a copy button) and switch on **Developer mode** (top right).
3. **Drag the `ChromeExtension` folder** from Finder anywhere onto the extensions page — or click *Load unpacked* and pick it.
4. Click the Maruko icon in Chrome's toolbar (pin it via the puzzle-piece menu if it's hidden) and **paste the pairing code** shown in Maruko.

The moment the extension reaches Maruko, the checklist collapses into a green "Extension connected".

The pairing code is `port-token`: the extension only talks to `127.0.0.1` and Maruko rejects any request without the token, so nothing else on the machine (or a web page) can drive it.

## Day-to-day flow

1. Open Maruko and select **Chrome Extension** in the sidebar (this starts the local listener).
2. In Chrome, click the Maruko icon → **Send Bookmarks**. The extension sends the live bookmark tree plus recent history.
3. Maruko analyzes (rewrite rules, duplicates, recency — AI title rules run on-device as usual) and shows the preview.
4. Click **Apply via Extension** in Maruko and confirm.
5. The extension picks the changes up on its next poll and applies them. **Keep the popup open while it applies**; if you closed it, click the Maruko icon again and it resumes.

Chrome Sync then propagates the cleanup to the server and your other devices.

## Safety

- Before analyzing, Maruko saves the **full tree the extension sent** to
  `~/Library/Containers/com.mellowfleet.Maruko/Data/Library/Application Support/Maruko/ExtensionSnapshots/`
  (last 10 kept). **Undo Last Change does not cover extension formatting yet** — the snapshots are for manual recovery.
- Enterprise-managed bookmarks are never touched.
- Individual operation failures don't abort the run; they're collected and reported in the summary.

## Updating the extension

When a Maruko update ships a newer extension, opening the Chrome Extension screen re-exports it automatically and shows a reminder: open `chrome://extensions` and click **Reload (⟳)** on Maruko Companion.

## Troubleshooting

- **"Could not reach Maruko"** — the app must be open with Chrome Extension selected in the sidebar; the listener runs while the app does.
- **Port in use** — Maruko falls back through ports 38765–38769. The pairing code embeds the port, so if it changed, re-pair (the popup's *Re-pair with Maruko* link).
- **Regenerate the pairing token** — delete the `maruko.extensionPairingToken` default (`defaults delete com.mellowfleet.Maruko maruko.extensionPairingToken`), relaunch Maruko, re-pair.
- **Popup closed mid-apply** — click the Maruko icon again; it resumes where it left off (already-applied operations are skipped).
- **Deleted Maruko or its container** — Chrome's loaded copy of the extension lives inside Maruko's container, so it breaks if the container is removed. Re-run *Install Extension…*, or use *Export to Folder…* to keep it somewhere permanent.
- **Huge profiles** — applying thousands of edits can take a while, and Chrome Sync may throttle very large bursts; the edits are journaled, so sync catches up on its own.

## Development

The extension source of truth is [`extension/`](../extension/) at the repo root (it's bundled into `Maruko.app/Contents/Resources/extension/` at build time). For extension work, load the repo checkout directly via *Load unpacked* — edits are picked up with a single Reload, no app rebuild.
