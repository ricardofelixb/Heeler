// Turns what the iOS keyboard types into a hidden text field into remote key
// presses. The soft keyboard does not report reliable key events, so the field
// is compared before and after each edit: removed characters become
// backspaces, added ones become their keysyms. The field starts filled so
// backspace always has something to delete (an empty field reports nothing).

export const XK_BACKSPACE = 0xff08;
export const XK_TAB = 0xff09;
export const XK_RETURN = 0xff0d;
export const XK_ESCAPE = 0xff1b;

/** Keys that never reach the text field and are sent straight from keydown. */
export const SPECIAL_KEYS: Record<string, { code: string; keysym: number }> = {
  ArrowDown: { code: "ArrowDown", keysym: 0xff54 },
  ArrowLeft: { code: "ArrowLeft", keysym: 0xff51 },
  ArrowRight: { code: "ArrowRight", keysym: 0xff53 },
  ArrowUp: { code: "ArrowUp", keysym: 0xff52 },
  Delete: { code: "Delete", keysym: 0xffff },
  End: { code: "End", keysym: 0xff57 },
  Enter: { code: "Enter", keysym: XK_RETURN },
  Escape: { code: "Escape", keysym: XK_ESCAPE },
  Home: { code: "Home", keysym: 0xff50 },
  PageDown: { code: "PageDown", keysym: 0xff56 },
  PageUp: { code: "PageUp", keysym: 0xff55 },
  Tab: { code: "Tab", keysym: XK_TAB },
};

export const FILLER = "_".repeat(64);

/** Latin-1 maps to itself; everything else uses X11's Unicode keysym range. */
export function keysymFor(codePoint: number) {
  if (codePoint === 0x0a) return XK_RETURN;
  if (codePoint === 0x09) return XK_TAB;
  if (codePoint >= 0x20 && codePoint <= 0xff) return codePoint;
  return 0x01000000 | codePoint;
}

export type KeyPress = { code?: string; keysym: number };

/**
 * The key presses that turn `before` into `after`, and the text the field
 * should hold next (the filler again once it runs low or grows long).
 */
export function diffInput(before: string, after: string) {
  let common = 0;
  const shortest = Math.min(before.length, after.length);
  while (common < shortest && before[common] === after[common]) common++;
  // Never split a surrogate pair.
  if (common > 0 && /[\uD800-\uDBFF]/.test(before[common - 1]!)) common--;

  const keys: KeyPress[] = [];
  const removed = Array.from(before.slice(common)).length;
  for (let index = 0; index < removed; index++) {
    keys.push({ code: "Backspace", keysym: XK_BACKSPACE });
  }
  for (const character of Array.from(after.slice(common))) {
    const keysym = keysymFor(character.codePointAt(0)!);
    keys.push(keysym === XK_RETURN ? { code: "Enter", keysym } : { keysym });
  }
  const refill = after.length < FILLER.length / 2 || after.length > FILLER.length * 2;
  return { keys, next: refill ? FILLER : after };
}
