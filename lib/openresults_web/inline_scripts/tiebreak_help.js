(() => {
  const place = (button) => {
    const tip = button.nextElementSibling;
    if (!tip) { return; }
    const r = button.getBoundingClientRect();
    const w = tip.offsetWidth;
    const h = tip.offsetHeight;
    const left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8));
    const below = r.bottom + 6;
    const top = below + h > window.innerHeight - 8 ? Math.max(8, r.top - h - 6) : below;
    tip.style.left = left + "px";
    tip.style.top = top + "px";
  };

  const closeAll = (except) => {
    document.querySelectorAll('[data-tb-help][aria-expanded="true"]').forEach((b) => {
      if (b !== except) { b.setAttribute("aria-expanded", "false"); }
    });
  };

  document.addEventListener("click", (e) => {
    const button = e.target.closest("[data-tb-help]");
    closeAll(button);
    if (!button) { return; }
    const open = button.getAttribute("aria-expanded") !== "true";
    button.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) { place(button); }
  });

  document.addEventListener("mouseover", (e) => {
    const button = e.target.closest && e.target.closest(".tb-help-wrap");
    if (button) { place(button.querySelector("[data-tb-help]")); }
  });

  document.addEventListener("focusin", (e) => {
    if (e.target.matches && e.target.matches("[data-tb-help]")) { place(e.target); }
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { closeAll(null); }
  });

  window.addEventListener("scroll", () => closeAll(null), {passive: true});
})();
