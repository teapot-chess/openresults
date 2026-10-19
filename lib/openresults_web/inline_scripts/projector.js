(() => {
  const CYCLE_MS = 12000;
  // Independent of, and slower than, the site-wide 20-second refresher
  // in the root layout (which is switched off entirely on this page -
  // see the layout for why): that one replaces a whole region and would
  // wipe out which page is showing and the running timer along with it.
  // This swaps only the rows.
  const REFRESH_MS = 60000;

  const section = document.querySelector("[data-projector]");
  const wrap = document.getElementById("projector-boards");
  if (!section || !wrap) { return; }

  const table = wrap.querySelector("table");
  const tbody = table.querySelector("tbody");
  const thead = table.querySelector("thead");
  const foot = document.getElementById("projector-foot");
  const pageLabel = document.getElementById("projector-page");
  const pausedLabel = document.getElementById("projector-paused");
  const bar = document.getElementById("projector-bar");
  const barFill = document.getElementById("projector-bar-fill");

  // Before anything below touches the rows.
  let served = tbody.innerHTML;
  let rowsPerPage = 1;
  let page = 0;
  let paused = false;
  let cycleTimer = null;

  const rows = () => Array.from(tbody.querySelectorAll("tr"));

  // How many rows the glass actually holds, measured against an
  // already-rendered row rather than guessed - so nothing has to be
  // configured for a particular television.
  const measure = () => {
    const sample = rows()[0];
    if (!sample) { return 1; }

    const rowHeight = sample.getBoundingClientRect().height;
    if (rowHeight <= 0) { return rowsPerPage || 1; }

    const top = table.getBoundingClientRect().top;
    const headHeight = thead ? thead.getBoundingClientRect().height : 0;
    // Room for the page counter and bar below, so the last row is
    // never half-clipped at the bottom edge.
    const chrome = headHeight + 72;
    const usable = window.innerHeight - top - chrome;

    return Math.max(Math.floor(usable / rowHeight), 1);
  };

  const pageCount = () => Math.max(Math.ceil(rows().length / rowsPerPage), 1);

  // Shows the current page's rows and the counter beneath them.
  // Deliberately does not touch the progress bar's animation - a
  // resize or a data refresh must not restart a countdown somebody is
  // already watching.
  const applyPage = () => {
    const count = pageCount();
    page = Math.min(page, count - 1);

    rows().forEach((row, i) => {
      row.hidden = Math.floor(i / rowsPerPage) !== page;
    });

    if (count > 1) {
      foot.hidden = false;
      // The sentence comes from the server, already in the reader's
      // language, with the two numbers left as placeholders.
      pageLabel.textContent = (foot.dataset.pageLabel || "{page} / {count}")
        .replace("{page}", page + 1)
        .replace("{count}", count);
      pausedLabel.hidden = !paused;
      bar.hidden = paused;
    } else {
      // Every board fits on one screen: no counter, no bar, no timer.
      foot.hidden = true;
    }
  };

  // Restarts the sweep from empty. Called only where the countdown
  // itself actually restarts - a page turning over, or a resume - so
  // the bar and the timer that drives it can never drift apart.
  const restartBar = () => {
    if (paused) { return; }
    barFill.classList.remove("running");
    void barFill.offsetWidth;
    barFill.style.animationDuration = `${CYCLE_MS}ms`;
    barFill.classList.add("running");
  };

  const scheduleCycle = () => {
    if (cycleTimer) { clearInterval(cycleTimer); }
    cycleTimer = paused ? null : setInterval(advance, CYCLE_MS);
  };

  function advance() {
    const count = pageCount();
    if (paused || count <= 1) { return; }
    page = (page + 1) % count;
    applyPage();
    restartBar();
  }

  const refit = () => {
    rowsPerPage = measure();
    applyPage();
  };

  // A tap holds the page it is on rather than jumping back to the
  // start, so a player mid-read is not chased off their own board.
  const togglePause = () => {
    paused = !paused;
    applyPage();
    scheduleCycle();
    restartBar();
    // The paused line appears silently otherwise, and it is the one
    // place the page says how to start the screen moving again.
    if (paused && window.openResultsAnnounce) {
      window.openResultsAnnounce(pausedLabel.textContent.trim());
    }
  };

  section.addEventListener("click", (e) => {
    // Real links and buttons (the theme picker lives outside this
    // section, but stay defensive) keep their own behaviour.
    if (e.target.closest("a, button")) { return; }
    togglePause();
  });

  document.addEventListener("keydown", (e) => {
    if (e.key !== " " && e.code !== "Space") { return; }

    // Do not steal space from something else on the page that wants
    // it - the theme picker's own trigger, chiefly.
    const tag = document.activeElement && document.activeElement.tagName;
    if (["BUTTON", "SUMMARY", "A", "INPUT", "TEXTAREA", "SELECT"].includes(tag)) {
      return;
    }

    e.preventDefault();
    togglePause();
  });

  let resizeTimer = null;

  const onResize = () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(refit, 150);
  };

  window.addEventListener("resize", onResize);
  window.addEventListener("orientationchange", refit);

  // ---- keeping the boards current --------------------------------
  //
  // A re-fetch of this same URL and a swap of only the <tbody>, not a
  // reload - a reload would restart the cycle and blink the screen,
  // which is exactly what somebody watching this from across a hall
  // must never see.
  // A finished tournament's board does not change, so it is not polled
  // (`data-results-finished`, see `TournamentHTML.finished_marker/1`).
  // One that finishes while the screen is up stops with the first
  // poll that carries the mark.
  let refresher = null;
  let stopped = !!document.querySelector("[data-results-finished]");
  const stopRefreshing = () => {
    if (refresher !== null) { clearInterval(refresher); refresher = null; }
    stopped = true;
  };

  const refreshRows = () => {
    if (document.hidden) { return; }

    fetch(window.location.href, {
      headers: { accept: "text/html", "x-openresults-refresh": "1" }
    })
      .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
      .then((html) => {
        const doc = new DOMParser().parseFromString(html, "text/html");
        if (doc.querySelector("[data-results-finished]")) {
          stopRefreshing();
        } else if (stopped) {
          // Reopened by a correction: back to the usual pace.
          stopped = false;
          refresher = setInterval(refreshRows, REFRESH_MS);
        }
        const fresh = doc.querySelector("#projector-boards tbody");
        // Against the rows as the server last sent them, not as they
        // stand: paging sets `hidden` on them, so the live markup never
        // matched and every poll re-wrote the table.
        if (!fresh || fresh.innerHTML === served) { return; }

        served = fresh.innerHTML;
        tbody.innerHTML = served;
        refit();
      })
      .catch(() => {
        // The hall's wifi wobbles. The board stays as it was rather
        // than blank - stale is better than gone.
      });
  };

  refit();
  if (pageCount() > 1) { restartBar(); }
  scheduleCycle();
  if (!stopped) { refresher = setInterval(refreshRows, REFRESH_MS); }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && !stopped) { refreshRows(); }
  });
  // The arbiter just published: the root layout's event stream says
  // so, and the rows are fetched now rather than within the minute.
  document.addEventListener("openresults:changed", refreshRows);
})();
