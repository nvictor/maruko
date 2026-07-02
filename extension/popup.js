// Maruko Companion popup. All logic lives here (no service worker): the
// popup drives sending the tree, polling Maruko for the confirmed ops, and
// applying them via chrome.bookmarks. If the popup closes mid-flow, the
// session id persists in storage and reopening the popup resumes.

const HISTORY_WINDOW_MS = 90 * 24 * 60 * 60 * 1000;
const POLL_INTERVAL_MS = 1500;
const BOOKMARK_API_TIMEOUT_MS = 15000;

const els = {
  pairingSection: document.getElementById("pairing-section"),
  pairingInput: document.getElementById("pairing-input"),
  pairingSave: document.getElementById("pairing-save"),
  mainSection: document.getElementById("main-section"),
  send: document.getElementById("send"),
  hint: document.getElementById("hint"),
  status: document.getElementById("status"),
  keepOpen: document.getElementById("keep-open"),
  repair: document.getElementById("repair"),
};

let pairing = null; // { port, token }
let pollTimer = null;
let applying = false;

function failureResult(message) {
  return {
    ok: false,
    counts: { deleted: 0, retitled: 0, moved: 0 },
    errors: [{ op: "apply", id: null, message }],
  };
}

function chromeCall(label, fn, ...args) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error(`${label} did not finish after ${BOOKMARK_API_TIMEOUT_MS / 1000} seconds.`));
    }, BOOKMARK_API_TIMEOUT_MS);

    try {
      fn(...args, (result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        const lastError = chrome.runtime.lastError;
        if (lastError) {
          reject(new Error(lastError.message));
        } else {
          resolve(result);
        }
      });
    } catch (error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    }
  });
}

function setStatus(text, kind) {
  els.status.textContent = text || "";
  els.status.className = "status" + (kind ? " " + kind : "");
}

function showPairing() {
  els.pairingSection.hidden = false;
  els.mainSection.hidden = true;
}

function showMain() {
  els.pairingSection.hidden = true;
  els.mainSection.hidden = false;
}

// --- Maruko API -------------------------------------------------------

function baseURL() {
  return `http://127.0.0.1:${pairing.port}`;
}

