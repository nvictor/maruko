# Maruko

Format and move your browser bookmarks.

Maruko is a macOS app that cleans up your Chrome bookmarks. It works together with a small companion Chrome extension: Maruko analyzes your bookmarks and previews the cleanup, the extension applies the change through Chrome's own `chrome.bookmarks` API. No exporting, no importing, and it works with Chrome running and Sync on, so the cleanup propagates to your other devices too.

![Maruko Screenshot](docs/demo.png)

- Removes duplicate bookmarks.
- Curates a "Recent" folder of your most accessed bookmarks from the last 30 days, up to 20.
- Previews every change and applies it only after you confirm.
- Setup is a one-time pairing with the companion extension. See [Extension setup](docs/extension-setup.md).

Requires macOS 26.0 or later and Apple Silicon.
