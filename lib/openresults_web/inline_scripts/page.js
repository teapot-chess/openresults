(() => {
  const KEY = "openresults:theme";
  const root = document.documentElement;

  const write = (v) => { try { localStorage.setItem(KEY, v); } catch (_) {} };
  const read = () => { try { return localStorage.getItem(KEY); } catch (_) { return null; } };

  // ---- theme switch ----
  const picker = document.querySelector(".theme-picker");

  if (picker) {
    const trigger = picker.querySelector("summary");

    // The same answer the stylesheet highlights, said to a screen
    // reader as well: which option is the current one. Worked out from
    // the two attributes on <html> exactly as the CSS does it, so the
    // two cannot disagree.
    const markCurrent = () => {
      const source = root.getAttribute("data-theme-source");
      const current =
        source === "system" ? "system" : source === "default" ? "paper" : root.getAttribute("data-theme");

      picker.querySelectorAll("[data-theme-opt]").forEach((option) => {
        option.setAttribute("aria-pressed", String(option.dataset.themeOpt === current));
      });
    };

    markCurrent();

    picker.addEventListener("click", (e) => {
      const button = e.target.closest("[data-theme-opt]");
      if (!button) { return; }

      const value = button.dataset.themeOpt;
      write(value);

      if (value === "system") {
        root.removeAttribute("data-theme");
        root.setAttribute("data-theme-source", "system");
      } else {
        root.setAttribute("data-theme", value);
        root.setAttribute("data-theme-source", "user");
      }

      markCurrent();

      // A popover that stays open after you have chosen is a popover
      // you have to dismiss twice. Focus goes back to the trigger: the
      // option that had it has just been hidden, and a focused element
      // that disappears drops the keyboard at the top of the page.
      picker.removeAttribute("open");
      if (trigger) { trigger.focus(); }
    });

    // <details> does not close on Escape by itself.
    picker.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && picker.open) {
        picker.removeAttribute("open");
        if (trigger) { trigger.focus(); }
      }
    });
  }

  // ---- a form sent back refused ----
  //
  // The page reloads with the reason at the top, and a reader who
  // pressed "Send" from the bottom of the form would otherwise have to
  // find it. Focus goes to the sentence saying nothing was sent; the
  // next Tab is the first field.
  const refused = document.querySelector("#registration-form .alarm, #report-form .alarm");
  if (refused) { refused.focus(); }

  // A tie-break's working opens as a sheet on a phone: its Close button
  // shuts it, and opening one shuts the one before, so two sheets never
  // stack. Delegated, so it survives the refresher's swaps.
  document.addEventListener("click", (event) => {
    const close = event.target.closest("[data-close-detail]");
    if (close) { close.closest("details").open = false; }
  });
  document.addEventListener("toggle", (event) => {
    const opened = event.target;
    if (!(opened instanceof HTMLDetailsElement) || !opened.open || !opened.matches(".tb-detail")) { return; }
    document.querySelectorAll("details.tb-detail[open]").forEach((other) => {
      if (other !== opened) { other.open = false; }
    });
  }, true);

  // ---- finding an element again after the refresher replaced it ----
  //
  // The refresher swaps the region's HTML, which replaces every node in
  // it, so "the button that had focus" no longer exists afterwards - only
  // one just like it does. These two find it: `locate` records how to
  // recognise an element (its own identifying attributes, or those of the
  // nearest ancestor that has some, plus the path down from there) and
  // `relocate` looks for the same thing in the fresh DOM.
  const live = document.getElementById("live-region");
  const IDENTIFYING = [
    "id", "href", "name", "data-sort-key", "data-filter", "data-index-search",
    "data-standings-reset", "data-detail",
  ];

  const selectorFor = (el) => {
    const parts = IDENTIFYING.filter((name) => el.hasAttribute(name)).map(
      (name) => `[${name}="${CSS.escape(el.getAttribute(name))}"]`
    );
    return parts.length ? el.tagName.toLowerCase() + parts.join("") : null;
  };

  const locate = (el) => {
    const path = [];
    let node = el;

    while (live && node && node !== live && live.contains(node)) {
      const selector = selectorFor(node);
      if (selector) {
        const index = Array.from(live.querySelectorAll(selector)).indexOf(node);
        return {selector, index, path};
      }
      path.unshift(Array.prototype.indexOf.call(node.parentElement.children, node));
      node = node.parentElement;
    }

    // Nothing identifying on the way up: the path from the region
    // itself, rather than no answer - most <details> have no id.
    return live && node === live ? {selector: null, index: 0, path} : null;
  };

  const relocate = (spot) => {
    if (!live || !spot) { return null; }
    const matches = spot.selector ? live.querySelectorAll(spot.selector) : [live];
    let node = matches[spot.index] || matches[0] || null;
    for (const step of spot.path) { node = node ? node.children[step] : null; }
    return node;
  };

  // ---- the player card ----
  const overlay = document.getElementById("card-overlay");
  const body = document.getElementById("card-body");
  if (!overlay || !body) { return; }

  const dialog = overlay.querySelector(".card-dialog");

  // The name the card was opened from, and how to find it again if the
  // refresher replaced it while the card was open.
  let opener = null;

  const close = () => {
    if (overlay.hidden) { return; }
    overlay.hidden = true;
    const loading = document.createElement("p");
    loading.className = "card-loading";
    // From the server, in the reader's language, and set as TEXT - the
    // one place this script writes a whole element rather than moving
    // one the server already sent.
    loading.textContent = overlay.dataset.loading || "";
    body.replaceChildren(loading);
    body.removeAttribute("aria-busy");

    // Back to where the reader was. Without this, closing the card
    // left the keyboard at the top of the page, and a screen reader
    // user who had walked to row 140 had to walk there again.
    const back = opener && (opener.el.isConnected ? opener.el : relocate(opener.spot));
    opener = null;
    if (back) { back.focus(); }
  };

  // Everything in the dialog a Tab can land on, in order.
  const tabbable = () =>
    Array.from(
      dialog.querySelectorAll("a[href], button:not([disabled]), summary, input, select, textarea")
    ).filter((el) => !el.closest("[hidden]"));

  overlay.addEventListener("click", (e) => { if (e.target === overlay) { close(); } });
  overlay.querySelector(".card-close").addEventListener("click", close);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !overlay.hidden) {
      e.preventDefault();
      close();
    }
  });

  // A modal keeps Tab inside it: past the last link back to the close
  // button, and Shift+Tab the other way round. Otherwise the keyboard
  // walks out into a page `aria-modal` has just told a screen reader
  // is not there.
  overlay.addEventListener("keydown", (e) => {
    if (e.key !== "Tab") { return; }
    const items = tabbable();
    if (!items.length) { e.preventDefault(); return; }

    const first = items[0];
    const last = items[items.length - 1];
    const at = document.activeElement;

    if (e.shiftKey && (at === first || !dialog.contains(at) || at === dialog)) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && (at === last || !dialog.contains(at))) {
      e.preventDefault();
      first.focus();
    }
  });

  // ---- keeping the page current ----
  //
  // The pages this replaced were LiveViews on a PubSub topic: standings
  // moved as results were entered. This site is static by design, and a
  // spectator refreshing their phone every two minutes was the most
  // visible thing lost in the move.
  //
  // A re-fetch and a swap, not a reload. `location.reload()` would be
  // four lines and would throw away scroll position every 20 seconds,
  // which on a 200-player standings table means losing your place while
  // reading it - worse than the problem.
  //
  // Deliberately does nothing at all on the entry form or the report
  // form: replacing the DOM under somebody who is typing would clear
  // what they had written.
  const status = document.getElementById("live-status");
  const announce = window.openResultsAnnounce || (() => {});
  const isForm = !!document.querySelector("#registration-form, #report-form");
  // The projector view runs its own refresh, on its own slower clock,
  // that swaps only its board rows - see the round template. This one
  // replaces the whole region, which would wipe out which page is
  // showing and the running cycle timer along with it.
  const isProjector = !!document.querySelector("[data-projector]");

  if (live && !isForm && !isProjector) {
    let failures = 0;
    let busy = false;
    // A publish heard on the event stream while a poll was already out:
    // that poll may have left before the publish landed, so one more
    // goes the moment it is back.
    let again = false;

    // Somebody in the middle of using a control - a filter dropdown
    // open, a search half typed. Swapping now would close the dropdown
    // under their finger, so this poll is skipped and the next one
    // tries again.
    const inUse = () => {
      const at = document.activeElement;
      return !!at && live.contains(at) && at.matches("input, select, textarea");
    };

    // The page's own wide tables, in order - not the small ones inside a
    // tie-break's <details>, which move with their row when it is sorted.
    const scrollers = () =>
      Array.from(live.querySelectorAll(".scroller")).filter((el) => !el.closest("details"));

    // What a reader has done to the region that its fresh HTML knows
    // nothing about: where focus is, which <details> they opened, how
    // far a wide table is scrolled sideways, what is typed in a box.
    const capture = () => {
      const at = document.activeElement;

      return {
        focus: at && at !== live && live.contains(at) ? locate(at) : null,
        // Open AND closed: the phone filter disclosure arrives open
        // from the server, so a reader who closed it must get it back
        // closed, not just the opened ones back open.
        details: Array.from(live.querySelectorAll("details"))
          .map((el) => [locate(el), el.open])
          .filter(([spot]) => spot),
        scroll: scrollers().map((el) => el.scrollLeft),
        typed: Array.from(live.querySelectorAll("input[type=search], input[type=text]"))
          .map((el) => [locate(el), el.value])
          .filter(([spot, value]) => spot && value),
      };
    };

    const swap = (html) => {
      const doc = new DOMParser().parseFromString(html, "text/html");
      const fresh = doc.getElementById("live-region");
      if (!fresh) { throw new Error("no live region"); }

      // Compare before touching the DOM. Most polls find nothing new,
      // and replacing identical markup would collapse an open <details>
      // and drop focus for no reason.
      //
      // By the server's fingerprint of what it sent, not by markup: the
      // region in the browser has been changed by its own scripts (a
      // class on the filter form, a closed disclosure, hidden rows), so
      // it never equals fresh server HTML and every poll looked like an
      // update. The markup is only the fallback for a response from a
      // server that sends no fingerprint.
      const version = fresh.getAttribute("data-version");
      const unchanged = version
        ? version === live.getAttribute("data-version")
        : fresh.innerHTML === live.innerHTML;
      if (unchanged) { return false; }

      const kept = capture();

      live.innerHTML = fresh.innerHTML;
      if (version) { live.setAttribute("data-version", version); }

      // Before the scripts below re-run, so they read what the reader
      // had typed rather than an empty box.
      kept.details.forEach(([spot, open]) => {
        const details = relocate(spot);
        if (details && details.tagName === "DETAILS") { details.open = open; }
      });
      kept.typed.forEach(([spot, value]) => {
        const box = relocate(spot);
        if (box) { box.value = value; }
      });

      // A script embedded in that HTML does NOT run - innerHTML never
      // executes a <script> it inserts - so anything inside
      // #live-region that wires itself up on load (the standings
      // table's sort and filter, currently) would otherwise work once
      // and then go quiet after the first real update. This is the
      // hook: it fires on the region that is always still `live`
      // itself, so code registered against `document` from the page's
      // FIRST render - which does run - can re-query the fresh DOM and
      // wire it up again.
      document.dispatchEvent(new CustomEvent("openresults:updated"));

      // After the scripts, which may have re-sorted the rows the
      // scroll position and the focused element are measured against.
      scrollers().forEach((el, i) => {
        if (kept.scroll[i]) { el.scrollLeft = kept.scroll[i]; }
      });

      // Focus back on the same control, without scrolling to it: the
      // page has not moved, so neither should the reader. Without this
      // every real update dropped a keyboard user's focus to the top
      // of the document - on a sort button, a player's name, anything.
      const refocus = relocate(kept.focus);
      if (refocus) { refocus.focus({preventScroll: true}); }

      return true;
    };

    const tick = () => {
      // Nothing to update while the tab is in the background, and a
      // phone in a pocket should not be polling a server all round.
      // One poll at a time: a tab brought to the front can ask while
      // the timer's own request is still out, and two swaps racing
      // each other can land in either order.
      if (document.hidden || (inUse() && !paused) || busy) { return; }
      busy = true;

      fetch(window.location.href, {
        headers: {"accept": "text/html", "x-openresults-refresh": "1"}
      })
        .then((r) => r.ok ? r.text().then((html) => [r, html]) : Promise.reject(r.status))
        .then(([r, html]) => {
          busy = false;
          failures = 0;
          if (again) { again = false; setTimeout(tick, 0); }
          if (status) { status.hidden = true; }
          // Redirected somewhere else - a renamed or withdrawn page. That
          // page's region does not belong under this address.
          if (r.redirected) { return; }
          if (paused) { holdBack(html); arm(); return; }
          if (inUse()) { return; }
          const changed = swap(html);
          // A tournament that went live again after being finished
          // (a correction, a reopened round) takes the polling back up.
          arm();
          showPause();
          if (changed) {
            // Said quietly and only when something actually changed, so
            // a spectator knows the page is live rather than stuck.
            if (status) {
              status.textContent = status.dataset.updated || "";
              status.hidden = false;
              announce(status.dataset.updated);
            }
          }
        })
        .catch(() => {
          busy = false;
          again = false;
          // A hall's wifi drops. Say so rather than showing a page that
          // has silently stopped being current, and keep trying - this
          // is not an error worth ending the session over.
          failures += 1;
          if (failures >= 2 && status) {
            status.textContent = status.dataset.offline || "";
            status.hidden = false;
            // Announced once, when it starts, not on every failed poll
            // after that.
            if (failures === 2) { announce(status.dataset.offline); }
          }
        });
    };

    // Every 20 seconds, and every 10 on a tournament page while a
    // round's results are coming in - the masthead carries
    // `data-results-live` exactly then (see `TournamentHTML.masthead/1`).
    // Asked again before every wait, of the region as it stands after
    // the last swap, so the pace follows the round: faster the moment
    // one goes live, back to 20 once its last result is in. Each poll
    // still sends `x-openresults-refresh`, so none of them counts as a
    // view whatever the pace.
    const delay = () => (live.querySelector("[data-results-live]") ? 10000 : 20000);
    // A finished tournament does not change under its readers, so its
    // pages do not poll at all: the server marks them
    // `data-results-finished` (see `TournamentHTML.finished_marker/1`).
    // Checked before every wait and again when it ends, so a page open
    // while its tournament finished stops with the first poll that
    // carries the mark. No back-off for anything else: live
    // tournaments and every other page keep the pace above.
    const finished = () => !!live.querySelector("[data-results-finished]");
    let timer = null;

    // ---- pausing (WCAG 2.2.2) ----
    //
    // Polling goes on while paused, so "N updates waiting" is true, but
    // nothing is applied: the page under the reader's finger stays put.
    // Resuming applies the latest state in one swap, not N of them. The
    // choice is remembered per visitor; a browser that will not store it
    // simply starts unpaused each visit.
    const PAUSE_KEY = "openresults:paused";
    const pauseButton = document.getElementById("live-pause");
    const pauseStatus = document.getElementById("live-pause-status");
    let paused = false;
    let waiting = 0;
    let waitingVersion = null;
    let waitingHtml = null;

    try { paused = localStorage.getItem(PAUSE_KEY) === "1"; } catch (_) {}

    const showPause = () => {
      if (!pauseButton) { return; }
      // Nothing to pause on a finished tournament: its pages do not poll.
      pauseButton.hidden = finished();
      pauseButton.textContent = (paused ? pauseButton.dataset.resume : pauseButton.dataset.pause) || "";
      pauseButton.setAttribute("aria-pressed", String(paused));
      if (!pauseStatus) { return; }
      pauseStatus.hidden = !paused || pauseButton.hidden;
      if (paused) {
        const say = waiting === 0 ? pauseStatus.dataset.none
          : waiting === 1 ? pauseStatus.dataset.one
          : (pauseStatus.dataset.many || "").replace("{n}", String(waiting));
        pauseStatus.textContent = say || "";
      }
    };

    // Count a fetched page the reader is not being shown: one more waiting
    // update per distinct version the server sends, none if it is back to
    // what is on screen.
    const holdBack = (html) => {
      const doc = new DOMParser().parseFromString(html, "text/html");
      const fresh = doc.getElementById("live-region");
      if (!fresh) { return; }
      const version = fresh.getAttribute("data-version") || fresh.innerHTML;
      const shown = live.getAttribute("data-version") || live.innerHTML;
      if (version === shown) {
        waiting = 0; waitingVersion = null; waitingHtml = null;
      } else if (version !== waitingVersion) {
        waiting += 1; waitingVersion = version; waitingHtml = html;
      }
      showPause();
    };

    const setPaused = (value) => {
      paused = value;
      try { localStorage.setItem(PAUSE_KEY, value ? "1" : "0"); } catch (_) {}
      if (!paused && waitingHtml) {
        const html = waitingHtml;
        waiting = 0; waitingVersion = null; waitingHtml = null;
        try { swap(html); } catch (_) {}
      }
      showPause();
      // Said, because the button's own text changing is not announced.
      announce(paused ? (pauseStatus && pauseStatus.dataset.none) : (status && status.dataset.updated));
      if (!paused) { tick(); }
    };

    if (pauseButton) {
      pauseButton.addEventListener("click", () => setPaused(!paused));
      showPause();
    }

    const arm = () => {
      if (timer !== null || finished()) { return; }
      timer = setTimeout(() => {
        timer = null;
        if (finished()) { return; }
        tick();
        arm();
      }, delay());
    };
    arm();
    // A tab brought back to the front is stale by however long it was
    // hidden, and its reader is looking at it right now - unless the
    // tournament is over and there is nothing new to see.
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden && !finished()) { tick(); }
    });
    // The arbiter just published - see "hearing about a publish" below.
    document.addEventListener("openresults:changed", () => {
      if (busy) { again = true; } else { tick(); }
    });
  }

  // ---- hearing about a publish ----
  //
  // The polls above are the floor, not the speed: a page that waited
  // for its next turn showed an arbiter's change up to twenty seconds
  // after it was on this server. So the page also holds the
  // tournament's event stream (`data-events`, see
  // `OpenResultsWeb.EventsController`), which says one word when a
  // publish lands, and the page polls at once.
  //
  // It carries no data: the poll is the same request as always, through
  // the same revalidation and the same page cache. A browser without
  // `EventSource`, a stream that drops, or a server that is full only
  // means the page is back to its polls. The random spread, under a
  // second, is so a hall full of phones does not ask in the same
  // millisecond. Closed while the tab is in the background, like the
  // polls: a phone in a pocket holds no connection open.
  const events = live && live.getAttribute("data-events");

  if (events && !isForm && window.EventSource) {
    let source = null;

    const open = () => {
      if (source || document.hidden) { return; }
      source = new EventSource(events);
      source.onmessage = () => {
        setTimeout(() => {
          document.dispatchEvent(new CustomEvent("openresults:changed"));
        }, Math.random() * 800);
      };
      // Closed for good means the server said no (full, or the
      // tournament is gone) - not a dropped connection, which the
      // browser retries on its own. Forgotten, so a tab brought back
      // to the front may try once more.
      source.onerror = () => {
        if (source && source.readyState === EventSource.CLOSED) { source = null; }
      };
    };

    const close = () => {
      if (source) { source.close(); source = null; }
    };

    document.addEventListener("visibilitychange", () => {
      if (document.hidden) { close(); } else { open(); }
    });
    window.addEventListener("pagehide", close);
    open();
  }

  // ---- finding yourself on the FIDE list ----
  //
  // Fills the form's fields; never required, never blocking. Everything
  // it would fill can be typed, and a player who is not on the FIDE list
  // ignores it entirely. The panel is only rendered where this server
  // has a list, so "unavailable" is only ever the list vanishing
  // between drawing the page and the search - said as such, because
  // "no match" would tell somebody on the list that they are not.
  const fide = document.getElementById("fide-search");

  if (fide) {
    const box = document.getElementById("fide-query");
    const list = document.getElementById("fide-results");
    const none = document.getElementById("fide-none");
    const unavailable = document.getElementById("fide-unavailable");
    const endpoint = fide.dataset.endpoint;
    let timer = null;
    let latest = 0;

    const field = (name) => document.getElementById("registration_" + name);

    const fill = (player) => {
      // Only what came back. A blank from the FIDE list means "not
      // recorded", and writing it over something the person already
      // typed would be this page deciding it knows better.
      const set = (name, value) => {
        const el = field(name);
        if (el && value !== null && value !== undefined && value !== "") {
          el.value = value;
        }
      };

      set("name", player.name);
      set("rating", player.rating);
      set("federation", player.federation);
      set("fide_id", player.fide_id);
      set("title", player.title);
      set("birth_year", player.birth_year);
      // The FIDE list has neither of these. Kept for an answer that
      // does carry them (the arbiter's own machine used to add its
      // national list's), and left alone like every other blank above.
      set("national_id", player.national_id);
      set("club", player.club);

      list.hidden = true;
      none.hidden = true;
      box.value = "";
      // Straight to the one field the list cannot supply, which is the
      // one the arbiter actually needs - and said, because a screen
      // reader otherwise hears "Email, required" with no idea that four
      // fields around it have just changed.
      announce(fide.dataset.filled);
      field("email")?.focus();
    };

    const render = (players, available) => {
      list.replaceChildren();
      unavailable.hidden = true;

      if (available === false) {
        list.hidden = true;
        none.hidden = true;
        unavailable.hidden = false;
        announce(unavailable.textContent.trim());
        return;
      }

      if (!players.length) {
        list.hidden = true;
        none.hidden = false;
        announce(none.textContent.trim());
        return;
      }

      none.hidden = true;
      announce(fide.dataset.found);

      for (const player of players) {
        const li = document.createElement("li");
        const button = document.createElement("button");
        button.type = "button";

        const who = document.createElement("span");
        who.className = "who";
        who.textContent = [player.title, player.name].filter(Boolean).join(" ");

        const about = document.createElement("span");
        about.className = "about";
        about.textContent = [player.federation, player.rating, player.birth_year, player.club]
          .filter(Boolean)
          .join(" \u00b7 ");

        button.append(who, about);
        button.addEventListener("click", () => fill(player));
        li.append(button);
        list.append(li);
      }

      list.hidden = false;
    };

    const run = (query) => {
      // Every response carries the number of the request that asked for
      // it. Without that, a slow search for "van" can land after a fast
      // one for "van der berg" and replace the right answers with
      // stale ones.
      const mine = ++latest;

      fetch(endpoint + "?q=" + encodeURIComponent(query), {
        headers: {"accept": "application/json"},
      })
        .then((r) => r.ok ? r.json() : Promise.reject(r.status))
        .then((data) => {
          if (mine !== latest) { return; }
          render(data.players || [], data.available);
        })
        .catch(() => {
          // The form works without this. An error about somebody else's
          // server is not something the person typing their name can do
          // anything with.
          if (mine !== latest) { return; }
          list.hidden = true;
          none.hidden = false;
          announce(none.textContent.trim());
        });
    };

    box.addEventListener("input", () => {
      clearTimeout(timer);
      const query = box.value.trim();

      if (query.length < 2) {
        list.hidden = true;
        none.hidden = true;
        unavailable.hidden = true;
        return;
      }

      // A request per keystroke would be a search per letter of a
      // surname, against a machine that is also running a tournament.
      timer = setTimeout(() => run(query), 250);
    });

    // The panel is inside the form, so Enter in it would submit a
    // half-filled entry.
    box.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); }
    });

    document.addEventListener("click", (e) => {
      if (!fide.contains(e.target)) { list.hidden = true; }
    });
  }

  // A right-click on a name - or, from the keyboard, the context-menu key
  // or Shift+F10 on a focused one, which send this same event with the
  // focused link as its target.
  document.addEventListener("contextmenu", (e) => {
    const link = e.target.closest("a.player[data-player]");
    if (!link) { return; }
    e.preventDefault();

    opener = {el: link, spot: locate(link)};
    overlay.hidden = false;
    body.setAttribute("aria-busy", "true");
    // Into the dialog straight away, so a screen reader says "Player
    // card, dialog" while it loads rather than nothing at all.
    dialog.focus();

    fetch(link.href, {headers: {"accept": "text/html"}})
      .then((r) => r.ok ? r.text() : Promise.reject(r.status))
      .then((html) => {
        const doc = new DOMParser().parseFromString(html, "text/html");
        // The SUMMARY section, not the page's first one. The page
        // carries a second, much longer section - the chart, the
        // round-by-round table, every tie-break contribution - and
        // lifting that into a dialog would make the peek and the page
        // the same thing again, which is what this stopped being.
        const section = doc.querySelector("#player-summary");
        if (!section) { throw new Error("no card"); }
        // The page's own links off the player (their whole record, the
        // follow switch) are not part of a peek.
        section.querySelectorAll("[data-peek-hide]").forEach((el) => el.remove());
        body.replaceChildren(section);
        body.removeAttribute("aria-busy");

        // Then onto whose card it is, if the reader has not already
        // moved on inside the dialog.
        const heading = section.querySelector("h2");
        if (heading && document.activeElement === dialog) {
          heading.tabIndex = -1;
          heading.focus();
        }
      })
      .catch(() => {
        // The card is a convenience; the page behind it is the real
        // thing. Falling through to it beats an error message about a
        // feature the visitor did not know existed.
        close();
        window.location.href = link.href;
      });
  });
})();