async function api(method, path, body) {
  const response = await fetch(baseURL() + path, {
    method,
    headers: {
      "X-Maruko-Token": pairing.token,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `Maruko answered ${response.status}.`);
  }
  return payload;
}

async function ping() {
  const info = await api("GET", "/ping");
  return info.app === "maruko";
}

// --- Pairing ----------------------------------------------------------

async function savePairing() {
  const code = els.pairingInput.value.trim();
  const dash = code.indexOf("-");
  const port = Number(code.slice(0, dash));
  const token = code.slice(dash + 1);
  if (dash < 1 || !Number.isInteger(port) || port <= 0 || !token) {
    setStatus("That doesn't look like a Maruko pairing code.", "error");
    return;
  }

  pairing = { port, token };
  try {
    await ping();
  } catch (error) {
    pairing = null;
    setStatus(`Could not reach Maruko: ${error.message} Is the app open on the Chrome Extension screen?`, "error");
    return;
  }

  await chrome.storage.local.set({ pairing });
  setStatus("Connected to Maruko.", "ok");
  showMain();
}

// --- Send -------------------------------------------------------------

async function collectPayload() {
  const tree = await chrome.bookmarks.getTree();
  const historyItems = await chrome.history.search({
    text: "",
    startTime: Date.now() - HISTORY_WINDOW_MS,
    maxResults: 100000,
  });
  return {
    browser: "chrome",
    extensionVersion: chrome.runtime.getManifest().version,
    tree,
    history: historyItems
      .filter((item) => item.url && item.lastVisitTime)
      .map((item) => ({ url: item.url, lastVisitTime: item.lastVisitTime })),
  };
}

async function sendBookmarks() {
  els.send.disabled = true;
  setStatus("Collecting bookmarks…");
  try {
    const payload = await collectPayload();
    setStatus("Sending to Maruko…");
    const { sessionId } = await api("POST", "/session", payload);
    await chrome.storage.local.set({ sessionId });
    startPolling(sessionId);
  } catch (error) {
    setStatus(error.message, "error");
    els.send.disabled = false;
  }
}

// --- Polling & applying -------------------------------------------------

function startPolling(sessionId) {
  stopPolling();
  const tick = () => poll(sessionId).catch((error) => {
    stopPolling();
    setStatus(error.message, "error");
    els.send.disabled = false;
  });
  pollTimer = setInterval(tick, POLL_INTERVAL_MS);
  tick();
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

async function poll(sessionId) {
  if (applying) return;
  const { status, ops } = await api("GET", `/session/${sessionId}`);

  switch (status) {
    case "analyzing":
      els.send.disabled = true;
      setStatus("Maruko is analyzing…");
      break;
    case "awaitingConfirmation":
      els.send.disabled = true;
      setStatus("Review the plan in Maruko and click Apply via Extension.");
      break;
    case "opsReady":
    case "applying":
      if (ops && !applying) {
        stopPolling();
        await applyAndReport(sessionId, ops);
      } else {
        els.send.disabled = true;
        setStatus("Waiting for Maruko to send the operations…");
      }
      break;
    case "applied":
      stopPolling();
      await chrome.storage.local.remove("sessionId");
      els.send.disabled = false;
      setStatus("Done. Bookmarks formatted.", "ok");
      break;
    case "failed":
    case "cancelled":
      stopPolling();
      await chrome.storage.local.remove("sessionId");
      els.send.disabled = false;
      setStatus(status === "failed" ? "Maruko reported a failure." : "Cancelled in Maruko.", status === "failed" ? "error" : "");
      break;
  }
}

async function applyAndReport(sessionId, ops) {
  applying = true;
  els.send.disabled = true;
  els.keepOpen.hidden = false;
  try {
    const result = await applyOps(ops);
    await api("POST", `/session/${sessionId}/result`, result);
    await chrome.storage.local.remove("sessionId");
    if (result.ok) {
      setStatus("Done. Bookmarks formatted.", "ok");
    } else {
      setStatus(`Finished with ${result.errors.length} errors: ${result.errors[0].message}`, "error");
    }
  } catch (error) {
    const message = String(error.message || error);
    try {
      await api("POST", `/session/${sessionId}/result`, failureResult(message));
      await chrome.storage.local.remove("sessionId");
    } catch {
      // Keep the session id so reopening the popup can try to report or apply again.
    }
    setStatus(`Applying failed: ${message}`, "error");
  } finally {
    applying = false;
    els.keepOpen.hidden = true;
    els.send.disabled = false;
  }
}

async function applyOps(ops) {
  const errors = [];
  const counts = { deleted: 0, retitled: 0, moved: 0 };
  const total = ops.deletes.length + ops.retitles.length + ops.reorders.length;
  let done = 0;
  const progress = () => setStatus(`Applying ${++done} of ${total}…`);

  for (const id of ops.deletes) {
    setStatus(`Deleting bookmark ${done + 1} of ${total}…`);
    try {
      await chromeCall("Delete bookmark", chrome.bookmarks.remove, id);
      counts.deleted++;
    } catch (error) {
      errors.push({ op: "delete", id, message: String(error.message || error) });
    }
    progress();
  }

  for (const { id, title } of ops.retitles) {
    setStatus(`Renaming bookmark ${done + 1} of ${total}…`);
    try {
      await chromeCall("Rename bookmark", chrome.bookmarks.update, id, { title });
      counts.retitled++;
    } catch (error) {
      errors.push({ op: "retitle", id, message: String(error.message || error) });
    }
    progress();
  }

  for (const { folderId, orderedChildIds } of ops.reorders) {
    const folderNumber = done + 1;
    setStatus(`Reordering folder ${folderNumber} of ${total}…`);
    try {
      // Work against the live tree: ids may have vanished, and moving
      // within the same parent shifts indices, so update a local order model
      // after every move instead of re-reading the whole folder repeatedly.
      const existingChildren = await chromeCall("Read folder children", chrome.bookmarks.getChildren, folderId);
      const existing = new Set(existingChildren.map((c) => c.id));
      const desired = orderedChildIds.filter((id) => existing.has(id));
      const desiredSet = new Set(desired);
      const order = [
        ...desired,
        ...existingChildren.map((child) => child.id).filter((id) => !desiredSet.has(id)),
      ];
      for (let i = 0; i < desired.length; i++) {
        if (i % 10 === 0 || i === desired.length - 1) {
          setStatus(`Reordering folder ${folderNumber} of ${total}: ${i + 1} of ${desired.length}…`);
        }
        const currentIndex = order.indexOf(desired[i]);
        if (currentIndex === -1) continue;
        if (currentIndex !== i) {
          const [moved] = order.splice(currentIndex, 1);
          order.splice(i, 0, moved);
          await chromeCall("Move bookmark", chrome.bookmarks.move, moved, { parentId: folderId, index: i });
          counts.moved++;
        }
      }
    } catch (error) {
      errors.push({ op: "reorder", id: folderId, message: String(error.message || error) });
    }
    progress();
  }

  return { ok: errors.length === 0, counts, errors };
}

// --- Startup ------------------------------------------------------------

async function init() {
  els.pairingSave.addEventListener("click", savePairing);
  els.pairingInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") savePairing();
  });
  els.send.addEventListener("click", sendBookmarks);
  els.repair.addEventListener("click", async (event) => {
    event.preventDefault();
    await chrome.storage.local.remove(["pairing", "sessionId"]);
    pairing = null;
    stopPolling();
    setStatus("");
    showPairing();
  });

  const stored = await chrome.storage.local.get(["pairing", "sessionId"]);
  if (!stored.pairing) {
    showPairing();
    return;
  }
  pairing = stored.pairing;
  showMain();

  try {
    await ping();
  } catch {
    setStatus("Maruko isn't reachable. Open the app and select Chrome Extension in its sidebar.", "error");
    return;
  }

  if (stored.sessionId) {
    setStatus("Resuming…");
    startPolling(stored.sessionId);
  } else {
    setStatus("Connected to Maruko.", "ok");
  }
}

init();
