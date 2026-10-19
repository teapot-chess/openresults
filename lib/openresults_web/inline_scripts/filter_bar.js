(() => {
  // Lower case, accents off, split into words - the same rule
  // `Tournament.Filter`'s name search applies on the server, so the
  // rows typing leaves are the rows Enter will load.
  const fold = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
  const words = (s) => fold(s).split(/[\s,]+/).filter(Boolean);
  const matches = (name, query) => {
    const haystack = fold(name);
    return query.every((word) => haystack.includes(word));
  };

  let announceTimer = null;

  // `firstRun` is the page load. On a refresher swap the reader's own
  // state - which disclosures they opened or closed, what they typed -
  // has already been put back by the refresher, and must not be undone
  // here.
  const init = (firstRun) => {
    const form = document.querySelector("[data-filter-form]");
    if (!form) { return; }

    // Marks the form as JS-driven, which is the only thing that hides
    // the Apply button (see `.filter-form.js-auto .filter-submit` in
    // app.css) - a reader with no script never gets this class, so the
    // button stays visible and the form stays usable exactly as it
    // was without this enhancement.
    form.classList.add("js-auto");

    // A control changing submits the form for real - a normal
    // navigation to the same GET the button already performs, never a
    // fetch. `requestSubmit` (not `.submit()`) so the button's own
    // `click`/`submit` events still fire, which is what a reader's
    // browser extensions or password manager would expect either way.
    // Once per element: `init` runs again after every refresher swap,
    // and a form the swap did not replace must not submit twice.
    form.querySelectorAll("select:not([data-auto-submit])").forEach((select) => {
      select.dataset.autoSubmit = "1";
      select.addEventListener("change", () => form.requestSubmit());
    });

    // A closed disclosure is only for narrow screens with nothing
    // active: the server always renders it open, so no-JS readers and
    // wide screens always see the controls.
    const details = form.querySelector(".filter-disclosure");
    if (firstRun && details && details.dataset.keepOpen !== "true" &&
        window.matchMedia("(max-width: 39.99rem)").matches) {
      details.open = false;
    }

    // Typing filters the rows already on the page, instantly and
    // without a reload (the old version reloaded the page half a
    // second after each pause, mid-name). Enter submits the real
    // filter, which is what makes a shareable link.
    const search = form.querySelector('input[name="q"]');
    if (!search) { return; }

    const bar = form.closest(".filter-bar");
    const count = bar && bar.querySelector(".filter-count");
    if (count && count.dataset.serverText === undefined) {
      count.dataset.serverText = count.textContent;
    }

    // Only the table this bar filters: the first wide table after it.
    // Not every table under the same parent - on a team round that
    // took in the matches table, whose team rows carry no player name
    // and whose boards sit in a nested table of their own.
    const rows = () => {
      let node = bar && bar.nextElementSibling;
      while (node && !node.matches(".scroller")) { node = node.nextElementSibling; }
      return node ? Array.from(node.querySelectorAll(":scope > table > tbody > tr")) : [];
    };

    const apply = (spoken) => {
      const query = words(search.value);
      // What the server already filtered by. Rows it sent all match it,
      // and its own count is the true sentence for them.
      const same = query.join(" ") === words(search.defaultValue).join(" ");
      let shown = 0;
      const all = rows();

      all.forEach((row) => {
        // A board shows when EITHER player matches, as on the server -
        // never on words split between White and Black.
        // The row's own names only: a standings row's tie-break
        // working, folded in a <details>, names every opponent too.
        const names = Array.from(row.querySelectorAll(".name"))
          .filter((n) => n.closest("tr") === row && !n.closest("details"))
          .map((n) => n.textContent);
        const hit = same || !query.length ||
          (names.length ? names.some((n) => matches(n, query)) : matches(row.textContent, query));
        row.hidden = !hit;
        if (hit) { shown += 1; }
      });

      // Hiding rows makes no sound. The count says it, and a screen
      // reader hears it once the reader pauses, not per letter.
      const sentence = same
        ? (count ? count.dataset.serverText : "")
        : (form.dataset.liveCount || "").replace("{shown}", shown).replace("{total}", all.length);
      if (count) { count.textContent = sentence; }

      if (spoken && window.openResultsAnnounce) {
        clearTimeout(announceTimer);
        announceTimer = setTimeout(() => window.openResultsAnnounce(sentence.trim()), 600);
      }
    };

    if (!search.dataset.liveFilter) {
      search.dataset.liveFilter = "1";
      search.addEventListener("input", () => apply(true));
    }

    // Text already in the box - put back by the refresher after a swap,
    // or by the browser on Back - filters the fresh rows too, instead
    // of a box saying "Peeters" over every row in the tournament.
    apply(false);
  };

  init(true);
  document.addEventListener("openresults:updated", () => init(false));
})();
