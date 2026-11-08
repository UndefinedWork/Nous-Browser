/* Interactive Nous Browser demo. */
(function () {
  const { pages, fav, info, esc, SITES } = window.NousSites;
  const W = 1180, H = 740;
  const SPRING = "cubic-bezier(.2, .9, .25, 1)";
  const win = document.getElementById("win");
  if (!win) return;

  const ic = (d) => `<svg class="ic" viewBox="0 0 16 16">${d}</svg>`;
  const I = {
    sidebar: ic('<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2.4"/><path d="M6 2.8v10.4"/>'),
    plus: ic('<path d="M8 3.2v9.6M3.2 8h9.6"/>'),
    x: ic('<path d="M4 4l8 8M12 4l-8 8"/>'),
    back: ic('<path d="M10 3.5 5.5 8l4.5 4.5"/>'),
    fwd: ic('<path d="M6 3.5 10.5 8 6 12.5"/>'),
    reload: ic('<path d="M12.8 8.6A4.9 4.9 0 1 1 11.4 4.4"/><path d="M12.2 2.4v2.8H9.4"/>'),
    library: ic('<rect x="2" y="2.8" width="12" height="3.4" rx="1"/><path d="M3 6.2v6.3a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V6.2M6.4 8.8h3.2"/>'),
    chev: ic('<path d="M6 3.5 10.5 8 6 12.5"/>'),
    folder: ic('<path d="M2 4.5a1 1 0 0 1 1-1h3l1.4 1.5H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z"/>'),
    search: ic('<circle cx="7" cy="7" r="4.6"/><path d="M10.4 10.4 14 14"/>'),
    globe: ic('<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c2 2 2 10 0 12M8 2c-2 2-2 10 0 12"/>'),
    star: ic('<path d="m8 1.8 1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z"/>'),
    check: ic('<path d="m3.5 8.4 3 3 6-6.6"/>'),
    link: ic('<path d="M7 9a3 3 0 0 0 4.2 0l2-2A3 3 0 0 0 9 2.8l-.8.8M9 7a3 3 0 0 0-4.2 0l-2 2A3 3 0 0 0 7 13.2l.8-.8"/>'),
    shot: ic('<path d="M2.5 5.5v-2a1 1 0 0 1 1-1h2M10.5 2.5h2a1 1 0 0 1 1 1v2M13.5 10.5v2a1 1 0 0 1-1 1h-2M5.5 13.5h-2a1 1 0 0 1-1-1v-2"/><circle cx="8" cy="8" r="2"/>'),
    arrow: ic('<path d="M3.5 12.5 12.5 3.5M6.5 3.5h6v6"/>'),
    rect: ic('<rect x="2.5" y="3.5" width="11" height="9" rx="1.5"/>'),
    text: ic('<path d="M3.5 4.5V3h9v1.5M8 3v10M6 13h4"/>'),
    num: ic('<circle cx="8" cy="8" r="5.5"/><path d="M7 6.2 8.3 5.4v5.2"/>'),
    blur: ic('<path d="M8 2s4 4.5 4 7.2A4 4 0 0 1 4 9.2C4 6.5 8 2 8 2z"/>'),
    undo: ic('<path d="M5 6.5h5a3 3 0 0 1 0 6H7"/><path d="M7 4 4.5 6.5 7 9"/>'),
    cursor: ic('<path d="M4 2.5v10l2.8-2.6 1.9 4 1.6-.7-1.9-4H12z"/>'),
    briefcase: ic('<rect x="2" y="5" width="12" height="8.5" rx="1.5"/><path d="M5.8 5V3.6a1 1 0 0 1 1-1h2.4a1 1 0 0 1 1 1V5M2 9h12"/>'),
    house: ic('<path d="M2.5 7.2 8 2.8l5.5 4.4M4 6v7h8V6"/><path d="M6.8 13v-3.2h2.4V13"/>'),
    book: ic('<path d="M8 4.2C6.6 3 4.6 2.8 2.5 3.2v9.6c2.1-.4 4.1-.2 5.5 1 1.4-1.2 3.4-1.4 5.5-1V3.2C11.4 2.8 9.4 3 8 4.2zM8 4.2v9.6"/>'),
    play: ic('<path d="M5.5 3.5v9l7-4.5z" fill="currentColor"/>'),
  };
  const SPACE_ICON = { briefcase: I.briefcase, house: I.house, book: I.book };
  const EMOJI = ["🚀", "✈️", "📚", "💼", "🎨", "🧪", "🏠", "⭐️"];
  const BGS = ["linear-gradient(135deg,#8ea3ea,#3f9de8)", "linear-gradient(160deg,#0b1f9a,#7fb2f0)", "linear-gradient(135deg,#f6d365,#fda085)", "linear-gradient(135deg,#fbc2eb,#a6c1ee)", "linear-gradient(135deg,#d4fc79,#96e6a1)", "linear-gradient(135deg,#e0c3fc,#8ec5fc)", "linear-gradient(135deg,#232526,#414345)", "#ffffff"];
  const COLORS = ["#ff3b30", "#ffcc00", "#2f7bf6", "#1d1d1f"];

  /* ---------------------------------------------------------------- */
  /* State                                                             */
  /* ---------------------------------------------------------------- */

  let uid = 0;
  const S = {
    spaces: [], cur: 0, mode: "expanded", tabs: {}, closed: [],
    bookmarks: [], shots: [], visits: [], downloads: [],
    lib: { sec: "screenshots", q: "" },
    ed: { tool: "arrow", color: COLORS[0] },
  };
  const mkTab = (entry) => { const id = "t" + (++uid); S.tabs[id] = { id, stack: [entry], idx: 0, rev: 0 }; return id; };
  const cur = (t) => t.stack[t.idx];
  const space = () => S.spaces[S.cur];
  const T = (e) => mkTab(e);
  const G = (name, icon, open, tabs) => ({ kind: "group", id: "g" + (++uid), name, icon, open, tabs });
  const R = (e) => ({ kind: "tab", id: T(e) });

  function seed() {
    const launch = G("Q4 Launch", "🚀", true, [T("notion"), T("figma"), T("docs")]);
    const trip = G("Lisbon trip", "✈️", false, [T("airbnb"), T("flights"), T("maps")]);
    S.spaces = [
      { id: "work", name: "Work", icon: "briefcase", pins: [T("gmail"), T("calendar"), T("slack"), T("linear")], items: [launch, R("github"), R("hn")] },
      { id: "personal", name: "Personal", icon: "house", pins: [T("youtube"), T("spotify"), T("reddit")], items: [trip, R("cooking")] },
      { id: "reading", name: "Reading", icon: "book", pins: [], items: [R("wikipedia"), G("Typography", "🎨", true, [T("youtube")]), R("hn")] },
    ];
    S.spaces[0].active = launch.tabs[0];
    S.spaces[1].active = trip.tabs[0];
    S.spaces[2].active = S.spaces[2].items[0].id;

    const now = Date.now();
    S.visits = [["github", 95], ["gmail", 80], ["calendar", 64], ["airbnb", 50], ["flights", 47], ["notion", 31], ["figma", 22], ["hn", 9]].map(([e, m]) => ({ entry: e, time: new Date(now - m * 60000) }));
    S.bookmarks = [["github", 3], ["wikipedia", 26], ["cooking", 50], ["airbnb", 90]].map(([e, h]) => ({ entry: e, time: new Date(now - h * 3600000) }));
    S.downloads = [
      { name: "Nous-Browser-1.4.5.dmg", kind: "DMG", size: 186.4, got: 186.4, from: "github.com" },
      { name: "Offsite-Agenda.pdf", kind: "PDF", size: 0.18, got: 0.18, from: "mail.google.com" },
      { name: "Lisbon-City-Guide.pdf", kind: "PDF", size: 24.6, got: 7.1, from: "visitlisboa.com" },
    ];
  }

  function locate(sp, tid) {
    let i = sp.pins.indexOf(tid);
    if (i > -1) return { arr: sp.pins, i, pinned: true };
    for (let k = 0; k < sp.items.length; k++) {
      const it = sp.items[k];
      if (it.kind === "tab" && it.id === tid) return { arr: sp.items, i: k, root: true };
      if (it.kind === "group") { const j = it.tabs.indexOf(tid); if (j > -1) return { arr: it.tabs, i: j, group: it }; }
    }
    return null;
  }
  const detach = (sp, tid) => { const L = locate(sp, tid); if (L) L.arr.splice(L.i, 1); return L; };
  const flat = (sp) => [...sp.pins, ...sp.items.flatMap((it) => (it.kind === "tab" ? [it.id] : it.tabs))];
  const groupById = (sp, gid) => sp.items.find((it) => it.id === gid);
  const titleOf = (entry) => info(entry, { shotTitle }).title;
  const hostOf = (entry) => info(entry).host;
  function shotTitle(id) { const s = S.shots.find((x) => x.id === id); return s ? `Screenshot ${fmtTime(s.time)}` : "Screenshot"; }
  const fmtTime = (d) => d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });

  /* ---------------------------------------------------------------- */
  /* Skeleton                                                          */
  /* ---------------------------------------------------------------- */

  win.innerHTML = `
    <aside class="sb">
      <div class="sb-top"><div class="lights"><i></i><i></i><i></i></div>
        <button class="icb" data-act="toggle-sidebar" data-tip="Toggle sidebar" data-kbd="⌘/">${I.sidebar}</button>
        <span class="sp"></span>
        <button class="icb" data-act="new-tab" data-tip="New tab" data-kbd="⌘T">${I.plus}</button></div>
      <div class="sb-body"><div class="sb-pane"></div></div>
      <div class="sb-bottom">
        <div class="navpill"><button data-act="back" data-tip="Back" data-kbd="⌘[">${I.back}</button><button data-act="fwd" data-tip="Forward" data-kbd="⌘]">${I.fwd}</button><button data-act="reload" data-tip="Reload" data-kbd="⌘R">${I.reload}</button></div>
        <div class="dots"></div>
        <button class="icb lib" data-act="library" data-tip="Library" data-kbd="⇧⌘L">${I.library}<span class="badge"></span></button>
      </div>
    </aside>
    <div class="page"><div class="page-stack"></div><div class="loadbar"></div><div class="space-hud"></div></div>
    <div class="peek"><div class="lights"><i></i><i></i><i></i></div><button class="icb" data-act="toggle-hidden" data-tip="Show sidebar" data-kbd="⌘.">${I.sidebar}</button></div>
    <div class="ov"><div class="toast"></div><div class="tip"></div></div>`;

  const $ = (s, r = win) => r.querySelector(s);
  const sbBody = $(".sb-body"), pageEl = $(".page"), stack = $(".page-stack"), ov = $(".ov");
  const toastEl = $(".toast"), tipEl = $(".tip");
  const pane = () => sbBody.lastElementChild;
  const scale = () => win.getBoundingClientRect().width / W || 1;
  const local = (x, y) => { const r = win.getBoundingClientRect(), s = r.width / W; return { x: (x - r.left) / s, y: (y - r.top) / s }; };
  const localRect = (el) => { const r = el.getBoundingClientRect(), a = local(r.left, r.top), s = scale(); return { x: a.x, y: a.y, w: r.width / s, h: r.height / s }; };

  /* ---------------------------------------------------------------- */
  /* Sidebar rendering                                                 */
  /* ---------------------------------------------------------------- */

  function tileHTML(sp, tid) {
    const t = S.tabs[tid];
    return `<div class="tile${sp.active === tid ? " sel" : ""}${t.unloaded ? " unloaded" : ""}" data-tab="${tid}" data-key="${tid}">${fav(cur(t), 16)}</div>`;
  }
  function rowHTML(sp, tid) {
    const t = S.tabs[tid], e = cur(t);
    return `<div class="row${sp.active === tid ? " sel" : ""}" data-tab="${tid}" data-key="${tid}">${fav(e, 16)}<span class="lbl">${esc(titleOf(e))}</span><button class="x" data-act="close" data-tab="${tid}" aria-label="Close tab">${I.x}</button></div>`;
  }
  function groupHTML(sp, g) {
    const shown = g.open ? g.tabs : g.tabs.filter((id) => id === sp.active);
    const contained = g.open || shown.length;
    return `<div class="group${g.open ? " open" : ""}${contained ? " contained" : ""}" data-key="${g.id}" data-group="${g.id}">
      <div class="ghead" data-act="group-toggle" data-gid="${g.id}"><span class="gicon">${g.icon ? esc(g.icon) : I.folder}</span><span class="gname">${esc(g.name)}</span><span class="gcount">${g.tabs.length}</span><span class="chev">${I.chev}</span></div>
      <div class="gbody">${shown.map((id) => rowHTML(sp, id)).join("")}${g.open && !g.tabs.length ? '<div class="gempty">Drag tabs here</div>' : ""}</div></div>`;
  }
  const paneHTML = (sp) => `<div class="pins" data-pins>${sp.pins.map((id) => tileHTML(sp, id)).join("")}</div>
    <div class="list" data-list>${sp.items.map((it) => (it.kind === "tab" ? rowHTML(sp, it.id) : groupHTML(sp, it))).join("")}</div>`;

  function rects(root) { const m = new Map(); root.querySelectorAll("[data-key]").forEach((el) => m.set(el.dataset.key, el.getBoundingClientRect())); return m; }

  function renderSidebar(opts = {}) {
    const sp = space();
    if (opts.dir) {
      const old = pane();
      const nw = document.createElement("div");
      nw.className = "sb-pane";
      nw.innerHTML = paneHTML(sp);
      sbBody.appendChild(nw);
      const d = opts.dir;
      nw.animate([{ transform: `translateX(${d * 45}%)`, opacity: 0 }, { transform: "none", opacity: 1 }], { duration: 460, easing: SPRING });
      if (old) old.animate([{ transform: "none", opacity: 1 }, { transform: `translateX(${-d * 45}%)`, opacity: 0 }], { duration: 360, easing: SPRING }).onfinish = () => old.remove();
      renderDots();
      return;
    }
    const p = pane();
    const before = rects(p);
    p.innerHTML = paneHTML(sp);
    if (drag && drag.on) { const src = p.querySelector(`[data-key="${drag.tid}"]`); if (src) src.classList.add("drag-src"); }
    if (opts.instant) return;
    const over = opts.from || {};
    const s = scale();
    const deltas = new Map();
    p.querySelectorAll("[data-key]").forEach((el) => {
      const k = el.dataset.key, b = over[k] || before.get(k), r = el.getBoundingClientRect();
      if (!b) { el.animate([{ opacity: 0, transform: "scale(.94)" }, { opacity: 1, transform: "none" }], { duration: 280, easing: SPRING }); return; }
      deltas.set(el, [(b.left - r.left) / s, (b.top - r.top) / s, b, r]);
    });
    deltas.forEach(([dx, dy, b, r], el) => {
      const par = el.parentElement.closest("[data-key]");
      if (par && deltas.has(par)) { dx -= deltas.get(par)[0]; dy -= deltas.get(par)[1]; }
      if (Math.abs(dx) > .5 || Math.abs(dy) > .5) el.animate([{ transform: `translate(${dx}px,${dy}px)` }, { transform: "none" }], { duration: 420, easing: SPRING });
      if (el.classList.contains("group") && Math.abs(b.height - r.height) > 1) {
        el.style.overflow = "hidden";
        el.animate([{ height: b.height / s + "px" }, { height: r.height / s + "px" }], { duration: 420, easing: SPRING }).onfinish = () => { el.style.overflow = ""; };
      }
    });
  }

  function renderDots() {
    $(".dots").innerHTML = S.spaces.map((sp, i) => `<button class="${i === S.cur ? "on" : ""}" data-act="space" data-i="${i}" data-tip="${esc(sp.name)}" data-kbd="${i === S.cur ? "" : "⌥⌘" + (i > S.cur ? "→" : "←")}"><i></i></button>`).join("");
  }

  function updateNav() {
    const t = S.tabs[space().active];
    $('[data-act="back"]').disabled = !t || t.idx === 0;
    $('[data-act="fwd"]').disabled = !t || t.idx >= t.stack.length - 1;
  }

  /* ---------------------------------------------------------------- */
  /* Page rendering                                                    */
  /* ---------------------------------------------------------------- */

  let shownKey = "";
  function siteHTML(entry) {
    const [key, arg] = String(entry).split(/:(.*)/);
    if (key === "library") return libraryHTML();
    if (key === "shot") return editorHTML(arg);
    return (pages[key] || pages.newtab)(arg);
  }
  function renderPage(force) {
    const sp = space(), t = S.tabs[sp.active];
    if (!t) return;
    const e = cur(t), key = `${t.id}|${e}|${t.rev}`;
    updateNav();
    if (key === shownKey && !force) return;
    shownKey = key;
    const v = document.createElement("div");
    v.className = "page-view in";
    v.innerHTML = siteHTML(e);
    stack.replaceChildren(v);
    const k = e.split(":")[0];
    if (k === "shot") mountEditor(v, e.slice(5));
    if (k === "library") { $(".lib", win).classList.remove("has-badge"); mountLibrary(v); }
  }
  function loadbar() { const b = $(".loadbar"); b.classList.remove("go"); void b.offsetWidth; b.classList.add("go"); }
  const visit = (entry) => { if (!/^(newtab|library|shot)/.test(entry)) S.visits.push({ entry, time: new Date() }); };

  function render(opts) { renderSidebar(opts); renderPage(); }

  /* ---------------------------------------------------------------- */
  /* Actions                                                           */
  /* ---------------------------------------------------------------- */

  function selectTab(tid) {
    const sp = space();
    if (!S.tabs[tid]) return;
    const t = S.tabs[tid];
    if (t.unloaded) { t.unloaded = false; loadbar(); }
    if (sp.active === tid) return;
    sp.active = tid;
    render();
  }

  function insertAfterActive(sp, tid) {
    const L = sp.active && locate(sp, sp.active);
    if (L && !L.pinned) L.arr.splice(L.i + 1, 0, L.root ? { kind: "tab", id: tid } : tid);
    else sp.items.push({ kind: "tab", id: tid });
  }

  function newTab(entry = "newtab", { palette = entry === "newtab", after = false } = {}) {
    const sp = space(), tid = mkTab(entry);
    if (after) insertAfterActive(sp, tid); else sp.items.push({ kind: "tab", id: tid });
    sp.active = tid;
    if (entry !== "newtab") { loadbar(); visit(entry); }
    render();
    if (palette) openPalette("current");
    return tid;
  }

  function navigate(entry) {
    const sp = space(), t = S.tabs[sp.active];
    if (!t) return newTab(entry);
    t.stack = t.stack.slice(0, t.idx + 1).concat(entry);
    t.idx++;
    loadbar(); visit(entry);
    render();
  }
  function go(d) {
    const t = S.tabs[space().active];
    if (!t) return;
    const n = t.idx + d;
    if (n < 0 || n >= t.stack.length) return;
    t.idx = n; loadbar(); render();
  }
  function reload() { const t = S.tabs[space().active]; if (!t) return; t.rev++; loadbar(); renderPage(); }

  function closeTab(tid) {
    const sp = space();
    const L = locate(sp, tid);
    if (!L) return;
    const t = S.tabs[tid];
    if (L.pinned) {
      t.unloaded = true; t.stack = [t.stack[0]]; t.idx = 0;
      if (sp.active === tid) pickNeighbor(sp, tid, flat(sp).filter((id) => id !== tid));
      else renderSidebar();
      toast("Pinned tab unloaded. It stays in place.", I.check);
      return;
    }
    const order = flat(sp).filter((id) => !sp.pins.includes(id));
    const idx = order.indexOf(tid);
    const finish = () => {
      detach(sp, tid);
      S.closed.push({ tid, space: S.cur });
      if (sp.active === tid) {
        const rest = order.filter((id) => id !== tid);
        const next = rest[Math.min(idx, rest.length - 1)] || sp.pins[0];
        if (next) { sp.active = next; S.tabs[next].unloaded = false; render(); }
        else newTab("newtab", { palette: false });
      } else renderSidebar();
    };
    const el = pane().querySelector(`[data-key="${tid}"]`);
    if (el) { el.classList.add("leaving"); setTimeout(finish, 150); } else finish();
  }
  function pickNeighbor(sp, tid, candidates) {
    const next = candidates.find((id) => !S.tabs[id].unloaded) || candidates[0];
    if (next) { sp.active = next; render(); } else newTab("newtab", { palette: false });
  }
  function reopen() {
    const c = S.closed.pop();
    if (!c) return toast("No recently closed tabs");
    if (c.space !== S.cur) switchSpace(c.space - S.cur, true);
    const sp = space();
    sp.items.push({ kind: "tab", id: c.tid });
    sp.active = c.tid; loadbar(); render();
  }

  function setMode(m) {
    if (S.mode === m) return;
    if (m === "hidden") S.prevMode = S.mode;
    S.mode = m;
    win.dataset.mode = m;
    hideTip();
  }
  const toggleCompact = () => setMode(S.mode === "expanded" ? "compact" : "expanded");
  const toggleHidden = () => setMode(S.mode === "hidden" ? S.prevMode || "expanded" : "hidden");

  let spaceLock = false;
  function switchSpace(d, instant) {
    const n = S.spaces.length;
    const to = ((S.cur + d) % n + n) % n;
    if (to === S.cur) return;
    S.cur = to;
    closeOverlays();
    renderSidebar({ dir: d > 0 ? 1 : -1 });
    renderPage();
    if (!instant) {
      const hud = $(".space-hud");
      const sp = space();
      hud.innerHTML = `${SPACE_ICON[sp.icon]}<span>${esc(sp.name)}</span>`;
      hud.classList.remove("show"); void hud.offsetWidth; hud.classList.add("show");
    }
  }

  function openLibrary(sec) {
    if (sec) S.lib.sec = sec;
    const sp = space();
    const existing = flat(sp).find((id) => cur(S.tabs[id]) === "library");
    if (existing) { if (sp.active === existing) { shownKey = ""; renderPage(); } else selectTab(existing); }
    else newTab("library", { palette: false });
  }

  function toggleBookmark() {
    const t = S.tabs[space().active];
    if (!t) return;
    const e = cur(t);
    if (/^(newtab|library|shot)/.test(e)) return toast("This page can't be bookmarked");
    const i = S.bookmarks.findIndex((b) => b.entry === e);
    if (i > -1) { S.bookmarks.splice(i, 1); toast("Removed from bookmarks", I.star); }
    else { S.bookmarks.unshift({ entry: e, time: new Date() }); toast("Added to bookmarks", I.star); }
  }
  function copyLink(tid) {
    const t = S.tabs[tid || space().active];
    if (!t) return;
    const h = hostOf(cur(t));
    if (h && navigator.clipboard) navigator.clipboard.writeText(h.startsWith("nous") ? h : "https://" + h).catch(() => {});
    toast("Link copied", I.link);
  }

  function pinTab(tid) { const sp = space(); detach(sp, tid); sp.pins.push(tid); renderSidebar(); }
  function unpinTab(tid) { const sp = space(); detach(sp, tid); sp.items.unshift({ kind: "tab", id: tid }); S.tabs[tid].unloaded = false; renderSidebar(); }
  function moveToGroup(tid, gid) { const sp = space(); const g = groupById(sp, gid); detach(sp, tid); g.tabs.push(tid); renderSidebar(); }
  function removeFromGroup(tid) {
    const sp = space(); const L = locate(sp, tid);
    const gi = sp.items.indexOf(L.group);
    detach(sp, tid); sp.items.splice(gi + 1, 0, { kind: "tab", id: tid }); renderSidebar();
  }
  function duplicate(tid) {
    const sp = space(), src = S.tabs[tid];
    const id = mkTab(cur(src));
    const L = locate(sp, tid);
    if (L.pinned) sp.items.unshift({ kind: "tab", id });
    else L.arr.splice(L.i + 1, 0, L.root ? { kind: "tab", id } : id);
    sp.active = id; render();
  }
  function newGroup(tid) {
    const sp = space();
    const g = G("New group", "", true, []);
    if (tid) {
      const L = locate(sp, tid);
      const at = L && L.root ? L.i : sp.items.length;
      detach(sp, tid); g.tabs.push(tid);
      sp.items.splice(Math.min(at, sp.items.length), 0, g);
    } else sp.items.push(g);
    renderSidebar();
    setTimeout(() => renameGroup(g.id), 60);
  }
  function renameGroup(gid) {
    const g = groupById(space(), gid);
    const el = pane().querySelector(`[data-gid="${gid}"] .gname`);
    if (!g || !el) return;
    if (S.mode === "compact") setMode("expanded");
    el.innerHTML = `<input value="${esc(g.name)}" maxlength="40">`;
    const inp = el.firstChild;
    inp.focus({ preventScroll: true }); inp.select();
    const done = (commit) => { if (commit && inp.value.trim()) g.name = inp.value.trim(); inp.onblur = null; renderSidebar({ instant: true }); };
    inp.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter") done(true); if (e.key === "Escape") done(false); });
    inp.addEventListener("pointerdown", (e) => e.stopPropagation());
    inp.addEventListener("click", (e) => e.stopPropagation());
    inp.onblur = () => done(true);
  }
  function ungroup(gid) {
    const sp = space(); const i = sp.items.findIndex((it) => it.id === gid);
    const g = sp.items[i];
    sp.items.splice(i, 1, ...g.tabs.map((id) => ({ kind: "tab", id })));
    renderSidebar();
  }
  function closeGroup(gid) {
    const sp = space(); const g = groupById(sp, gid);
    const had = g.tabs.includes(sp.active);
    sp.items.splice(sp.items.indexOf(g), 1);
    g.tabs.forEach((id) => S.closed.push({ tid: id, space: S.cur }));
    if (had) { const rest = flat(sp).filter((id) => !sp.pins.includes(id)); if (rest[0]) { sp.active = rest[0]; render(); } else newTab("newtab", { palette: false }); }
    else renderSidebar();
  }

  let toastTimer;
  function toast(msg, icon = "") {
    toastEl.innerHTML = `${icon}<span>${esc(msg)}</span>`;
    toastEl.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove("show"), 1900);
  }

  /* ---------------------------------------------------------------- */
  /* Clicks                                                            */
  /* ---------------------------------------------------------------- */

  win.addEventListener("click", (e) => {
    const a = e.target.closest("[data-act]");
    if (a && win.contains(a)) return act(a.dataset.act, a, e);
    const n = e.target.closest("[data-nav]");
    if (n) navigate(n.dataset.nav);
  });

  function act(name, el, e) {
    switch (name) {
      case "toggle-sidebar": return S.mode === "hidden" ? setMode("expanded") : toggleCompact();
      case "toggle-hidden": return toggleHidden();
      case "new-tab": return newTab();
      case "back": return go(-1);
      case "fwd": return go(1);
      case "reload": return reload();
      case "library": return openLibrary();
      case "space": return switchSpace(+el.dataset.i - S.cur);
      case "close": e.stopPropagation(); return closeTab(el.dataset.tab);
      case "group-toggle": {
        if (justDragged) return;
        const g = groupById(space(), el.dataset.gid);
        if (g) { g.open = !g.open; renderSidebar(); }
        return;
      }
      case "palette": return openPalette("current");
      case "todo": return el.classList.toggle("done");
      case "heart": e.stopPropagation(); el.classList.toggle("on"); return toast(el.classList.contains("on") ? "Saved to Wishlist" : "Removed from Wishlist", I.check);
      case "play": {
        const p = el.closest(".yt-player");
        if (p) p.classList.toggle("playing"); else toast("Playing Discover Weekly", I.play);
        return;
      }
      case "lib-sec": S.lib.sec = el.dataset.sec; return renderLibraryBody(true);
      case "open-entry": return newTab(el.dataset.entry, { palette: false, after: true });
      case "open-shot": return openShot(el.dataset.id);
      case "rec": return toast("Recordings open in the editor in the app", I.play);
      case "cap-full": return finishCapture(null);
      case "cap-cancel": return closeOverlays();
      default: if (name.startsWith("ed-")) return editorAct(name, el);
    }
  }

  /* ---------------------------------------------------------------- */
  /* Drag and drop                                                     */
  /* ---------------------------------------------------------------- */

  let drag = null, justDragged = false;
  win.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    const el = e.target.closest(".sb [data-tab]");
    if (!el || e.target.closest(".x")) return;
    drag = { tid: el.dataset.tab, x0: e.clientX, y0: e.clientY, on: false, target: null };
  });
  window.addEventListener("pointermove", (e) => {
    if (!drag) return;
    if (!drag.on) { if (Math.hypot(e.clientX - drag.x0, e.clientY - drag.y0) < 5) return; startDrag(); }
    moveDrag(e);
  });
  window.addEventListener("pointerup", (e) => {
    if (!drag) return;
    const d = drag;
    if (d.on) endDrag(e); else { drag = null; selectTab(d.tid); }
    drag = null;
  });
  window.addEventListener("pointercancel", () => { if (drag && drag.on) cancelDrag(); drag = null; });

  function startDrag() {
    drag.on = true;
    hideTip(); closeMenus();
    win.classList.add("is-dragging");
    const src = pane().querySelector(`[data-key="${drag.tid}"]`);
    if (src) src.classList.add("drag-src");
    const t = S.tabs[drag.tid];
    const g = document.createElement("div");
    g.className = "ghost";
    g.innerHTML = `${fav(cur(t), 16)}<span>${esc(titleOf(cur(t)))}</span>`;
    ov.appendChild(g);
    drag.ghost = g;
  }

  function moveDrag(e) {
    const p = local(e.clientX, e.clientY);
    drag.ghost.style.transform = `translate(${p.x - 20}px, ${p.y - 16}px) rotate(-1.5deg)`;
    const t = hitTest(e);
    drag.target = t;
    paintTarget(t);
    clearTimeout(drag.hoverTimer);
    if (t && t.type === "group") {
      const g = groupById(space(), t.gid);
      if (g && !g.open) drag.hoverTimer = setTimeout(() => { g.open = true; renderSidebar(); }, 480);
    }
  }

  function hitTest(e) {
    const p = pane(), sb = $(".sb").getBoundingClientRect();
    if (S.mode === "hidden" || e.clientX < sb.left - 10 || e.clientX > sb.right + 24 || e.clientY < sb.top || e.clientY > sb.bottom) return null;
    const pins = p.querySelector("[data-pins]");
    const pr = pins.getBoundingClientRect();
    if (e.clientY < pr.bottom + 4 && (pr.height > 0 || win.classList.contains("is-dragging"))) {
      const tiles = [...pins.querySelectorAll(".tile")].filter((el) => el.dataset.tab !== drag.tid);
      let index = tiles.length;
      for (let i = 0; i < tiles.length; i++) {
        const r = tiles[i].getBoundingClientRect();
        if (e.clientY < r.top || (e.clientY < r.bottom && e.clientX < r.left + r.width / 2)) { index = i; break; }
      }
      return { type: "pin", index, el: tiles[index], tiles };
    }
    const slots = [];
    p.querySelectorAll("[data-list] > *").forEach((el) => {
      if (el.classList.contains("row")) { if (el.dataset.tab !== drag.tid) slots.push({ el, kind: "root", tid: el.dataset.tab }); }
      else if (el.classList.contains("group")) {
        const head = el.querySelector(".ghead");
        slots.push({ el: head, kind: "ghead", gid: el.dataset.group, group: el });
        el.querySelectorAll(".gbody > .row").forEach((r) => { if (r.dataset.tab !== drag.tid) slots.push({ el: r, kind: "ingroup", gid: el.dataset.group, tid: r.dataset.tab }); });
      }
    });
    for (const s of slots) {
      const r = s.el.getBoundingClientRect();
      if (s.kind === "ghead" && e.clientY > r.top + 7 && e.clientY < r.bottom - 5) return { type: "group", gid: s.gid, el: s.group };
      if (e.clientY < r.top + r.height / 2) {
        if (s.kind === "root") return { type: "before-root", tid: s.tid, el: s.el };
        if (s.kind === "ghead") return { type: "before-group", gid: s.gid, el: s.group };
        return { type: "before-in", gid: s.gid, tid: s.tid, el: s.el };
      }
    }
    return { type: "end" };
  }

  function paintTarget(t) {
    const p = pane();
    p.querySelectorAll(".drop").forEach((el) => el.classList.remove("drop"));
    let line = p.querySelector(".drop-line");
    if (!t || t.type === "group" || t.type === "pin") {
      if (line) line.remove();
      if (t && t.type === "group") t.el.classList.add("drop");
      if (t && t.type === "pin") p.querySelector("[data-pins]").classList.add("drop");
      return;
    }
    if (!line) { line = document.createElement("div"); line.className = "drop-line"; p.appendChild(line); }
    const s = scale(), pr = p.getBoundingClientRect();
    let ref, y;
    if (t.type === "end") {
      const last = p.querySelector("[data-list]").lastElementChild;
      const lr = (last || p.querySelector("[data-list]")).getBoundingClientRect();
      ref = lr; y = (lr.bottom - pr.top) / s + 1;
    } else { ref = t.el.getBoundingClientRect(); y = (ref.top - pr.top) / s - 1.5; }
    line.style.top = y + p.scrollTop + "px";
    line.style.left = (ref.left - pr.left) / s + 6 + "px";
    line.style.width = Math.max(20, ref.width / s - 12) + "px";
  }

  function cancelDrag() {
    clearTimeout(drag.hoverTimer);
    win.classList.remove("is-dragging");
    drag.ghost && drag.ghost.remove();
    renderSidebar({ instant: true });
  }

  function endDrag() {
    clearTimeout(drag.hoverTimer);
    const sp = space(), tid = drag.tid, t = drag.target;
    const ghostRect = drag.ghost.getBoundingClientRect();
    drag.ghost.remove();
    win.classList.remove("is-dragging");
    justDragged = true; setTimeout(() => (justDragged = false), 50);
    if (!t) { drag.on = false; return renderSidebar(); }
    const wasPinned = sp.pins.includes(tid);
    detach(sp, tid);
    if (t.type === "pin") sp.pins.splice(Math.min(t.index, sp.pins.length), 0, tid);
    else if (t.type === "group") { const g = groupById(sp, t.gid); g.tabs.push(tid); }
    else if (t.type === "before-root") sp.items.splice(sp.items.findIndex((it) => it.kind === "tab" && it.id === t.tid), 0, { kind: "tab", id: tid });
    else if (t.type === "before-group") sp.items.splice(sp.items.findIndex((it) => it.id === t.gid), 0, { kind: "tab", id: tid });
    else if (t.type === "before-in") { const g = groupById(sp, t.gid); g.tabs.splice(g.tabs.indexOf(t.tid), 0, tid); }
    else sp.items.push({ kind: "tab", id: tid });
    if (wasPinned && t.type !== "pin") S.tabs[tid].unloaded = false;
    drag.on = false;
    renderSidebar({ from: { [tid]: ghostRect } });
    if (t.type === "pin" && !wasPinned) toast("Pinned. It stays here across windows.", I.check);
  }

  /* Two-finger horizontal swipe on the sidebar switches Spaces */
  let swipeAcc = 0, swipeT;
  sbBody.addEventListener("wheel", (e) => {
    if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
    e.preventDefault();
    swipeAcc += e.deltaX;
    clearTimeout(swipeT); swipeT = setTimeout(() => (swipeAcc = 0), 180);
    if (!spaceLock && Math.abs(swipeAcc) > 50) {
      switchSpace(swipeAcc > 0 ? 1 : -1);
      spaceLock = true; swipeAcc = 0;
      setTimeout(() => (spaceLock = false), 650);
    }
  }, { passive: false });

  /* ---------------------------------------------------------------- */
  /* Tooltips                                                          */
  /* ---------------------------------------------------------------- */

  let tipTimer, tipFor = null;
  win.addEventListener("pointerover", (e) => {
    if (drag && drag.on) return;
    const el = e.target.closest("[data-tip], .sb .tile, .sb .row, .sb .ghead");
    if (el === tipFor) return;
    hideTip();
    if (!el) return;
    const compact = S.mode === "compact";
    if (el.classList.contains("row") && !compact) return;
    if (el.classList.contains("ghead") && !compact) return;
    tipFor = el;
    tipTimer = setTimeout(() => showTip(el), 300);
  });
  win.addEventListener("pointerleave", hideTip);
  win.addEventListener("pointerdown", hideTip);
  function showTip(el) {
    let text = el.dataset.tip, kbd = el.dataset.kbd || "";
    if (el.dataset.tab) text = titleOf(cur(S.tabs[el.dataset.tab]));
    if (el.classList.contains("ghead")) { const g = groupById(space(), el.dataset.gid); text = g ? g.name : ""; kbd = ""; }
    if (!text) return;
    tipEl.innerHTML = `${esc(text)}${kbd ? `<kbd>${kbd}</kbd>` : ""}`;
    const r = localRect(el);
    const inList = el.closest(".sb-body");
    let x, y;
    if (inList) { x = r.x + r.w + 8; y = r.y + r.h / 2 - 13; tipEl.style.transformOrigin = "left center"; }
    else if (el.closest(".sb-bottom")) { x = r.x; y = r.y - 34; tipEl.style.transformOrigin = "left bottom"; }
    else { x = r.x; y = r.y + r.h + 6; tipEl.style.transformOrigin = "left top"; }
    tipEl.style.left = Math.min(x, W - 200) + "px";
    tipEl.style.top = y + "px";
    tipEl.classList.add("show");
  }
  function hideTip() { clearTimeout(tipTimer); tipFor = null; tipEl.classList.remove("show"); }

  /* ---------------------------------------------------------------- */
  /* Context menus                                                     */
  /* ---------------------------------------------------------------- */

  function closeMenus() { ov.querySelectorAll(".menu").forEach((m) => m.remove()); }
  function showMenu(x, y, items) {
    closeMenus(); hideTip();
    const m = document.createElement("div");
    m.className = "menu";
    m.innerHTML = items.map((it, i) => it === "-" ? '<div class="ms"></div>'
      : it.head ? `<div class="mh">${esc(it.head)}</div>`
      : it.emojis ? `<div class="emojis">${EMOJI.map((em) => `<button data-emoji="${em}">${em}</button>`).join("")}</div>`
      : `<button class="mi" data-mi="${i}" ${it.disabled ? "disabled" : ""}>${esc(it.label)}${it.kbd ? `<kbd>${it.kbd}</kbd>` : ""}</button>`).join("");
    ov.appendChild(m);
    const w = m.offsetWidth, h = m.offsetHeight;
    m.style.left = Math.min(x, W - w - 8) + "px";
    m.style.top = Math.min(y, H - h - 8) + "px";
    m.addEventListener("click", (e) => {
      e.stopPropagation();
      const b = e.target.closest("[data-mi]");
      if (b) { closeMenus(); items[+b.dataset.mi].run(); }
      const em = e.target.closest("[data-emoji]");
      if (em) { closeMenus(); const it = items.find((i) => i.emojis); it.emojis(em.dataset.emoji); }
    });
  }
  window.addEventListener("pointerdown", (e) => { if (!e.target.closest(".menu")) closeMenus(); }, true);

  win.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const p = local(e.clientX, e.clientY);
    const sp = space();
    const tabEl = e.target.closest(".sb [data-tab]");
    const gEl = e.target.closest(".sb .ghead");
    if (tabEl) {
      const tid = tabEl.dataset.tab, L = locate(sp, tid);
      const marked = S.bookmarks.some((b) => b.entry === cur(S.tabs[tid]));
      const groups = sp.items.filter((it) => it.kind === "group" && it !== L.group);
      const items = [
        L.pinned ? { label: "Unpin Tab", run: () => unpinTab(tid) } : { label: "Pin Tab", run: () => pinTab(tid) },
        "-",
        { label: "New Group with Tab", kbd: "⌥⌘N", run: () => newGroup(tid) },
        ...groups.map((g) => ({ label: `Move to ${g.icon ? g.icon + " " : ""}${g.name}`, run: () => moveToGroup(tid, g.id) })),
        ...(L.group ? [{ label: "Remove from Group", run: () => removeFromGroup(tid) }] : []),
        "-",
        { label: marked ? "Remove Bookmark" : "Add Bookmark", kbd: "⌘D", run: () => { const a = sp.active; sp.active = tid; toggleBookmark(); sp.active = a; } },
        { label: "Copy Link", kbd: "⇧⌘C", run: () => copyLink(tid) },
        { label: "Duplicate Tab", run: () => duplicate(tid) },
        "-",
        { label: L.pinned ? "Unload Tab" : "Close Tab", kbd: "⌘W", run: () => closeTab(tid) },
      ];
      return showMenu(p.x, p.y, items);
    }
    if (gEl) {
      const gid = gEl.dataset.gid;
      return showMenu(p.x, p.y, [
        { label: "Rename Group…", run: () => renameGroup(gid) },
        { head: "Icon" },
        { emojis: (em) => { groupById(sp, gid).icon = em; renderSidebar({ instant: true }); } },
        { label: "Use Folder Icon", run: () => { groupById(sp, gid).icon = ""; renderSidebar({ instant: true }); } },
        "-",
        { label: "Ungroup", run: () => ungroup(gid) },
        { label: "Close Group", run: () => closeGroup(gid) },
      ]);
    }
    if (e.target.closest(".sb")) {
      return showMenu(p.x, p.y, [
        { label: "New Tab", kbd: "⌘T", run: () => newTab() },
        { label: "New Group", kbd: "⌥⌘N", run: () => newGroup() },
        "-",
        { label: S.mode === "expanded" ? "Collapse Sidebar" : "Expand Sidebar", kbd: "⌘/", run: toggleCompact },
        { label: "Hide Sidebar", kbd: "⌘.", run: toggleHidden },
      ]);
    }
    if (e.target.closest(".page")) {
      const t = S.tabs[sp.active];
      return showMenu(p.x, p.y, [
        { label: "Back", kbd: "⌘[", disabled: !t || t.idx === 0, run: () => go(-1) },
        { label: "Forward", kbd: "⌘]", disabled: !t || t.idx >= t.stack.length - 1, run: () => go(1) },
        { label: "Reload", kbd: "⌘R", run: reload },
        "-",
        { label: "Add Bookmark", kbd: "⌘D", run: toggleBookmark },
        { label: "Copy Link", kbd: "⇧⌘C", run: () => copyLink() },
        { label: "Take Screenshot", kbd: "⌥⇧⌘S", run: startCapture },
        "-",
        { label: "Open Library", kbd: "⇧⌘L", run: () => openLibrary() },
      ]);
    }
  });

  /* ---------------------------------------------------------------- */
  /* Address palette                                                   */
  /* ---------------------------------------------------------------- */

  const CATALOG = Object.keys(SITES).filter((k) => SITES[k].name && !k.includes("-") && k !== "search");
  function closeOverlays() {
    let did = false;
    ov.querySelectorAll(".menu, .scrim, .palette, .cap").forEach((el) => { el.remove(); did = true; });
    return did;
  }
  function openPalette(mode) {
    closeOverlays();
    const pr = localRect(pageEl);
    const scrim = document.createElement("div");
    scrim.className = "scrim";
    const p = document.createElement("div");
    p.className = "palette";
    p.style.left = pr.x + pr.w / 2 + "px";
    const t = S.tabs[space().active];
    const curEntry = t ? cur(t) : "newtab";
    const preset = curEntry === "newtab" || /^(library|shot)/.test(curEntry) ? "" : hostOf(curEntry);
    p.innerHTML = `<div class="pin-row">${I.search}<input placeholder="Search or enter address" value="${esc(preset)}" spellcheck="false"></div><div class="pl"></div><div class="pf"><span>↑↓ to move</span><span>⏎ to open</span><span>esc to close</span></div>`;
    ov.append(scrim, p);
    const inp = p.querySelector("input"), list = p.querySelector(".pl");
    let opts = [], sel = 0;
    const update = () => {
      const q = inp.value.trim().toLowerCase();
      const visited = [...new Set(S.visits.slice().reverse().map((v) => v.entry))].filter((e) => CATALOG.includes(e));
      if (!q || q === preset.toLowerCase()) opts = (visited.length ? visited : CATALOG).slice(0, 6).map((k) => ({ entry: k }));
      else {
        const score = (k) => {
          const s = SITES[k], words = `${s.name} ${s.title}`.toLowerCase().split(/[^a-z0-9]+/);
          if (s.name.toLowerCase().startsWith(q) || s.host.startsWith(q)) return 0;
          if (words.some((w) => w.startsWith(q))) return 1;
          return `${s.title} ${s.host}`.toLowerCase().includes(q) ? 2 : 9;
        };
        const m = CATALOG.map((k) => [k, score(k)]).filter(([, sc]) => sc < 9).sort((a, b) => a[1] - b[1]).map(([k]) => ({ entry: k }));
        opts = [...m.slice(0, 5), { entry: "search:" + inp.value.trim(), search: true }];
      }
      sel = Math.min(sel, opts.length - 1);
      list.innerHTML = opts.map((o, i) => `<div class="po${i === sel ? " on" : ""}" data-i="${i}">${o.search ? I.search : fav(o.entry, 18)}<span class="t">${o.search ? `Search Google for “${esc(inp.value.trim())}”` : esc(SITES[o.entry].title)}</span><span class="h">${o.search ? "" : esc(SITES[o.entry].host.split("/")[0])}</span></div>`).join("");
    };
    const choose = (o) => { closeOverlays(); if (!o) return; mode === "new" ? newTab(o.entry, { palette: false }) : navigate(o.entry); };
    inp.addEventListener("input", () => { sel = 0; update(); });
    inp.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown") { sel = (sel + 1) % opts.length; update(); e.preventDefault(); }
      else if (e.key === "ArrowUp") { sel = (sel - 1 + opts.length) % opts.length; update(); e.preventDefault(); }
      else if (e.key === "Enter") { e.preventDefault(); choose(opts[sel]); }
      else if (e.key === "Escape") { e.preventDefault(); closeOverlays(); }
    });
    list.addEventListener("pointermove", (e) => { const o = e.target.closest(".po"); if (o && +o.dataset.i !== sel) { sel = +o.dataset.i; update(); } });
    list.addEventListener("click", (e) => { const o = e.target.closest(".po"); if (o) choose(opts[+o.dataset.i]); });
    scrim.addEventListener("pointerdown", () => closeOverlays());
    update();
    setTimeout(() => { inp.focus({ preventScroll: true }); inp.select(); }, 20);
  }

  /* ---------------------------------------------------------------- */
  /* Library                                                           */
  /* ---------------------------------------------------------------- */

  const SECS = [["bookmarks", "Bookmarks"], ["screenshots", "Screenshots"], ["recordings", "Recordings"], ["history", "History"], ["downloads", "Downloads"]];
  function libraryHTML() {
    return `<div class="lib-page"><div class="lib-head"><h1>Library</h1>
      <div class="lib-bar"><div class="seg">${SECS.map(([k, n]) => `<button data-act="lib-sec" data-sec="${k}" class="${S.lib.sec === k ? "on" : ""}">${n}</button>`).join("")}</div>
      <label class="lib-search">${I.search}<input placeholder="Search Library" value="${esc(S.lib.q)}" spellcheck="false"></label></div></div>
      <div class="lib-body"></div></div>`;
  }
  function mountLibrary(v) {
    const inp = v.querySelector(".lib-search input");
    inp.addEventListener("input", () => { S.lib.q = inp.value; renderLibraryBody(); });
    inp.addEventListener("keydown", (e) => e.stopPropagation());
    renderLibraryBody();
  }
  const match = (entry) => { const q = S.lib.q.trim().toLowerCase(); return !q || titleOf(entry).toLowerCase().includes(q) || hostOf(entry).toLowerCase().includes(q); };
  const ago = (d) => { const m = Math.round((Date.now() - d) / 60000); return m < 1 ? "Just now" : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} hr ago` : `${Math.round(m / 1440)} d ago`; };
  let dlTimer;
  function renderLibraryBody(segChanged) {
    const v = stack.querySelector(".lib-page");
    if (!v) return;
    if (segChanged) v.querySelectorAll(".seg button").forEach((b) => b.classList.toggle("on", b.dataset.sec === S.lib.sec));
    const body = v.querySelector(".lib-body");
    const sec = S.lib.sec;
    let html = "";
    if (sec === "bookmarks") {
      const list = S.bookmarks.filter((b) => match(b.entry));
      html = list.length ? `<div class="lib-list">${list.map((b) => `<div class="lib-row" data-act="open-entry" data-entry="${b.entry}">${fav(b.entry, 18)}<span class="t">${esc(titleOf(b.entry))}</span><span class="h">${esc(hostOf(b.entry).split("/")[0])}</span><span class="star">${I.star}</span><time>${ago(b.time)}</time></div>`).join("")}</div>` : empty("No bookmarks yet. Press ⌘D on any page.");
    } else if (sec === "screenshots") {
      const list = S.shots.filter((s) => match(s.entry) || shotTitle(s.id).toLowerCase().includes(S.lib.q.toLowerCase()));
      html = list.length ? `<div class="lib-grid">${list.map((s) => `<div class="lib-card${s.fresh ? " new" : ""}" data-act="open-shot" data-id="${s.id}"><div class="lib-thumb">${figHTML(s, 210, 130)}</div><b>${esc(shotTitle(s.id))}</b><small>${esc(SITES[s.entry.split(":")[0]]?.name || "Nous")} · ${Math.round(s.rect.w)} × ${Math.round(s.rect.h)}</small></div>`).join("")}</div>` : empty("No screenshots. Press ⌥⇧⌘S to capture one.");
      S.shots.forEach((s) => (s.fresh = false));
    } else if (sec === "recordings") {
      const recs = REC.filter((r) => match(r.entry));
      html = `<div class="lib-grid">${recs.map((r) => `<div class="lib-card" data-act="rec"><div class="lib-thumb">${figHTML(r, 210, 130)}<span class="rec-play">${I.play}</span><span class="rec-dur">${r.dur}</span></div><b>${esc(r.name)}</b><small>${esc(SITES[r.entry].name)} · ${r.when}</small></div>`).join("")}</div>`;
    } else if (sec === "history") {
      const list = S.visits.slice().reverse().filter((h) => match(h.entry));
      html = list.length ? `<div class="lib-sec">Today</div><div class="lib-list">${list.map((h) => `<div class="lib-row" data-act="open-entry" data-entry="${h.entry}"><time style="text-align:left;width:64px">${fmtTime(h.time)}</time>${fav(h.entry, 18)}<span class="t">${esc(titleOf(h.entry))}</span><span class="h">${esc(hostOf(h.entry).split("/")[0])}</span></div>`).join("")}</div>` : empty("Nothing matches your search.");
    } else {
      html = `<div class="lib-list">${S.downloads.map((d, i) => `<div class="lib-row" data-dl="${i}"><span class="dl-file">${d.kind}</span><div class="dl-meta">${esc(d.name)}<small>${dlText(d)}</small>${d.got < d.size ? `<div class="dl-bar"><i style="width:${(d.got / d.size) * 100}%"></i></div>` : ""}</div><span class="h" style="width:140px;text-align:right">${esc(d.from)}</span></div>`).join("")}</div>`;
    }
    body.innerHTML = html;
    clearInterval(dlTimer);
    if (sec === "downloads") dlTimer = setInterval(tickDownloads, 350);
  }
  const empty = (t) => `<div class="lib-empty">${esc(t)}</div>`;
  const dlText = (d) => d.got >= d.size ? `${d.size >= 1 ? d.size.toFixed(1) + " MB" : Math.round(d.size * 1000) + " KB"} · Done` : `${d.got.toFixed(1)} of ${d.size.toFixed(1)} MB · ${Math.max(1, Math.round((d.size - d.got) / 1.6))} sec left`;
  function tickDownloads() {
    const d = S.downloads.find((x) => x.got < x.size);
    const row = d && stack.querySelector(`[data-dl="${S.downloads.indexOf(d)}"]`);
    if (!d || !row) return clearInterval(dlTimer);
    d.got = Math.min(d.size, d.got + 0.55 + Math.random() * 0.5);
    row.querySelector("small").textContent = dlText(d);
    const bar = row.querySelector(".dl-bar");
    if (d.got >= d.size) { bar && bar.remove(); toast(`${d.name} downloaded`, I.check); }
    else bar.firstChild.style.width = (d.got / d.size) * 100 + "%";
  }

  /* ---------------------------------------------------------------- */
  /* Screenshots                                                       */
  /* ---------------------------------------------------------------- */

  let shotSeq = 0;
  function makeShot(entry, html, pw, ph, rect, extra = {}) {
    return Object.assign({ id: "s" + (++shotSeq), entry, html, pw, ph, rect, bg: 0, pad: 56, radius: 12, shadow: 45, ratio: "auto", notes: [], time: new Date() }, extra);
  }
  const PW = W - 236 - 8, PH = H - 16;
  let REC = [];
  function seedShots() {
    const mk = (entry, rect, extra) => makeShot(entry, pages[entry](), PW, PH, rect, extra);
    S.shots = [
      mk("airbnb", { x: 0, y: 76, w: PW, h: 520 }, { bg: 2, time: new Date(Date.now() - 42 * 60000), notes: [{ t: "num", x: 150, y: 210, c: "#ff3b30", n: 1 }, { t: "rect", x: 324, y: 152, w: 296, h: 330, c: "#ff3b30" }] }),
      mk("calendar", { x: 228, y: 60, w: 706, h: 440 }, { bg: 1, time: new Date(Date.now() - 3 * 3600000) }),
      mk("figma", { x: 200, y: 44, w: 540, h: 400 }, { bg: 5, time: new Date(Date.now() - 26 * 3600000) }),
    ];
    REC = [
      Object.assign(mk("notion", { x: 0, y: 0, w: PW, h: 560 }, { bg: 3 }), { name: "Launch plan walkthrough", dur: "0:48", when: "Today" }),
      Object.assign(mk("figma", { x: 0, y: 0, w: PW, h: 560 }, { bg: 1 }), { name: "Landing page review", dur: "1:32", when: "Yesterday" }),
    ];
  }

  function figHTML(sh, maxW, maxH) {
    const { w, h } = sh.rect, pad = sh.pad;
    let fw = w + pad * 2, fh = h + pad * 2;
    const r = { auto: 0, "16:9": 16 / 9, "4:3": 4 / 3, "1:1": 1 }[sh.ratio];
    if (r) { if (fw / fh < r) fw = fh * r; else fh = fw / r; }
    const k = Math.min(maxW / fw, maxH / fh, 1);
    const ix = ((fw - w) / 2) * k, iy = ((fh - h) / 2) * k;
    const shadow = sh.shadow ? `0 ${sh.shadow * 0.3 * k}px ${sh.shadow * 1.1 * k}px rgba(0,0,0,${0.1 + sh.shadow / 380})` : "none";
    return `<div class="fig" style="width:${fw * k}px;height:${fh * k}px;background:${BGS[sh.bg]};border-radius:${pad ? Math.max(4, 14 * k) : 0}px">
      <div class="img" style="left:${ix}px;top:${iy}px;width:${w * k}px;height:${h * k}px;border-radius:${sh.radius * k}px;box-shadow:${shadow}">
        <div class="clip" data-clip style="width:${w}px;height:${h}px;transform:scale(${k})">
          <div class="snap" style="left:${-sh.rect.x}px;top:${-sh.rect.y}px;width:${sh.pw}px;height:${sh.ph}px"><div class="page-view">${sh.html}</div></div>
          <div class="notes" data-notes>${notesHTML(sh)}</div>
        </div></div></div>`;
  }
  function notesHTML(sh) {
    let svg = "", out = "";
    sh.notes.forEach((n, i) => {
      if (n.t === "arrow") {
        const a = Math.atan2(n.y2 - n.y1, n.x2 - n.x1), L = 18, Wd = 10;
        const bx = n.x2 - Math.cos(a) * L, by = n.y2 - Math.sin(a) * L;
        const p1 = `${bx + Math.sin(a) * Wd},${by - Math.cos(a) * Wd}`, p2 = `${bx - Math.sin(a) * Wd},${by + Math.cos(a) * Wd}`;
        svg += `<line x1="${n.x1}" y1="${n.y1}" x2="${bx}" y2="${by}" stroke="${n.c}" stroke-width="5" stroke-linecap="round"/><polygon points="${n.x2},${n.y2} ${p1} ${p2}" fill="${n.c}" stroke="${n.c}" stroke-width="2" stroke-linejoin="round"/>`;
      } else if (n.t === "rect") out += `<div class="note-rect" style="--c:${n.c};left:${n.x}px;top:${n.y}px;width:${n.w}px;height:${n.h}px"></div>`;
      else if (n.t === "blur") out += `<div class="note-blur" style="left:${n.x}px;top:${n.y}px;width:${n.w}px;height:${n.h}px"></div>`;
      else if (n.t === "num") out += `<div class="note-num" style="--c:${n.c};left:${n.x}px;top:${n.y}px">${n.n}</div>`;
      else if (n.t === "text") out += `<div class="note-text" contenteditable="true" spellcheck="false" data-ni="${i}" style="--c:${n.c};left:${n.x}px;top:${n.y}px">${esc(n.s)}</div>`;
    });
    return out + `<svg viewBox="0 0 ${sh.rect.w} ${sh.rect.h}">${svg}</svg>`;
  }

  function startCapture() {
    closeOverlays(); hideTip();
    if (S.mode === "hidden") { /* page fills the window, fine */ }
    const pr = localRect(pageEl);
    const cap = document.createElement("div");
    cap.className = "cap";
    Object.assign(cap.style, { left: pr.x + "px", top: pr.y + "px", width: pr.w + "px", height: pr.h + "px", borderRadius: "12px" });
    cap.innerHTML = `<div class="hint">Drag to capture an area<button data-act="cap-full">Capture Page</button><button data-act="cap-cancel">Cancel</button></div>`;
    ov.appendChild(cap);
    let start = null, sel = null;
    cap.addEventListener("pointerdown", (e) => {
      if (e.target.closest(".hint")) return;
      e.preventDefault();
      const p = local(e.clientX, e.clientY);
      start = { x: p.x - pr.x, y: p.y - pr.y };
      sel = document.createElement("div"); sel.className = "sel"; sel.innerHTML = "<span></span>";
      cap.appendChild(sel); cap.classList.add("has-sel");
      cap.querySelector(".hint").style.display = "none";
      cap.setPointerCapture(e.pointerId);
    });
    cap.addEventListener("pointermove", (e) => {
      if (!start) return;
      const p = local(e.clientX, e.clientY);
      const x2 = Math.max(0, Math.min(pr.w, p.x - pr.x)), y2 = Math.max(0, Math.min(pr.h, p.y - pr.y));
      const r = { x: Math.min(start.x, x2), y: Math.min(start.y, y2), w: Math.abs(x2 - start.x), h: Math.abs(y2 - start.y) };
      Object.assign(sel.style, { left: r.x + "px", top: r.y + "px", width: r.w + "px", height: r.h + "px" });
      sel.firstChild.textContent = `${Math.round(r.w)} × ${Math.round(r.h)}`;
      sel.rect = r;
    });
    cap.addEventListener("pointerup", () => {
      if (!start) return;
      const r = sel.rect;
      start = null;
      if (!r || r.w < 30 || r.h < 30) { sel.remove(); cap.classList.remove("has-sel"); cap.querySelector(".hint").style.display = ""; return; }
      finishCapture(r);
    });
  }

  function finishCapture(rect) {
    const v = stack.querySelector(".page-view");
    if (!v) return;
    const pw = v.clientWidth, ph = v.clientHeight;
    rect = rect || { x: 0, y: 0, w: pw, h: ph };
    const t = S.tabs[space().active];
    const sh = makeShot(cur(t).startsWith("shot") ? "newtab" : cur(t), v.innerHTML, pw, ph, rect, { fresh: true });
    S.shots.unshift(sh);
    closeOverlays();
    const pr = localRect(pageEl);
    const f = document.createElement("div");
    f.className = "flash";
    Object.assign(f.style, { left: pr.x + rect.x + "px", top: pr.y + rect.y + "px", width: rect.w + "px", height: rect.h + "px", right: "auto", bottom: "auto" });
    ov.appendChild(f);
    setTimeout(() => f.remove(), 500);
    $(".lib").classList.add("has-badge");
    setTimeout(() => { newTab("shot:" + sh.id, { palette: false, after: true }); toast("Screenshot saved to Library", I.check); }, 320);
  }

  function openShot(id) {
    const sp = space();
    const existing = flat(sp).find((tid) => cur(S.tabs[tid]) === "shot:" + id);
    existing ? selectTab(existing) : newTab("shot:" + id, { palette: false, after: true });
  }

  const TOOLS = [["none", I.cursor, "Select"], ["arrow", I.arrow, "Arrow"], ["rect", I.rect, "Rectangle"], ["text", I.text, "Text"], ["num", I.num, "Step number"], ["blur", I.blur, "Blur"]];
  function editorHTML(id) {
    const sh = S.shots.find((s) => s.id === id);
    if (!sh) return pages.newtab();
    const range = (k, label, max) => `<div class="ed-group"><b>${label} <span data-v="${k}">${sh[k]}</span></b><input type="range" min="0" max="${max}" value="${sh[k]}" data-range="${k}"></div>`;
    return `<div class="ed" data-tool="${S.ed.tool}">
      <div class="ed-top"><h2>Screenshot</h2>
        <div class="ed-tools">${TOOLS.map(([k, icon, l]) => `<button data-act="ed-tool" data-tool="${k}" class="${S.ed.tool === k ? "on" : ""}" data-tip="${l}">${icon}</button>`).join("")}<span class="sep"></span>${COLORS.map((c) => `<button class="sw${S.ed.color === c ? " on" : ""}" data-act="ed-color" data-c="${c}"><i style="--c:${c}"></i></button>`).join("")}<span class="sep"></span><button data-act="ed-undo" data-tip="Undo">${I.undo}</button></div>
        <button class="ed-btn" data-act="ed-copy">Copy</button><button class="ed-btn primary" data-act="ed-save">Save</button></div>
      <div class="ed-main"><div class="ed-canvas" data-canvas></div>
        <aside class="ed-side">
          <div class="ed-group"><b>Background</b><div class="bgs">${BGS.map((b, i) => `<button data-act="ed-bg" data-i="${i}" class="${sh.bg === i ? "on" : ""}" style="background:${b}"></button>`).join("")}</div></div>
          ${range("pad", "Padding", 120)}${range("radius", "Corner radius", 40)}${range("shadow", "Shadow", 100)}
          <div class="ed-group"><b>Aspect ratio</b><div class="seg">${["auto", "16:9", "4:3", "1:1"].map((r) => `<button data-act="ed-ratio" data-r="${r}" class="${sh.ratio === r ? "on" : ""}">${r === "auto" ? "Auto" : r}</button>`).join("")}</div></div>
        </aside></div></div>`;
  }
  let edShot = null, edView = null;
  function drawFigure() {
    const c = edView.querySelector("[data-canvas]");
    c.innerHTML = figHTML(edShot, c.clientWidth - 40, c.clientHeight - 30);
  }
  function mountEditor(v, id) {
    edShot = S.shots.find((s) => s.id === id);
    edView = v;
    if (!edShot) return;
    drawFigure();
    v.querySelectorAll("[data-range]").forEach((inp) => inp.addEventListener("input", () => {
      edShot[inp.dataset.range] = +inp.value;
      v.querySelector(`[data-v="${inp.dataset.range}"]`).textContent = inp.value;
      drawFigure();
    }));
    const canvas = v.querySelector("[data-canvas]");
    let draft = null;
    canvas.addEventListener("pointerdown", (e) => {
      const clip = e.target.closest("[data-clip]");
      if (!clip || S.ed.tool === "none" || e.target.closest(".note-text")) return;
      e.preventDefault();
      const r = clip.getBoundingClientRect(), f = r.width / edShot.rect.w;
      const pt = (ev) => ({ x: (ev.clientX - r.left) / f, y: (ev.clientY - r.top) / f });
      const p = pt(e), c = S.ed.color, tool = S.ed.tool;
      if (tool === "num") {
        const n = edShot.notes.filter((x) => x.t === "num").length + 1;
        edShot.notes.push({ t: "num", x: p.x, y: p.y, c, n });
        return drawNotes();
      }
      if (tool === "text") {
        edShot.notes.push({ t: "text", x: p.x, y: p.y - 16, c, s: "Text" });
        drawNotes();
        const el = canvas.querySelector(`[data-ni="${edShot.notes.length - 1}"]`);
        if (el) { el.focus({ preventScroll: true }); document.getSelection().selectAllChildren(el); }
        return;
      }
      draft = tool === "arrow" ? { t: "arrow", x1: p.x, y1: p.y, x2: p.x, y2: p.y, c } : { t: tool, x: p.x, y: p.y, w: 0, h: 0, c, ox: p.x, oy: p.y };
      edShot.notes.push(draft);
      const move = (ev) => {
        const q = pt(ev);
        if (draft.t === "arrow") { draft.x2 = q.x; draft.y2 = q.y; }
        else { draft.x = Math.min(draft.ox, q.x); draft.y = Math.min(draft.oy, q.y); draft.w = Math.abs(q.x - draft.ox); draft.h = Math.abs(q.y - draft.oy); }
        drawNotes();
      };
      const up = () => {
        window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up);
        const tiny = draft.t === "arrow" ? Math.hypot(draft.x2 - draft.x1, draft.y2 - draft.y1) < 12 : draft.w < 8 || draft.h < 8;
        if (tiny) edShot.notes.splice(edShot.notes.indexOf(draft), 1);
        draft = null; drawNotes();
      };
      window.addEventListener("pointermove", move); window.addEventListener("pointerup", up);
    });
    canvas.addEventListener("input", (e) => { const el = e.target.closest(".note-text"); if (el) edShot.notes[+el.dataset.ni].s = el.textContent; });
    canvas.addEventListener("keydown", (e) => { if (e.target.closest(".note-text")) { e.stopPropagation(); if (e.key === "Enter" || e.key === "Escape") { e.preventDefault(); e.target.blur(); } } });
  }
  function drawNotes() { const n = edView && edView.querySelector("[data-notes]"); if (n) n.innerHTML = notesHTML(edShot); }
  function editorAct(name, el) {
    if (!edShot) return;
    if (name === "ed-tool") { S.ed.tool = el.dataset.tool; edView.querySelector(".ed").dataset.tool = S.ed.tool; edView.querySelectorAll('[data-act="ed-tool"]').forEach((b) => b.classList.toggle("on", b === el)); }
    else if (name === "ed-color") { S.ed.color = el.dataset.c; edView.querySelectorAll(".sw").forEach((b) => b.classList.toggle("on", b === el)); }
    else if (name === "ed-undo") { edShot.notes.pop(); drawNotes(); }
    else if (name === "ed-bg") { edShot.bg = +el.dataset.i; edView.querySelectorAll('[data-act="ed-bg"]').forEach((b) => b.classList.toggle("on", b === el)); drawFigure(); }
    else if (name === "ed-ratio") { edShot.ratio = el.dataset.r; edView.querySelectorAll('[data-act="ed-ratio"]').forEach((b) => b.classList.toggle("on", b === el)); drawFigure(); }
    else if (name === "ed-copy") toast("Copied to clipboard", I.check);
    else if (name === "ed-save") { toast("Saved to Library", I.check); }
  }

  /* ---------------------------------------------------------------- */
  /* Keyboard                                                          */
  /* ---------------------------------------------------------------- */

  let hovering = false, latched = false;
  win.addEventListener("pointerenter", () => (hovering = true));
  win.addEventListener("pointerleave", () => (hovering = false));
  window.addEventListener("pointerdown", (e) => { latched = win.contains(e.target); }, true);

  document.addEventListener("keydown", (e) => {
    if (!(hovering || latched)) return;
    const typing = e.target.tagName === "INPUT" || e.target.isContentEditable;
    if (e.key === "Escape") { if (closeOverlays()) e.preventDefault(); return; }
    const mod = e.metaKey || e.ctrlKey;
    if (!mod || (typing && !e.altKey && e.code !== "KeyL")) return;
    const sp = space(), c = e.code;
    let ok = true;
    if (e.altKey && e.shiftKey && c === "KeyS") startCapture();
    else if (e.altKey && (e.key === "ArrowRight" || e.key === "ArrowLeft")) switchSpace(e.key === "ArrowRight" ? 1 : -1);
    else if (e.altKey && c === "KeyN") newGroup();
    else if (e.shiftKey && c === "KeyL") openLibrary();
    else if (e.shiftKey && c === "KeyT") reopen();
    else if (e.shiftKey && c === "KeyC") copyLink();
    else if (e.shiftKey && (c === "BracketRight" || c === "BracketLeft")) cycle(c === "BracketRight" ? 1 : -1);
    else if (e.shiftKey || e.altKey) ok = false;
    else if (c === "KeyT") newTab();
    else if (c === "KeyW") closeTab(sp.active);
    else if (c === "KeyL") openPalette("current");
    else if (c === "Slash") S.mode === "hidden" ? setMode("expanded") : toggleCompact();
    else if (c === "Period") toggleHidden();
    else if (c === "KeyD") toggleBookmark();
    else if (c === "KeyR") reload();
    else if (c === "BracketLeft") go(-1);
    else if (c === "BracketRight") go(1);
    else if (/^Digit[1-9]$/.test(c)) { const order = flat(sp); const n = +c.slice(5); const id = n === 9 ? order[order.length - 1] : order[n - 1]; if (id) selectTab(id); }
    else ok = false;
    if (ok) { e.preventDefault(); e.stopPropagation(); }
  });
  function cycle(d) { const sp = space(), order = flat(sp); const i = order.indexOf(sp.active); selectTab(order[(i + d + order.length) % order.length]); }

  /* ---------------------------------------------------------------- */
  /* Fit + boot                                                        */
  /* ---------------------------------------------------------------- */

  const scaler = document.getElementById("demo-scaler");
  function fit() {
    const w = scaler.clientWidth;
    const s = Math.min(1, w / W);
    win.style.transform = `scale(${s})`;
    scaler.style.height = H * s + "px";
  }
  new ResizeObserver(fit).observe(scaler);
  fit();

  seed();
  seedShots();
  renderDots();
  renderSidebar({ instant: true });
  renderPage();

  function bootStagger(delay) {
    const els = [...pane().querySelectorAll(".tile, [data-list] > *")];
    els.forEach((el, i) => el.animate([{ opacity: 0, transform: "translateY(6px)" }, { opacity: 1, transform: "none" }], { duration: 600, delay: delay + i * 55, easing: SPRING, fill: "backwards" }));
    stack.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 700, delay: delay + 120, fill: "backwards" });
  }

  window.NousDemo = {
    boot: bootStagger,
    run(name) {
      latched = true;
      if (name === "compact") S.mode === "hidden" ? setMode("expanded") : toggleCompact();
      else if (name === "space") switchSpace(1);
      else if (name === "library") openLibrary("screenshots");
      else if (name === "screenshot") startCapture();
      else if (name === "palette") openPalette("current");
    },
  };
})();
