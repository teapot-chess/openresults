(() => {
  const KEY = "openresults:theme";
  const root = document.documentElement;

  // localStorage THROWS rather than returning null where a browser
  // blocks site data - a private window, or a partitioned third-party
  // frame, which is exactly the club-embed case this site supports.
  // Unguarded, that would take the whole bootstrap down.
  const read = () => { try { return localStorage.getItem(KEY); } catch (_) { return null; } };

  const saved = read();

  // A round reached with `?display=1` is the projector view - see the
  // round template - and needs the high-contrast theme regardless of
  // what this visitor (or this browser) has otherwise chosen: the room
  // decides this, not a preference set at a desk somewhere else. Checked
  // first so it outranks both a saved choice and the device's own
  // scheme; the picker below is still there, one tap away, to switch it
  // back for this viewing.
  const params = new URLSearchParams(location.search);
  const projector = params.get("display") === "1" || params.get("display") === "true";

  // No choice made yet means LIGHT, not "follow the device".
  //
  // Following the device is the better default for an application
  // somebody lives in. This is a page a spectator opens once, often
  // embedded in a club's own site - and a club site is overwhelmingly
  // light, so a dark slab dropped into the middle of one reads as
  // broken rather than as a theme. The same argument applies to a
  // projector in a hall, which is the other place these pages end up.
  //
  // "Match device" is still there, one click away, and once chosen it
  // wins and persists. Only the default changed.
  if (projector) {
    root.setAttribute("data-theme", "contrast");
    // "user" rather than "default": the picker highlights whichever
    // dot matches these two attributes, and "High contrast" is the
    // true answer to "what theme is this" here, chosen or not.
    root.setAttribute("data-theme-source", "user");
  } else if (saved) {
    if (saved === "system") {
      // Deliberately no attribute: the stylesheet's
      // prefers-color-scheme query is what decides, and writing
      // "system" into the attribute would stop it matching.
      root.setAttribute("data-theme-source", "system");
    } else {
      root.setAttribute("data-theme", saved);
      root.setAttribute("data-theme-source", "user");
    }
  } else {
    root.setAttribute("data-theme", "paper");
    root.setAttribute("data-theme-source", "default");
  }

  root.classList.add("has-js");

  // One voice for every script on the page - see #announcer in the body.
  // Cleared first and filled a beat later, so the same sentence twice
  // in a row ("updated just now") is announced twice rather than
  // swallowed as no change.
  window.openResultsAnnounce = (text) => {
    const region = document.getElementById("announcer");
    if (!region || !text) { return; }
    region.textContent = "";
    setTimeout(() => { region.textContent = text; }, 100);
  };
})();
