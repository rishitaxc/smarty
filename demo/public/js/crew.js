// Loads assets/crew.svg once and mounts live, animatable copies of each character.
const STATES = ["talk", "work", "alert", "happy", "deny", "approve", "sleep"];
let source = null;
const mounted = { pip: [], scout: [], bolt: [], gate: [] };

export async function loadCrew() {
  const text = await (await fetch("assets/crew.svg")).text();
  source = new DOMParser().parseFromString(text, "image/svg+xml");
  const style = document.createElement("style");
  style.textContent = source.getElementById("crew-style").textContent;
  document.head.appendChild(style);
  document.querySelectorAll("[data-crew]").forEach(mountInto);
}

export function mountInto(el) {
  const who = el.dataset.crew;
  const node = document.importNode(source.getElementById(who), true);
  node.removeAttribute("id");
  node.removeAttribute("x");
  node.removeAttribute("y");
  node.setAttribute("width", "100%");
  node.setAttribute("height", "100%");
  el.replaceWith(node);
  // keep any classes/ids that were on the placeholder
  if (el.id) node.id = el.id;
  el.classList.forEach((c) => node.classList.add(c));
  mounted[who].push(node);
  return node;
}

// Set a state on every copy of a character ("idle" clears it).
export function crew(who, state = "idle") {
  for (const node of mounted[who] || []) {
    node.classList.remove(...STATES);
    if (state !== "idle") node.classList.add(state);
  }
}

export function crewNode(node, state = "idle") {
  node.classList.remove(...STATES);
  if (state !== "idle") node.classList.add(state);
}

// Swap which character an existing mounted node shows (used by the caption avatar).
export function swapCharacter(node, who) {
  const fresh = document.importNode(source.getElementById(who), true);
  for (const a of ["id", "x", "y"]) fresh.removeAttribute(a);
  fresh.setAttribute("width", "100%");
  fresh.setAttribute("height", "100%");
  if (node.id) fresh.id = node.id;
  node.replaceWith(fresh);
  for (const list of Object.values(mounted)) {
    const i = list.indexOf(node);
    if (i >= 0) list.splice(i, 1);
  }
  mounted[who].push(fresh);
  return fresh;
}
