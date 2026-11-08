/* Mock websites rendered inside the Nous demo window.
   Every page is plain HTML styled by sites.css. Elements with data-nav="<entry>"
   navigate the current tab; data-act="<name>" calls a demo action. */
(function () {
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const av = (name, c) => `<span class="av" style="--c:${c}">${name.split(" ").map((p) => p[0]).join("").slice(0, 2)}</span>`;
  const ico = {
    search: '<svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.6"/><path d="M10.4 10.4 14 14"/></svg>',
    star: '<svg viewBox="0 0 16 16"><path d="m8 1.8 1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z"/></svg>',
    heart: '<svg viewBox="0 0 16 16"><path d="M8 13.6S2 10 2 5.9A3 3 0 0 1 8 4.6a3 3 0 0 1 6 1.3C14 10 8 13.6 8 13.6z"/></svg>',
    play: '<svg viewBox="0 0 16 16"><path d="M5 3.2v9.6L13 8z" fill="currentColor" stroke="none"/></svg>',
    back: '<svg viewBox="0 0 16 16"><path d="M10 3 5 8l5 5"/></svg>',
    check: '<svg viewBox="0 0 16 16"><path d="m3.5 8.4 3 3 6-6.6"/></svg>',
    pin: '<svg viewBox="0 0 16 16"><path d="M8 14.5s4.5-4.2 4.5-7.8a4.5 4.5 0 0 0-9 0c0 3.6 4.5 7.8 4.5 7.8z"/><circle cx="8" cy="6.6" r="1.6"/></svg>',
    plane: '<svg viewBox="0 0 16 16"><path d="M14.5 8 2 3l2.2 5L2 13z"/></svg>',
  };

  /* ---------------------------------------------------------------- */
  /* Catalog                                                           */
  /* ---------------------------------------------------------------- */

  const SITES = {
    newtab:   { title: "New Tab", host: "", fav: "nous" },
    library:  { title: "Library", host: "nous://library", fav: "library" },
    shot:     { title: "Screenshot", host: "nous://screenshot", fav: "shot" },
    gmail:    { title: "Inbox (3) – Gmail", host: "mail.google.com/mail/u/0/#inbox", color: "#EA4335", glyph: "M", name: "Gmail" },
    "gmail-thread": { title: "Offsite agenda — final version – Gmail", host: "mail.google.com/mail/u/0/#inbox/FMfcgzQ", color: "#EA4335", glyph: "M", name: "Gmail" },
    calendar: { title: "Google Calendar – Week of November 8, 2026", host: "calendar.google.com/calendar/r/week", color: "#1A73E8", glyph: "31", name: "Google Calendar" },
    slack:    { title: "#launch – Acme – Slack", host: "app.slack.com/client/T02A/C07LAUNCH", color: "#4A154B", glyph: "#", name: "Slack" },
    linear:   { title: "Launch › Issues – Linear", host: "linear.app/acme/team/LAU/active", color: "#5E6AD2", glyph: "L", name: "Linear" },
    notion:   { title: "Q4 Launch Plan – Notion", host: "notion.so/acme/Q4-Launch-Plan-8f2c", color: "#191919", glyph: "N", name: "Notion", light: true },
    figma:    { title: "Landing page – Figma", host: "figma.com/design/k2Q/Landing-page", color: "#A259FF", glyph: "F", name: "Figma" },
    docs:     { title: "Launch announcement – Google Docs", host: "docs.google.com/document/d/1hXq", color: "#4285F4", glyph: "D", name: "Google Docs" },
    github:   { title: "UndefinedWork/Nous-Browser", host: "github.com/UndefinedWork/Nous-Browser", color: "#1F2328", glyph: "G", name: "GitHub" },
    hn:       { title: "Hacker News", host: "news.ycombinator.com", color: "#FF6600", glyph: "Y", name: "Hacker News" },
    youtube:  { title: "How great typography works – YouTube", host: "youtube.com/watch?v=t9pe4", color: "#FF0033", glyph: "▶", name: "YouTube" },
    spotify:  { title: "Discover Weekly – Spotify", host: "open.spotify.com/playlist/37i9dQZEVX", color: "#1DB954", glyph: "S", name: "Spotify" },
    reddit:   { title: "r/MacApps – Reddit", host: "reddit.com/r/MacApps", color: "#FF4500", glyph: "r", name: "Reddit" },
    airbnb:   { title: "Lisbon · Stays – Airbnb", host: "airbnb.com/s/Lisbon/homes", color: "#FF385C", glyph: "A", name: "Airbnb" },
    flights:  { title: "SFO to LIS – Google Flights", host: "google.com/travel/flights", color: "#1A73E8", glyph: "✈", name: "Google Flights" },
    maps:     { title: "Alfama, Lisbon – Google Maps", host: "google.com/maps/place/Alfama", color: "#34A853", glyph: "⌖", name: "Google Maps" },
    cooking:  { title: "Lemony Orzo With Peas and Feta – NYT Cooking", host: "cooking.nytimes.com/recipes/1025", color: "#111111", glyph: "C", name: "NYT Cooking", serifGlyph: true },
    wikipedia:{ title: "Web browser – Wikipedia", host: "en.wikipedia.org/wiki/Web_browser", color: "#ffffff", glyph: "W", name: "Wikipedia", light: true, serifGlyph: true },
    search:   { title: "Google Search", host: "google.com/search", color: "#4285F4", glyph: "G", name: "Google" },
  };

  /* ---------------------------------------------------------------- */
  /* Pages                                                             */
  /* ---------------------------------------------------------------- */

  const P = {};

  P.newtab = () => `<div class="s-nt"><div class="nt-inner">
      <img class="nt-icon" src="assets/app-icon.png" alt="" width="48" height="48">
      <h1>Nous Browser</h1>
      <button class="nt-search" data-act="palette">${ico.search}<span>Search or enter URL</span><kbd>⌘L</kbd></button>
    </div></div>`;

  const mails = [
    [1, "Maya Patel", "Offsite agenda — final version", "Hi team, attached is the final agenda for Thursday. We start at 9:30 with coffee on the roof…", "10:42 AM", "gmail-thread"],
    [1, "Airbnb", "Your reservation in Lisbon is confirmed", "Pack your bags! Check-in for Casa do Fado is Nov 20 after 3:00 PM. Here's everything you need…", "9:58 AM", "airbnb"],
    [1, "Linear", "[LAU-142] Onboarding copy moved to In Review", "Daniel Kim moved LAU-142 from In Progress to In Review and requested your review.", "9:15 AM", "linear"],
    [0, "Figma", "Sofia left 4 comments on Landing page", "“Can we try the hero headline in serif? It feels calmer.” — Sofia Rossi", "Yesterday", "figma"],
    [0, "GitHub", "[UndefinedWork/Nous-Browser] Release 1.4.5", "Window corner radius setting. A new slider in Settings › Appearance…", "Yesterday", "github"],
    [0, "Ethan Brooks", "Re: Coffee next week?", "Tuesday works for me — Blue Bottle on Market at 8? I'll bring the launch deck.", "Nov 6", ""],
    [0, "Stripe", "Your weekly summary", "Gross volume is up 12% compared to last week. 3 new customers, 0 disputes.", "Nov 6", ""],
    [0, "Spotify", "Your Discover Weekly is ready", "30 new songs picked just for you, every Monday.", "Nov 5", "spotify"],
    [0, "United Airlines", "Trip reminder: San Francisco to Lisbon", "Your trip is coming up. Check in opens 24 hours before departure.", "Nov 4", "flights"],
    [0, "The New York Times", "The Morning: Your Tuesday briefing", "Here's what you need to know today, plus a recipe for a quick weeknight dinner.", "Nov 3", "cooking"],
  ];
  P.gmail = () => `<div class="s-gm">
    <header class="gm-top"><div class="gm-brand"><span class="gm-logo">M</span>Gmail</div>
      <div class="gm-search">${ico.search}<span>Search mail</span></div>${av("Jordan Chen", "#7a5af8")}</header>
    <div class="gm-body">
      <nav class="gm-nav"><div class="gm-compose"><svg viewBox="0 0 16 16"><path d="M11 2.5 13.5 5 6 12.5H3.5V10z"/></svg>Compose</div>
        <a class="on">Inbox<b>3</b></a><a>Starred</a><a>Snoozed</a><a>Sent</a><a>Drafts<b>1</b></a><a>Purchases</a>
        <div class="gm-lh">Labels</div><a><i style="--c:#16a34a"></i>Launch</a><a><i style="--c:#f59e0b"></i>Travel</a><a><i style="--c:#6366f1"></i>Receipts</a></nav>
      <section class="gm-list">
        <div class="gm-tabs"><span class="on">Primary</span><span>Promotions</span><span>Updates</span></div>
        ${mails.map(([u, f, s, sn, t, nav]) => `<div class="gm-row${u ? " unread" : ""}" ${nav ? `data-nav="${nav}"` : ""}>
          <span class="gm-star">${ico.star}</span><span class="gm-from">${esc(f)}</span>
          <span class="gm-sub"><b>${esc(s)}</b> — ${esc(sn)}</span><span class="gm-time">${t}</span></div>`).join("")}
      </section></div></div>`;

  P["gmail-thread"] = () => `<div class="s-gm">
    <header class="gm-top"><div class="gm-brand"><span class="gm-logo">M</span>Gmail</div>
      <div class="gm-search">${ico.search}<span>Search mail</span></div>${av("Jordan Chen", "#7a5af8")}</header>
    <div class="gm-body">
      <nav class="gm-nav"><div class="gm-compose"><svg viewBox="0 0 16 16"><path d="M11 2.5 13.5 5 6 12.5H3.5V10z"/></svg>Compose</div>
        <a class="on">Inbox<b>2</b></a><a>Starred</a><a>Snoozed</a><a>Sent</a><a>Drafts<b>1</b></a></nav>
      <section class="gm-list gm-thread">
        <button class="gm-back" data-act="back">${ico.back}</button>
        <h2>Offsite agenda — final version <span class="gm-chip">Inbox</span></h2>
        <div class="gm-msg-h">${av("Maya Patel", "#e8590c")}<div><b>Maya Patel</b> <span>&lt;maya@acme.co&gt;</span><br><span>to team</span></div><span class="gm-time">10:42 AM (12 minutes ago)</span></div>
        <div class="gm-msg">
          <p>Hi team,</p>
          <p>Attached is the final agenda for Thursday's offsite. We start at 9:30 with coffee on the roof, then split into three sessions: launch readiness, the onboarding flow, and planning for next year.</p>
          <p>Please skim the launch plan in Notion beforehand and add questions to the doc. Lunch is from Tartine — reply with any dietary needs by Wednesday.</p>
          <p>See you there,<br>Maya</p>
          <div class="gm-att"><span class="gm-pdf">PDF</span>Offsite-Agenda.pdf<em>184 KB</em></div>
        </div>
        <div class="gm-actions"><span>Reply</span><span>Forward</span></div>
      </section></div></div>`;

  P.calendar = () => {
    const days = [["Sun", 8], ["Mon", 9], ["Tue", 10], ["Wed", 11], ["Thu", 12], ["Fri", 13], ["Sat", 14]];
    const ev = [
      [0, 11, 1, "Brunch with Ava", "#33b679"],
      [1, 10, 1, "Design review", "#7986cb"], [1, 14, .5, "1:1 · Maya", "#039be5"],
      [2, 9.5, 1, "Launch sync", "#e67c73"], [2, 12, 1, "Lunch with Ethan", "#33b679"], [2, 15, 1.5, "Interview: Product designer", "#8e24aa"],
      [3, 13, 3, "Focus time", "#616161"],
      [4, 9.5, 6.5, "Team offsite · Ferry Building", "#f4511e"],
      [5, 11, 1, "Ship 1.5 🚀", "#e67c73"], [5, 16, 1, "Drinks", "#f6bf26"],
      [6, 10, 1.5, "Farmers market", "#33b679"],
    ];
    const hours = [8, 9, 10, 11, 12, 13, 14, 15, 16, 17];
    const lbl = (h) => (h === 12 ? "12 PM" : h > 12 ? `${h - 12} PM` : `${h} AM`);
    return `<div class="s-cal">
      <header class="cal-top"><span class="cal-logo">31</span><b>Calendar</b><span class="cal-btn">Today</span><span class="cal-arrows">‹ ›</span><h2>November 2026</h2><span class="cal-sp"></span><span class="cal-btn">Week ▾</span>${av("Jordan Chen", "#7a5af8")}</header>
      <div class="cal-body">
        <aside class="cal-side"><div class="cal-create">＋ Create</div>
          <div class="cal-mini"><b>November 2026</b><div class="cal-mg">${"SMTWTFS".split("").map((d) => `<i>${d}</i>`).join("")}${Array.from({ length: 30 }, (_, i) => `<span class="${i + 1 === 8 ? "today" : ""}">${i + 1}</span>`).join("")}</div></div>
          <div class="cal-cals"><b>My calendars</b><label><i style="--c:#039be5"></i>Jordan Chen</label><label><i style="--c:#33b679"></i>Personal</label><label><i style="--c:#e67c73"></i>Launch</label><label><i style="--c:#8e24aa"></i>Hiring</label></div></aside>
        <section class="cal-grid">
          <div class="cal-head"><span></span>${days.map(([d, n], i) => `<div class="${i === 0 ? "today" : ""}"><small>${d.toUpperCase()}</small><b>${n}</b></div>`).join("")}</div>
          <div class="cal-rows">
            <div class="cal-hours">${hours.map((h) => `<span>${lbl(h)}</span>`).join("")}</div>
            ${days.map((_, di) => `<div class="cal-col">${ev.filter((e) => e[0] === di).map((e) => `<div class="cal-ev" style="--c:${e[4]};top:calc(${e[1] - 8} * var(--hh));height:calc(${e[2]} * var(--hh) - 2px)"><b>${esc(e[3])}</b><span>${fmtH(e[1])} – ${fmtH(e[1] + e[2])}</span></div>`).join("")}</div>`).join("")}
            <div class="cal-now" style="top:calc(2.6 * var(--hh))"></div>
          </div></section></div></div>`;
  };
  function fmtH(h) { const hr = Math.floor(h), m = Math.round((h - hr) * 60); const ap = hr >= 12 ? "pm" : "am"; const h12 = hr > 12 ? hr - 12 : hr; return `${h12}${m ? ":" + String(m).padStart(2, "0") : ""}${ap}`; }

  P.slack = () => {
    const msgs = [
      ["Maya Patel", "#e8590c", "10:02 AM", "The landing page is up for review in Figma 🎉 Feedback by end of day, please.", [["🎉", 4], ["👀", 2]]],
      ["Daniel Kim", "#0b7285", "10:05 AM", "Love the serif headline. Onboarding copy is in <span class=\"sl-link\">LAU-142</span> — ready for a look.", []],
      ["Sofia Rossi", "#c2255c", "10:11 AM", "Pushed the new hero video. Recorded it in Nous, the click zoom did all the editing for me.", [["🔥", 5]]],
      ["Ethan Brooks", "#5f3dc4", "10:20 AM", "Press release draft is in Docs. It lives in the Q4 Launch group if you use Nous 😉", [["😂", 3], ["✅", 1]]],
      ["Maya Patel", "#e8590c", "10:24 AM", "Reminder: offsite is Thursday at 9:30. Agenda is in your inbox.", []],
    ];
    return `<div class="s-sl">
      <aside class="sl-side"><div class="sl-ws">Acme <span>▾</span></div>
        <div class="sl-sec">Channels</div><a># general</a><a># design</a><a class="on"># launch</a><a># random</a><a class="b"># customer-love</a>
        <div class="sl-sec">Direct messages</div><a><i class="dot on"></i>Maya Patel</a><a><i class="dot on"></i>Daniel Kim</a><a><i class="dot"></i>Sofia Rossi</a><a><i class="dot on"></i>Ethan Brooks</a></aside>
      <section class="sl-main"><header># launch <span>☆</span><em>12 members</em></header>
        <div class="sl-msgs"><div class="sl-day"><span>Today</span></div>
        ${msgs.map(([n, c, t, m, r]) => `<div class="sl-msg">${av(n, c)}<div><b>${n}</b><time>${t}</time><p>${m}</p>${r.length ? `<div class="sl-re">${r.map(([e, k]) => `<span>${e} ${k}</span>`).join("")}</div>` : ""}</div></div>`).join("")}</div>
        <div class="sl-compose">Message #launch<span>⌃⏎</span></div></section></div>`;
  };

  P.linear = () => {
    const g = [
      ["In Review", "#5e6ad2", "half", [["LAU-142", "Onboarding flow copy", "Copy", "Daniel Kim", "#0b7285", 3], ["LAU-139", "Landing page hero animation", "Web", "Sofia Rossi", "#c2255c", 2]]],
      ["In Progress", "#f2c94c", "prog", [["LAU-151", "Library search across bookmarks and history", "Feature", "Jordan Chen", "#7a5af8", 4], ["LAU-148", "Press kit screenshots", "Marketing", "Maya Patel", "#e8590c", 2], ["LAU-147", "Spaces swipe gesture polish", "Feature", "Jordan Chen", "#7a5af8", 3]]],
      ["Todo", "#b0b3bb", "todo", [["LAU-156", "Release notes for 1.5", "Docs", "Ethan Brooks", "#5f3dc4", 1], ["LAU-155", "Update App Store screenshots", "Marketing", "Sofia Rossi", "#c2255c", 2], ["LAU-153", "Crash on window restore with 40+ tabs", "Bug", "Daniel Kim", "#0b7285", 4], ["LAU-150", "Group icons: emoji picker", "Feature", "Maya Patel", "#e8590c", 1]]],
    ];
    const pri = (p) => `<span class="ln-pri">${[1, 2, 3].map((i) => `<i class="${i <= Math.min(p, 3) ? "on" : ""}" style="height:${3 + i * 2}px"></i>`).join("")}</span>`;
    return `<div class="s-ln">
      <aside class="ln-side"><div class="ln-ws"><span class="ln-logo">A</span>Acme</div>
        <a>Inbox<b>4</b></a><a>My issues</a><div class="ln-sec">Your teams</div><a class="t">◆ Launch</a><a class="on sub">Issues</a><a class="sub">Projects</a><a class="sub">Views</a><a class="t">◆ Web</a></aside>
      <section class="ln-main"><header><b>Launch</b><span>›</span>Active issues<div class="ln-tabs"><span class="on">All issues</span><span>Active</span><span>Backlog</span></div></header>
        ${g.map(([name, c, st, rows]) => `<div class="ln-group"><div class="ln-gh"><span class="ln-st ${st}" style="--c:${c}"></span>${name}<em>${rows.length}</em></div>
          ${rows.map(([id, t, l, who, ac, p]) => `<div class="ln-row">${pri(p)}<span class="ln-id">${id}</span><span class="ln-st ${st}" style="--c:${c}"></span><span class="ln-t">${esc(t)}</span><span class="ln-l">${l}</span>${av(who, ac)}<span class="ln-d">Nov ${8 + (id.charCodeAt(6) % 9)}</span></div>`).join("")}</div>`).join("")}
      </section></div>`;
  };

  P.notion = () => `<div class="s-no">
    <header class="no-top"><span>Acme</span> / <span>Projects</span> / <b>🚀 Q4 Launch Plan</b><span class="no-sp"></span><span>Share</span><span>☆</span><span>···</span></header>
    <div class="no-cover"></div>
    <article class="no-doc"><div class="no-emoji">🚀</div><h1>Q4 Launch Plan</h1>
      <div class="no-props"><span>Owner</span><div>${av("Maya Patel", "#e8590c")} Maya Patel</div><span>Launch date</span><div>November 13, 2026</div><span>Status</span><div><em class="no-tag">On track</em></div></div>
      <h2>Goals</h2><ul><li>Ship version 1.5 with Spaces sync and Library search.</li><li>Grow weekly active users to 25,000 by year end.</li><li>Publish the new landing page and press kit.</li></ul>
      <div class="no-callout"><span>💡</span>Keep the message simple: a calm browser that gives the web more room.</div>
      <h2>Checklist</h2>
      ${[["Final QA pass on macOS 26", 1], ["Landing page review", 1], ["Record the product video", 0], ["Send the press release", 0], ["Post on Hacker News and Reddit", 0]].map(([t, d]) => `<label class="no-todo${d ? " done" : ""}" data-act="todo"><i>${ico.check}</i>${t}</label>`).join("")}
      <h2>Timeline</h2>
      <div class="no-table"><span>Week</span><span>Milestone</span><span>Owner</span>${[["Nov 2", "Feature freeze", "Daniel"], ["Nov 9", "Landing page + press kit", "Sofia"], ["Nov 13", "Launch 🎉", "Maya"]].map((r) => r.map((c) => `<div>${c}</div>`).join("")).join("")}</div>
    </article></div>`;

  P.figma = () => `<div class="s-fg">
    <header class="fg-top"><div class="fg-tools"><span class="on">▲</span><span>#</span><span>□</span><span>✎</span><span>T</span><span>💬</span></div><div class="fg-name">Launch / <b>Landing page</b></div><div class="fg-r">${av("Sofia Rossi", "#c2255c")}${av("Maya Patel", "#e8590c")}<span class="fg-share">Share</span><span class="fg-zoom">64%</span></div></header>
    <div class="fg-body">
      <aside class="fg-layers"><div class="fg-h">Layers</div>${["Desktop", "  Nav", "  Hero", "    Headline", "    Download button", "    Window", "  Footer", "Mobile", "Press kit"].map((l, i) => `<div class="${i === 2 ? "on" : ""}" style="padding-left:${12 + (l.length - l.trimStart().length) * 5}px">${l.trim().startsWith("Desktop") || l.trim().startsWith("Mobile") || l.trim().startsWith("Press") ? "#" : "▢"} ${l.trim()}</div>`).join("")}</aside>
      <div class="fg-canvas">
        <div class="fg-frame fg-desk"><span class="fg-fl">Desktop</span><div class="fg-hero"><div class="fg-ic"></div><div class="fg-h1">Nous Browser</div><div class="fg-btn"></div><div class="fg-win"></div></div><div class="fg-sel"><i></i><i></i><i></i><i></i><span>1440 × 900</span></div></div>
        <div class="fg-frame fg-mob"><span class="fg-fl">Mobile</span><div class="fg-hero"><div class="fg-ic"></div><div class="fg-h1">Nous</div><div class="fg-btn"></div></div></div>
        <div class="fg-cmt" style="left:54%;top:22%">${av("Sofia Rossi", "#c2255c")}</div>
        <div class="fg-cursor" style="left:38%;top:58%"><svg viewBox="0 0 16 16"><path d="M2 1.5v12l3.4-3.3 2.3 5 2-.9-2.3-4.9H12z"/></svg><span>Maya</span></div>
      </div>
      <aside class="fg-props"><div class="fg-h">Design <span>Prototype</span></div><div class="fg-p"><b>Frame</b><div class="fg-kv"><span>W</span>1440<span>H</span>900</div><div class="fg-kv"><span>X</span>0<span>Y</span>0</div></div>
        <div class="fg-p"><b>Fill</b><div class="fg-fill"><i></i>Linear · 100%</div></div><div class="fg-p"><b>Corner radius</b><div class="fg-kv"><span>◜</span>24</div></div><div class="fg-p"><b>Effects</b><div class="fg-fill"><i class="sh"></i>Drop shadow</div></div></aside>
    </div></div>`;

  P.docs = () => `<div class="s-gd">
    <header class="gd-top"><span class="gd-logo"></span><div><b>Launch announcement</b> <span class="gd-star">☆</span><nav>File Edit View Insert Format Tools Extensions Help</nav></div><span class="gd-sp"></span>${av("Ethan Brooks", "#5f3dc4")}<span class="gd-share">Share</span></header>
    <div class="gd-tool">↶ ↷ 🖨 &nbsp;100% ▾ &nbsp;|&nbsp; Normal text ▾ &nbsp;|&nbsp; Arial ▾ &nbsp;|&nbsp; − 11 + &nbsp;|&nbsp; <b>B</b> <i>I</i> <u>U</u> A</div>
    <div class="gd-canvas"><div class="gd-page">
      <h1>Acme launches 1.5 with Spaces sync</h1>
      <p class="gd-sub">For immediate release · San Francisco · November 13, 2026</p>
      <p>Today Acme is releasing version 1.5, the biggest update since launch. Spaces now sync across every Mac you own, and the Library gains a single search box for bookmarks, history and captures.</p>
      <p><mark>“We wanted the browser to feel like a quiet desk, not a crowded dashboard,”</mark> said Maya Patel, head of product. “Everything you need is one swipe away, and everything else gets out of the way.”</p>
      <h2>Availability</h2>
      <p>Version 1.5 is a free update for all users and is available today.</p>
    </div><div class="gd-comment">${av("Maya Patel", "#e8590c")}<div><b>Maya Patel</b><p>Can we shorten this quote a bit?</p></div></div></div></div>`;

  P.github = () => {
    const files = [["📁", "Docs", "Library: title on its own row", "3 days ago"], ["📁", "Engine", "NousCore engine, spaces, folders", "3 weeks ago"], ["📁", "Resources", "Window corner radius setting", "2 days ago"], ["📁", "Scripts", "Remove each build's staging bundle", "3 weeks ago"], ["📁", "Sources", "Window corner radius setting", "2 days ago"], ["📁", "Tests", "Group drag, page context menus", "last week"], ["📄", "Package.swift", "NousCore engine, spaces, folders", "3 weeks ago"], ["📄", "README.md", "Downloads, Inspect, crash fixes", "2 days ago"]];
    return `<div class="s-gh">
      <header class="gh-top"><span class="gh-logo"></span><b>UndefinedWork</b> / <b>Nous-Browser</b><em>Public</em><span class="gh-sp"></span><div class="gh-search">${ico.search} Type / to search</div></header>
      <nav class="gh-tabs"><span class="on">Code</span><span>Issues</span><span>Pull requests</span><span>Actions</span><span>Releases</span></nav>
      <div class="gh-body"><section>
        <div class="gh-bar"><span class="gh-br">⑂ codex/chromium-engine ▾</span><span class="gh-sp"></span><span class="gh-code">Code ▾</span></div>
        <div class="gh-files"><div class="gh-commit">${av("cellier", "#2f6feb")}<b>cellier</b> Nous Browser 1.4.5: window corner radius setting<span>b1e7021 · 2 days ago</span></div>
          ${files.map(([i, n, m, t]) => `<div class="gh-f"><span>${i}</span><b>${n}</b><em>${m}</em><time>${t}</time></div>`).join("")}</div>
        <div class="gh-readme"><div class="gh-rh">README</div><h1>Nous Browser</h1><p>Give the web a little more room.</p><p>Nous Browser is a lightweight, native macOS browser built with SwiftUI, Liquid Glass, SF Symbols and Chromium.</p>
          <h2>Features</h2><ul><li><b>Spaces</b> — every Space keeps its own pins, groups and tabs.</li><li><b>Pins</b> — pinned sites stay put across windows and restarts.</li><li><b>Library (⇧⌘L)</b> — bookmarks, screenshots, recordings, history and downloads.</li></ul></div>
      </section>
      <aside class="gh-about"><b>About</b><p>A lightweight, native Mac browser built on Chromium.</p><div class="gh-topics"><span>macos</span><span>swiftui</span><span>chromium</span><span>browser</span></div><b>Releases</b><p><span class="gh-tag">1.4.5</span> Latest · 2 days ago</p></aside></div></div>`;
  };

  P.hn = () => {
    const items = [
      ["Show HN: Nous – a calm, native Mac browser built on Chromium", "github.com/UndefinedWork", 412, 186, "github"],
      ["The tab is the wrong unit of work", "lindsey.dev", 318, 142, "wikipedia"],
      ["A visual history of the web browser (2024)", "en.wikipedia.org", 276, 61, "wikipedia"],
      ["Why I moved my team's planning back to plain documents", "notes.harperwells.com", 233, 118, ""],
      ["Designing calm software", "studio-orbit.design", 201, 74, ""],
      ["How Lisbon rebuilt itself after 1755", "historytoday.example", 188, 49, "maps"],
      ["Ask HN: What does your browser setup look like in 2026?", "", 164, 291, "reddit"],
      ["Typography for screens: a field guide", "typefield.io", 152, 37, "youtube"],
      ["We cut our CI time by 70% with one cache key", "eng.fernway.com", 140, 66, ""],
      ["Show HN: A tiny tool to turn screenshots into shareable cards", "framer.example", 98, 22, ""],
      ["The return of the personal homepage", "smallweb.club", 91, 40, ""],
    ];
    return `<div class="s-hn"><header class="hn-top"><span class="hn-y">Y</span><b>Hacker News</b><nav>new | past | comments | ask | show | jobs | submit</nav><span class="hn-sp"></span>login</header>
      <ol class="hn-list">${items.map(([t, d, p, c, nav], i) => `<li><span class="hn-n">${i + 1}.</span><span class="hn-up">▲</span><div><a ${nav ? `data-nav="${nav}"` : ""}>${esc(t)}</a>${d ? ` <span class="hn-d">(${d})</span>` : ""}<div class="hn-meta">${p} points by ${["pg_fan", "mtsmith", "sarah_k", "dlo", "rkn"][i % 5]} ${i + 1} hours ago | hide | ${c} comments</div></div></li>`).join("")}</ol></div>`;
  };

  P.youtube = () => {
    const recs = [["The grid, explained in 10 minutes", "Studio Type", "12:08", "#2b2d6e,#e85d4a"], ["Why serif fonts feel calm", "Margins", "8:41", "#f4e9d8,#c05621"], ["Designing a browser from scratch", "Interface Club", "24:15", "#0b1f9a,#7fb2f0"], ["Lisbon in 4K — walking Alfama at sunset", "Wander Slow", "41:02", "#f6a04d,#7a3f8f"], ["Lo-fi beats for deep work", "Quiet Hours", "LIVE", "#1d2b53,#7e2553"], ["Kerning is a feeling", "Studio Type", "6:30", "#111,#e3d5b8"]];
    return `<div class="s-yt"><header class="yt-top"><span class="yt-logo">${ico.play}</span><b>YouTube</b><div class="yt-search"><span>Search</span>${ico.search}</div>${av("Jordan Chen", "#7a5af8")}</header>
      <div class="yt-body"><section>
        <div class="yt-player" data-act="play"><div class="yt-art"><span>Aa</span><em>Type is a voice.</em></div><div class="yt-big">${ico.play}</div><div class="yt-bar"><i></i></div><div class="yt-ctl"><span>▶︎</span><span>3:12 / 14:27</span></div></div>
        <h1>How great typography works</h1>
        <div class="yt-ch">${av("Studio Type", "#e85d4a")}<div><b>Studio Type</b><small>412K subscribers</small></div><span class="yt-sub">Subscribe</span><span class="yt-sp"></span><span class="yt-pill">👍 18K | 👎</span><span class="yt-pill">Share</span></div>
        <div class="yt-desc"><b>284K views · 3 weeks ago</b><br>A look at rhythm, contrast and the small spacing decisions that make text feel effortless to read.</div>
      </section><aside>${recs.map(([t, c, d, g]) => `<div class="yt-rec"><div class="yt-th" style="background:linear-gradient(135deg,${g})"><span>${d}</span></div><div><b>${t}</b><small>${c}<br>${Math.floor(t.length * 7.3)}K views</small></div></div>`).join("")}</aside></div></div>`;
  };

  P.spotify = () => {
    const tr = [["Low Tide Radio", "Juniper Coast", "3:41"], ["Paper Lanterns", "Alma Reyes", "4:02"], ["Slow Orbit", "The Glass Hours", "3:18"], ["Saltwater Letters", "Maren & Cole", "3:55"], ["Northbound", "Kite Theory", "2:59"], ["Evening, Again", "Lune Park", "4:27"], ["Velvet Static", "Odessa Line", "3:33"], ["Copper Sky", "Harbor Lights", "3:12"]];
    return `<div class="s-sp"><aside class="sp-side"><div class="sp-nav"><b>⌂ Home</b><span>${ico.search} Search</span></div>
      <div class="sp-lib"><b>Your Library</b>${[["Discover Weekly", "#3b5bdb,#99e9f2"], ["Deep Focus", "#2b8a3e,#d8f5a2"], ["Lisbon Nights", "#e8590c,#ffd8a8"], ["Release Radar", "#c2255c,#fcc2d7"]].map(([n, g]) => `<div class="sp-pl"><i style="background:linear-gradient(135deg,${g})"></i><div>${n}<small>Playlist · Spotify</small></div></div>`).join("")}</div></aside>
      <section class="sp-main"><div class="sp-hero"><div class="sp-cover"><span>Discover<br>Weekly</span></div><div><small>Public Playlist</small><h1>Discover Weekly</h1><p>Your weekly mixtape of fresh music. Enjoy new discoveries and deep cuts chosen just for you.</p><small><b>Spotify</b> · 30 songs, about 1 hr 50 min</small></div></div>
        <div class="sp-ctl"><span class="sp-play" data-act="play">${ico.play}</span><span>♡</span><span>···</span></div>
        <div class="sp-tracks"><div class="sp-th"><span>#</span><span>Title</span><span>Album</span><span>⏱</span></div>
        ${tr.map(([t, a, d], i) => `<div class="sp-tr${i === 0 ? " on" : ""}"><span>${i === 0 ? "♫" : i + 1}</span><span><i style="background:linear-gradient(135deg,hsl(${i * 47} 60% 55%),hsl(${i * 47 + 60} 60% 35%))"></i><b>${t}</b><small>${a}</small></span><span>${t} — Single</span><span>${d}</span></div>`).join("")}</div></section></div>`;
  };

  P.reddit = () => {
    const posts = [["What's your favorite minimal browser in 2026?", "u/quietdesk", "1.2k", "318", "Looking for something lighter than Chrome but still compatible with everything at work. Spaces and vertical tabs are a must."], ["Nous Browser 1.4 adds Spaces, a Library and a built-in screen recorder", "u/macnerd_42", "864", "142", "", "github"], ["Finally organized 200 tabs into groups. AMA", "u/tabhoarder", "533", "97", ""], ["Best apps for window management on macOS 26?", "u/ellie_codes", "289", "76", ""]];
    return `<div class="s-rd"><header class="rd-top"><span class="rd-logo">r</span><b>reddit</b><div class="rd-search">${ico.search} Search in r/MacApps</div><span class="rd-btn">Log In</span></header>
      <div class="rd-banner"></div><div class="rd-head"><span class="rd-ic">r/</span><h1>r/MacApps</h1><span class="rd-join">Join</span></div>
      <div class="rd-body"><section>${posts.map(([t, u, v, c, b, nav]) => `<article class="rd-post" ${nav ? `data-nav="${nav}"` : ""}><small>r/MacApps · Posted by ${u} · 5h</small><h3>${esc(t)}</h3>${b ? `<p>${esc(b)}</p>` : ""}<div class="rd-meta"><span>⇧ ${v} ⇩</span><span>💬 ${c}</span><span>Share</span></div></article>`).join("")}</section>
      <aside><b>About Community</b><p>Discover and discuss apps for macOS. Be kind, share your setups, and no self-promo on weekends.</p><div class="rd-stats"><div><b>412k</b><small>Members</small></div><div><b>1.1k</b><small>Online</small></div></div></aside></div></div>`;
  };

  P.airbnb = () => {
    const L = [["Apartment in Alfama", "River views · 2 beds", "4.94", 168, "linear-gradient(160deg,#f2b880 0%,#d9774b 45%,#8a3b2b 100%)"], ["Loft in Príncipe Real", "Rooftop terrace · 1 bed", "4.88", 142, "radial-gradient(70% 50% at 30% 25%,#e8f1fb,transparent 60%),linear-gradient(170deg,#9cc3e6,#4a7fb5 55%,#1f3b5c)"], ["Casa do Fado", "Historic home · 3 beds", "4.97", 214, "linear-gradient(170deg,#ffe0a3,#f08a4b 55%,#6b2e1f)"], ["Studio in Bairro Alto", "Walk to everything · 1 bed", "4.81", 96, "linear-gradient(160deg,#b8d8e8,#5b8db8 60%,#2e4a66)"], ["Townhouse near Graça", "Garden · 2 beds", "4.90", 189, "linear-gradient(150deg,#c8e6c9,#6fa86f 55%,#2f5d3a)"], ["Riverside flat in Belém", "Near the tower · 2 beds", "4.86", 155, "linear-gradient(165deg,#fde2e4,#e5989b 50%,#6d597a)"]];
    return `<div class="s-ab"><header class="ab-top"><span class="ab-logo">airbnb</span><div class="ab-pill"><b>Lisbon</b><span>Nov 20 – 24</span><span>2 guests</span><i>${ico.search}</i></div><span class="ab-sp"></span>${av("Jordan Chen", "#7a5af8")}</header>
      <div class="ab-cats">${["🏛 Historical homes", "🌅 Amazing views", "🏙 Iconic cities", "🏖 Beachfront", "🍷 Vineyards", "🏡 Tiny homes"].map((c, i) => `<span class="${i === 0 ? "on" : ""}">${c}</span>`).join("")}</div>
      <p class="ab-count">Over 1,000 places in Lisbon</p>
      <div class="ab-grid">${L.map(([t, s, r, p, bg], i) => `<div class="ab-card"><div class="ab-ph" style="background:${bg}"><span class="ab-heart${i === 2 ? " on" : ""}" data-act="heart">${ico.heart}</span>${i === 2 ? '<span class="ab-badge">Guest favorite</span>' : ""}<div class="ab-dots"><i class="on"></i><i></i><i></i><i></i></div></div><div class="ab-t"><b>${t}</b><span>★ ${r}</span></div><small>${s}</small><small>Nov 20 – 24</small><p><b>$${p}</b> night</p></div>`).join("")}</div></div>`;
  };

  P.flights = () => {
    const F = [["TAP Air Portugal", "#0f9d58", "6:25 PM – 2:40 PM+1", "11 hr 15 min", "SFO–LIS", "Nonstop", "$742", "Best"], ["United", "#1a4fa3", "4:10 PM – 3:35 PM+1", "14 hr 25 min", "SFO–LIS", "1 stop · EWR", "$689", "Cheapest"], ["Lufthansa", "#0a1d3d", "1:20 PM – 1:05 PM+1", "14 hr 45 min", "SFO–LIS", "1 stop · FRA", "$811", ""], ["Air France", "#002157", "3:45 PM – 3:50 PM+1", "15 hr 5 min", "SFO–LIS", "1 stop · CDG", "$798", ""], ["KLM", "#00a1de", "1:55 PM – 2:20 PM+1", "15 hr 25 min", "SFO–LIS", "1 stop · AMS", "$776", ""]];
    return `<div class="s-fl"><header class="fl-top"><span class="fl-logo">${ico.plane}</span><b>Flights</b><nav><span>Travel</span><span>Explore</span><span class="on">Flights</span><span>Hotels</span></nav></header>
      <div class="fl-search"><div class="fl-opts"><span>⇄ Round trip ▾</span><span>👤 2 ▾</span><span>Economy ▾</span></div>
        <div class="fl-fields"><div><small>From</small>San Francisco</div><span class="fl-swap">⇄</span><div><small>To</small>Lisbon</div><div><small>Depart</small>Thu, Nov 19</div><div><small>Return</small>Wed, Nov 25</div></div></div>
      <div class="fl-list"><h3>Top departing flights</h3><p>Prices include required taxes and fees for 2 adults.</p>
        ${F.map(([a, c, t, d, r, s, p, tag]) => `<div class="fl-row"><span class="fl-air" style="--c:${c}">${a[0]}</span><div><b>${t}</b><small>${a}</small></div><div><b>${d}</b><small>${r}</small></div><div><b>${s}</b><small>${s === "Nonstop" ? "" : "2 hr 5 min"}</small></div><div class="fl-p"><b>${p}</b><small>round trip</small>${tag ? `<em>${tag}</em>` : ""}</div></div>`).join("")}</div></div>`;
  };

  P.maps = () => `<div class="s-mp">
    <svg class="mp-map" viewBox="0 0 900 700" preserveAspectRatio="xMidYMid slice">
      <rect width="900" height="700" fill="#f1efe8"/>
      <path d="M0 560 C 200 520, 380 600, 560 560 S 820 470, 900 480 L 900 700 L 0 700 Z" fill="#aad3f2"/>
      <path d="M90 120 h150 v110 h-150z M600 90 h170 v90 h-170z M420 330 h120 v80 h-120z" fill="#cfe8c4"/>
      <g stroke="#fff" stroke-width="10" fill="none" stroke-linecap="round"><path d="M0 300 C 200 280, 420 340, 900 260"/><path d="M300 0 C 320 200, 360 400, 380 560"/><path d="M640 0 C 620 160, 660 320, 720 500"/><path d="M0 440 C 260 420, 520 470, 900 400"/></g>
      <g stroke="#fde293" stroke-width="14" fill="none" stroke-linecap="round"><path d="M0 520 C 220 490, 420 540, 900 440"/></g>
      <g stroke="#fff" stroke-width="4" fill="none" opacity=".9"><path d="M120 360 l120 -40 l60 90"/><path d="M460 120 l80 60 l-30 90"/><path d="M520 380 l90 -20 l40 70"/><path d="M200 200 l40 80"/><path d="M760 300 l-60 60"/></g>
      <g font-family="-apple-system, Helvetica" font-size="15" fill="#5f6368"><text x="480" y="300">ALFAMA</text><text x="150" y="330">BAIXA</text><text x="620" y="220">GRAÇA</text><text x="600" y="610" fill="#5a8fc0" font-style="italic">Tagus River</text></g>
    </svg>
    <div class="mp-pin" style="left:57%;top:43%">${ico.pin}</div><div class="mp-dot" style="left:30%;top:52%"></div><div class="mp-dot" style="left:70%;top:35%"></div>
    <div class="mp-card"><div class="mp-search">${ico.search} Alfama, Lisbon</div><div class="mp-photo"></div><div class="mp-info"><h2>Alfama</h2><p>★★★★★ <b>4.7</b> (12,481) · Neighborhood</p><p class="mp-muted">Lisbon's oldest district, with steep lanes, tiled facades and fado houses.</p>
      <div class="mp-acts"><span><i>➚</i>Directions</span><span><i>☆</i>Save</span><span><i>◎</i>Nearby</span><span><i>⤴</i>Share</span></div>
      <div class="mp-row">🏠 Casa do Fado · 4 min walk</div><div class="mp-row">☕ Café da Garagem · 6 min walk</div><div class="mp-row">⛪ Lisbon Cathedral · 8 min walk</div></div></div>
    <div class="mp-zoom"><span>+</span><span>−</span></div></div>`;

  P.cooking = () => `<div class="s-ck"><header class="ck-top"><b>NYT Cooking</b><nav><span>Recipes</span><span>Guides</span><span>Collections</span></nav><span class="ck-sp"></span><span class="ck-btn">Subscribe</span></header>
    <div class="ck-body"><div class="ck-hero"><span>🍋</span></div>
      <div class="ck-text"><h1>Lemony Orzo With Peas and Feta</h1><p class="ck-by">By Clara Mendes</p>
        <div class="ck-meta"><div><small>Total Time</small>25 minutes</div><div><small>Rating</small>★★★★★ 4,213</div><div><small>Yield</small>4 servings</div></div>
        <p>A weeknight bowl that tastes like spring any time of year. The orzo cooks in broth until creamy, then gets a bright finish of lemon zest, sweet peas and salty feta.</p>
        <div class="ck-cols"><div><h3>Ingredients</h3><ul><li>2 tablespoons olive oil</li><li>1 shallot, finely chopped</li><li>1 ½ cups orzo</li><li>3 ½ cups chicken or vegetable broth</li><li>1 ½ cups frozen peas</li><li>1 lemon, zested and juiced</li><li>4 ounces feta, crumbled</li><li>Fresh mint, for serving</li></ul></div>
        <div><h3>Preparation</h3><ol><li>Warm the oil in a wide pot over medium heat. Add the shallot and cook until soft, about 3 minutes.</li><li>Stir in the orzo and toast for 2 minutes, then add the broth. Simmer, stirring often, until creamy, 10 to 12 minutes.</li><li>Add the peas, lemon zest and juice. Top with feta and mint.</li></ol></div></div></div></div></div>`;

  P.wikipedia = () => `<div class="s-wk"><header class="wk-top"><span class="wk-logo">W</span><div><b>WIKIPEDIA</b><small>The Free Encyclopedia</small></div><div class="wk-search">${ico.search} Search Wikipedia</div><span class="wk-sp"></span><span>Donate</span><span>Log in</span></header>
    <div class="wk-body"><aside class="wk-toc"><b>Contents</b><a>(Top)</a><a>History</a><a>Function</a><a>Features</a><a>Security</a><a>Market share</a><a>See also</a></aside>
      <article><h1>Web browser</h1><div class="wk-tabs"><span class="on">Article</span><span>Talk</span><span class="wk-sp"></span><span class="on">Read</span><span>Edit</span><span>View history</span></div>
        <p class="wk-from">From Wikipedia, the free encyclopedia</p>
        <div class="wk-box"><div class="wk-img"></div><small>A browser window showing a web page</small></div>
        <p>A <b>web browser</b> is an application used to access and display websites. When a user requests a page, the browser retrieves its files from a web server and renders the text, images and interactive elements on the user's device.</p>
        <p>Browsers handle far more than documents: they run web applications, play media, manage downloads and keep track of history and bookmarks. Most modern browsers share a small number of rendering engines, which helps websites behave consistently across them.</p>
        <h2>History</h2><p>The first web browser was written in 1990, and graphical browsers became widespread in the mid-1990s. Features such as tabs, private browsing and extensions arrived over the following decades, while recent designs focus on organizing many open pages, for example with vertical tabs and workspaces.</p>
        <h2>Function</h2><p>The core job of a browser is to fetch resources identified by a URL and present them to the user. Hyperlinks let users move from one resource to another, building the web of connected documents the system is named after.</p>
      </article></div></div>`;

  P.search = (q) => {
    const ql = q.toLowerCase();
    const hits = Object.entries(SITES).filter(([k, s]) => s.name && !k.includes("-") && (s.name.toLowerCase().includes(ql) || s.title.toLowerCase().includes(ql) || ql.includes(s.name.toLowerCase().split(" ")[0])));
    const base = hits.length ? hits : [["wikipedia", SITES.wikipedia], ["reddit", SITES.reddit], ["youtube", SITES.youtube], ["hn", SITES.hn]];
    return `<div class="s-gs"><header class="gs-top"><b class="gs-logo"><span style="color:#4285f4">G</span><span style="color:#ea4335">o</span><span style="color:#fbbc05">o</span><span style="color:#4285f4">g</span><span style="color:#34a853">l</span><span style="color:#ea4335">e</span></b><div class="gs-box" data-act="palette">${esc(q)}<span>${ico.search}</span></div></header>
      <nav class="gs-tabs"><span class="on">All</span><span>Images</span><span>News</span><span>Videos</span><span>Maps</span><span>Shopping</span></nav>
      <div class="gs-res"><p class="gs-count">About 1,240,000,000 results (0.31 seconds)</p>
      ${base.slice(0, 5).map(([k, s]) => `<div class="gs-r"><div class="gs-src">${NousSites.fav(k, 18)}<div><b>${esc(s.name)}</b><small>https://${esc(s.host.split("/")[0])}</small></div></div><a data-nav="${k}">${esc(s.title)}</a><p>${esc(snip(k, q))}</p></div>`).join("")}</div></div>`;
  };
  function snip(k, q) {
    const map = { wikipedia: "A web browser is an application used to access and display websites…", youtube: "Watch videos, listen to music and discover creators you'll love…", reddit: "Discussions, recommendations and setups from people who love Mac apps…", hn: "Hacker News is a social news website focusing on computer science and entrepreneurship.", airbnb: "Find vacation rentals, cabins, beach houses and more in Lisbon…", github: "A lightweight, native Mac browser built on Chromium." };
    return map[k] || `Results for “${q}” — ${SITES[k].name} on the web.`;
  }

  /* ---------------------------------------------------------------- */
  /* Favicons                                                          */
  /* ---------------------------------------------------------------- */

  const NOUS = '<svg viewBox="0 0 20 20"><defs><linearGradient id="nsg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2f8cff"/><stop offset="1" stop-color="#bfe0ff"/></linearGradient></defs><rect width="20" height="20" rx="5.5" fill="url(#nsg)"/><g fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" opacity=".95"><path d="M6 6.5a5 5 0 0 1 8.2 1.2"/><path d="M14 13.5a5 5 0 0 1-8.2-1.2"/><path d="M13.6 6.2a5 5 0 0 1 .4 6.4"/><path d="M6.4 13.8a5 5 0 0 1-.4-6.4"/></g></svg>';
  function fav(entry, size = 16) {
    const key = String(entry).split(":")[0];
    const s = SITES[key] || SITES.search;
    const st = `width:${size}px;height:${size}px`;
    if (s.fav === "nous") return `<span class="fav fav-img" style="${st}"><img src="assets/app-icon.png" alt=""></span>`;
    if (s.fav === "library") return `<span class="fav fav-sym" style="${st}"><svg viewBox="0 0 16 16"><rect x="2" y="3" width="12" height="3" rx="1"/><path d="M3 6v6.5a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V6M6.5 8.5h3"/></svg></span>`;
    if (s.fav === "shot") return `<span class="fav fav-sym" style="${st}"><svg viewBox="0 0 16 16"><path d="M2.5 5.5v-2a1 1 0 0 1 1-1h2M10.5 2.5h2a1 1 0 0 1 1 1v2M13.5 10.5v2a1 1 0 0 1-1 1h-2M5.5 13.5h-2a1 1 0 0 1-1-1v-2"/><circle cx="8" cy="8" r="2"/></svg></span>`;
    const g = s.glyph;
    const fs = Math.round(size * (g.length > 1 ? 0.5 : 0.62));
    return `<span class="fav fav-g${s.light ? " light" : ""}${s.serifGlyph ? " serif" : ""}" style="${st};--c:${s.color};font-size:${fs}px">${g}</span>`;
  }

  function info(entry, ctx) {
    const [key, arg] = String(entry).split(/:(.*)/);
    if (key === "search") return { title: `${arg} – Google Search`, host: `google.com/search?q=${encodeURIComponent(arg || "")}` };
    if (key === "shot") return { title: ctx && ctx.shotTitle ? ctx.shotTitle(arg) : "Screenshot", host: "nous://screenshot" };
    const s = SITES[key] || SITES.newtab;
    return { title: s.title, host: s.host, name: s.name };
  }

  window.NousSites = { SITES, pages: P, fav, info, esc, av };
})();
