(() => {
  // Re-run from the very first render - see the root layout's comment on
  // "openresults:updated" for why this survives the 20-second refresher's
  // innerHTML swap even though this very <script> tag does not run again.
  const init = () => {
    const box = document.querySelector("[data-index-search]");
    const panel = document.querySelector("[data-index-panel]");
    if (!box || !panel) { return; }

    const empty = document.querySelector("[data-index-empty]");
    const groups = Array.from(panel.querySelectorAll("[data-group]"));

    // `said` is true for a reader's own typing. The "nothing matches"
    // sentence is announced when it appears - once, not per keystroke -
    // because a list emptying itself makes no sound.
    // Accents off both sides, so "liege" finds "Liège" - the rule the
    // filter bar's name search follows.
    const fold = (s) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

    const apply = (said) => {
      const query = fold(box.value.trim());
      let anyVisible = false;

      groups.forEach((group) => {
        let groupHasMatch = false;

        group.querySelectorAll(".tournaments > li").forEach((row) => {
          const haystack = [row.dataset.name, row.dataset.city, row.dataset.federation]
            .filter(Boolean)
            .join(" ");

          const match = !query || fold(haystack).includes(query);
          row.hidden = !match;
          if (match) { groupHasMatch = true; }
        });

        group.hidden = !groupHasMatch;
        if (groupHasMatch) { anyVisible = true; }
      });

      if (empty) {
        const wasHidden = empty.hidden;
        empty.hidden = anyVisible || !query;
        if (said && wasHidden && !empty.hidden && window.openResultsAnnounce) {
          window.openResultsAnnounce(empty.textContent.trim());
        }
      }
    };

    box.addEventListener("input", () => apply(true));
    apply(false);
  };

  init();
  document.addEventListener("openresults:updated", init);
})();
