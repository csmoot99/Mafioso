// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error,
//     cards:[{title,images:[{src,alt,lazy}],note:{tag,maxLength,count,limit}|null}],
//     statLinks:[{label,href,scrolledTo,prevented}], arrow:{moved,scrolled,count},
//     send:{foreign,sent,restored,all,misrouted} } - the board after "fm-board:send"
//     messages from the Lavish chrome (see sendMessage below)
// The shim records listeners so the harness can drive the page the way a
// captain does: tap each summary card, type past the note cap, press the arrows.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.id = "";
    this.listeners = {};
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x !== c).join(" "); },
      toggle: (c, on) => {
        if (on) this.classList.add(c); else this.classList.remove(c);
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatch(type, extra = {}) {
    const ev = { type, target: this, prevented: false, preventDefault() { this.prevented = true; }, ...extra };
    for (const fn of this.listeners[type] || []) fn(ev);
    return ev;
  }
  getBoundingClientRect() { return { top: -50 }; }
  scrollIntoView(opts) { scrolls.push({ id: this.id, className: this.className, opts }); }
  focus() {}
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const scrolls = [];
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      n.id = id;
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const parentWindow = { name: "lavish-chrome" };
const windowListeners = {};
globalThis.window = {
  innerHeight: 800,
  parent: parentWindow,
  addEventListener: (type, fn) => { (windowListeners[type] ||= []).push(fn); },
};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));
const statLinks = strip.children.map((t) => {
  const before = scrolls.length;
  const ev = t.dispatch("click");
  return {
    label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
    href: t.href,
    scrolledTo: scrolls.slice(before).map((x) => x.id),
    prevented: ev.prevented,
  };
});

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const call = byId.get("bb-call") || new Node("div");
// Type a value far past any cap into a card's note field, as a paste would.
const noteOf = (card, typed) => {
  const ta = card.querySelectorAll(".bb-freeform")[0];
  if (!ta) return null;
  ta.value = typed;
  ta.dispatch("input");
  return {
    tag: ta.tagName,
    maxLength: ta.maxLength,
    bytes: new TextEncoder().encode(ta.value).length,
    count: card.querySelectorAll(".bb-count")[0]?.textContent ?? "",
    limit: card.querySelectorAll(".bb-limit")[0]?.textContent ?? "",
  };
};
const cards = call.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => ({
    title: card.querySelectorAll(".bb-decision__title")[0]?.textContent ?? "",
    images: card.querySelectorAll(".bb-shot__img").map((i) => ({
      src: i.src, alt: i.alt, lazy: i.loading === "lazy",
    })),
    note: noteOf(card, "\u00e9".repeat(700)),
  }));
// Press "next" once: the shown card changes and its top is brought into view.
const nextBtn = byId.get("bb-stack-next");
const beforeNext = scrolls.length;
const countText = () => byId.get("bb-stack-count")?.textContent ?? "";
const countBefore = countText();
nextBtn?.dispatch("click");
const arrow = {
  moved: countText() !== countBefore,
  scrolled: scrolls.slice(beforeNext).some((x) => x.className.includes("bb-decision")),
  count: countText(),
};

// Deliver a message the way the browser does: to every "message" listener on
// the window, from <source> (the parent chrome unless told otherwise).
const sendMessage = (data, source = parentWindow) => {
  for (const fn of windowListeners.message || []) fn({ data, source });
};
const need = () => strip.children.find((t) => t.className.includes("bb-stat--call"))
  ?.children.find((c) => c.className.includes("bb-stat__num"))?.textContent;
const deckState = () => ({
  shown: call.children
    .filter((c) => c.className.split(/\s+/).includes("bb-decision") && !c.hidden)
    .map((c) => c.querySelectorAll(".bb-decision__title")[0]?.textContent),
  count: countText(),
  need: need(),
  sub: byId.get("bb-call-sub")?.textContent ?? "",
  empty: call.className.split(/\s+/).includes("bb-call--empty"),
  navHidden: byId.get("bb-stack-count")?.parentNode?.hidden ?? false,
});
const item = (n, title, answer) => ({
  selector: `div#bb-call > div:nth-of-type(${n}) > div > form`,
  text: `${title} -> ${answer}`,
});
const first = cards[0]?.title, second = cards[1]?.title;
const send = {};
// Another window's message is ignored.
sendMessage({ type: "fm-board:send", phase: "start", id: "x", items: [item(1, first, "yes")] }, {});
send.foreign = deckState();
// A send hides the card it carried: found by its form's position.
sendMessage({ type: "fm-board:send", phase: "start", id: "a", items: [item(1, first, "yes")] });
send.sent = deckState();
// The same send failing deals it back.
sendMessage({ type: "fm-board:send", phase: "failed", id: "a", items: [item(1, first, "yes")] });
send.restored = deckState();
// A selector pointing at the wrong card falls back to the card the text names;
// a second send then empties the board.
sendMessage({ type: "fm-board:send", phase: "start", id: "b", items: [item(1, second, "yes")] });
send.misrouted = deckState();
sendMessage({ type: "fm-board:send", phase: "sent", id: "c", items: [item(1, first, "yes")] });
send.all = deckState();

process.stdout.write(
  JSON.stringify({ stats, statLinks, underway, charted, empty, more, cards, arrow, send, error: errorText }) + "\n");
