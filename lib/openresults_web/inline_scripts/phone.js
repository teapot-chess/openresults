(() => {
  const key = (slug) => "openresults:follow:" + slug;
  const read = (slug) => { try { return localStorage.getItem(key(slug)); } catch (_) { return null; } };
  const write = (slug, no) => {
    try {
      if (no) { localStorage.setItem(key(slug), no); } else { localStorage.removeItem(key(slug)); }
    } catch (_) {}
  };

  // Centred by measurement rather than scrollIntoView, which would
  // also scroll the page itself to wherever the strip is.
  const centreRounds = () => {
    const strip = document.getElementById("round-strip");
    if (!strip || strip.scrollWidth <= strip.clientWidth + 1) { return; }
    const chips = strip.querySelectorAll("a.chip");
    const target = strip.querySelector("[aria-current=page]") || chips[chips.length - 1];
    if (!target) { return; }
    const s = strip.getBoundingClientRect();
    const t = target.getBoundingClientRect();
    strip.scrollLeft += (t.left + t.width / 2) - (s.left + s.width / 2);
  };

  // The row a pairing number sits in: a board, a standings row or a
  // bye - never a name inside a tie-break's working, which names
  // every opponent too.
  const findRow = (pin, no) => {
    const link = 'a.player[data-player="' + no + '"]';
    const places = [
      "table.pairings:not(.projector-pairings) > tbody > tr > td.seat " + link,
      "table.standings > tbody > tr > th.row-head " + link,
      "table.byes > tbody > tr > th.row-head " + link,
    ];
    for (const selector of places) {
      const hit = Array.from(document.querySelectorAll(selector)).find((a) => !pin.contains(a));
      if (hit) { return hit.closest("tr"); }
    }
    return null;
  };

  // A copy that is a copy: no ids (two #board-12s, and the refresher
  // finds things by id), nothing marked current, and a tie-break's
  // working folded down to its number so the refresher's record of
  // which ones were open is not thrown off by a second set.
  const copyOf = (row) => {
    const table = row.closest("table");
    const copy = document.createElement("table");
    copy.className = table.className;
    if (table.tHead) { copy.append(table.tHead.cloneNode(true)); }
    const body = document.createElement("tbody");
    body.append(row.cloneNode(true));
    copy.append(body);

    copy.querySelectorAll("[id]").forEach((el) => el.removeAttribute("id"));
    copy.querySelectorAll("[aria-current]").forEach((el) => el.removeAttribute("aria-current"));
    copy.querySelectorAll(".is-followed").forEach((el) => el.classList.remove("is-followed"));
    copy.querySelectorAll("details").forEach((details) => {
      const summary = details.querySelector("summary");
      const span = document.createElement("span");
      span.textContent = summary && summary.firstChild ? summary.firstChild.textContent.trim() : "";
      details.replaceWith(span);
    });
    return copy;
  };

  const pinRow = () => {
    document.querySelectorAll("tr.is-followed").forEach((row) => row.classList.remove("is-followed"));

    // The cross-table has no pin above it, only the row marked where
    // it sits: the same class, so the same tint and edge as standings.
    const grid = document.querySelector("table.crosstable[data-follow-table]");
    if (grid) {
      const mine = read(grid.dataset.followTable);
      if (mine && /^[0-9]+$/.test(mine)) {
        const link = grid.querySelector('tbody > tr > th.row-head a.player[data-player="' + mine + '"]');
        if (link) { link.closest("tr").classList.add("is-followed"); }
      }
    }

    const pin = document.querySelector("[data-follow-pin]");
    if (!pin) { return; }
    const holder = pin.querySelector("[data-follow-rows]");
    if (holder) { holder.replaceChildren(); }
    pin.hidden = true;

    const no = read(pin.dataset.followPin);
    if (!holder || !no || !/^[0-9]+$/.test(no)) { return; }

    const row = findRow(pin, no);
    if (!row) { return; }

    row.classList.add("is-followed");
    holder.append(copyOf(row));
    pin.hidden = false;
  };

  const syncButton = () => {
    const button = document.getElementById("follow-player");
    if (!button) { return; }
    const on = read(button.dataset.followSlug) === button.dataset.followNo;
    button.textContent = on ? button.dataset.labelFollowing : button.dataset.labelFollow;
    button.classList.toggle("is-on", on);
    button.hidden = false;
    const hint = button.parentElement && button.parentElement.querySelector(".follow-hint");
    if (hint) { hint.hidden = false; }
  };

  // Delegated, so a button the refresher swapped in works without
  // anything being bound to it again.
  document.addEventListener("click", (e) => {
    const follow = e.target.closest("#follow-player");
    if (follow) {
      const slug = follow.dataset.followSlug;
      const on = read(slug) === follow.dataset.followNo;
      write(slug, on ? null : follow.dataset.followNo);
      syncButton();
      return;
    }

    const stop = e.target.closest("[data-follow-stop]");
    if (stop) {
      const pin = stop.closest("[data-follow-pin]");
      if (pin) { write(pin.dataset.followPin, null); }
      pinRow();
    }
  });

  const run = () => {
    centreRounds();
    pinRow();
    syncButton();
  };

  run();
  document.addEventListener("openresults:updated", run);
})();
