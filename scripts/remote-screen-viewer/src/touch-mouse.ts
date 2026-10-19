// Turns touches on the remote desktop into mouse input, the way a trackpad
// does: the pointer is its own thing that fingers push around, so it never sits
// under the finger that is moving it.
//
// - one finger moving: move the pointer by the finger's travel (faster flicks
//   travel further)
// - tap: left click at the pointer
// - hold, then move: left-button drag from the pointer
// - hold and release without moving: right click at the pointer
// - two fingers: scroll at the pointer; two-finger tap: right click

export const MOVE_SLOP_PX = 6;
export const HOLD_MS = 500;
export const LEFT_BUTTON = 1;
export const RIGHT_BUTTON = 2;
/** Pointer travel per px of finger travel for slow, precise movement. */
export const BASE_GAIN = 1.25;
/** Pointer travel per px of finger travel for fast flicks. */
export const MAX_GAIN = 3;
/** Finger speed, in px per ms, at which the gain reaches MAX_GAIN. */
const FAST_PX_PER_MS = 1.5;

export type TouchPoint = { clientX: number; clientY: number; identifier: number };

export type TouchInput = {
  changedTouches: ArrayLike<TouchPoint>;
  touches: ArrayLike<TouchPoint>;
  type: "touchcancel" | "touchend" | "touchmove" | "touchstart";
};

export type Bounds = { bottom: number; left: number; right: number; top: number };

type MouseOutput = {
  /** Where the remote screen is, in client coordinates; the pointer stays on it. */
  bounds(): Bounds;
  /** `buttons` is the DOM pressed-buttons mask after this event. */
  mouse(type: "mousedown" | "mousemove" | "mouseup", x: number, y: number, buttons: number): void;
  now(): number;
  wheel(x: number, y: number, deltaX: number, deltaY: number): void;
};

type Gesture =
  | {
      at: number;
      id: number;
      mode: "pending" | "point" | "drag";
      startedAt: number;
      x: number;
      y: number;
    }
  | { mode: "scroll"; moved: boolean; x: number; y: number };

function center(touches: ArrayLike<TouchPoint>) {
  let x = 0;
  let y = 0;
  for (let index = 0; index < touches.length; index++) {
    x += touches[index]!.clientX;
    y += touches[index]!.clientY;
  }
  return { x: x / touches.length, y: y / touches.length };
}

function find(touches: ArrayLike<TouchPoint>, id: number) {
  for (let index = 0; index < touches.length; index++) {
    if (touches[index]!.identifier === id) return touches[index];
  }
  return undefined;
}

const clamp = (value: number, min: number, max: number) => Math.min(Math.max(value, min), max);

export function gainFor(distance: number, elapsedMs: number) {
  const speed = elapsedMs > 0 ? distance / elapsedMs : 0;
  return BASE_GAIN + (MAX_GAIN - BASE_GAIN) * Math.min(speed / FAST_PX_PER_MS, 1);
}

export function createTouchMouse(output: MouseOutput) {
  let gesture: Gesture | null = null;
  // Starts in the middle of the screen, and is shown there on the first touch.
  let pointer: { x: number; y: number } | null = null;

  const place = () => {
    if (pointer) return pointer;
    const bounds = output.bounds();
    pointer = { x: (bounds.left + bounds.right) / 2, y: (bounds.top + bounds.bottom) / 2 };
    output.mouse("mousemove", pointer.x, pointer.y, 0);
    return pointer;
  };

  const push = (deltaX: number, deltaY: number, elapsedMs: number, buttons: number) => {
    const current = place();
    const bounds = output.bounds();
    const gain = gainFor(Math.hypot(deltaX, deltaY), elapsedMs);
    current.x = clamp(current.x + deltaX * gain, bounds.left, bounds.right - 1);
    current.y = clamp(current.y + deltaY * gain, bounds.top, bounds.bottom - 1);
    output.mouse("mousemove", current.x, current.y, buttons);
  };

  const click = (button: number) => {
    const { x, y } = place();
    output.mouse("mousedown", x, y, button);
    output.mouse("mouseup", x, y, 0);
  };

  return (event: TouchInput) => {
    if (event.type === "touchstart") {
      place();
      if (!gesture) {
        const point = event.changedTouches[0]!;
        const now = output.now();
        gesture = {
          at: now,
          id: point.identifier,
          mode: "pending",
          startedAt: now,
          x: point.clientX,
          y: point.clientY,
        };
      }
      // A second finger before the first has moved means scrolling.
      if (event.touches.length === 2 && gesture.mode === "pending") {
        const middle = center(event.touches);
        gesture = { mode: "scroll", moved: false, x: middle.x, y: middle.y };
      }
      return;
    }

    if (!gesture) return;

    if (event.type === "touchmove") {
      if (gesture.mode === "scroll") {
        if (event.touches.length < 2) return;
        const middle = center(event.touches);
        const deltaX = gesture.x - middle.x;
        const deltaY = gesture.y - middle.y;
        if (!gesture.moved && Math.hypot(deltaX, deltaY) < MOVE_SLOP_PX) return;
        gesture.moved = true;
        // Content follows the fingers, as it does everywhere else on iOS.
        const { x, y } = place();
        output.wheel(x, y, deltaX, deltaY);
        gesture.x = middle.x;
        gesture.y = middle.y;
        return;
      }
      const point = find(event.touches, gesture.id);
      if (!point) return;
      const now = output.now();
      if (gesture.mode === "pending") {
        if (Math.hypot(point.clientX - gesture.x, point.clientY - gesture.y) < MOVE_SLOP_PX) {
          return;
        }
        if (now - gesture.startedAt >= HOLD_MS) {
          const { x, y } = place();
          output.mouse("mousedown", x, y, LEFT_BUTTON);
          gesture.mode = "drag";
        } else {
          gesture.mode = "point";
        }
        // A finger that rested before moving says nothing about its speed.
        gesture.at = now;
      }
      push(
        point.clientX - gesture.x,
        point.clientY - gesture.y,
        now - gesture.at,
        gesture.mode === "drag" ? LEFT_BUTTON : 0,
      );
      gesture.at = now;
      gesture.x = point.clientX;
      gesture.y = point.clientY;
      return;
    }

    // touchend / touchcancel. Pointing and dragging end with their own finger,
    // wherever the others are; everything else acts once the last finger lifts.
    if (gesture.mode === "point" || gesture.mode === "drag") {
      if (!find(event.changedTouches, gesture.id)) return;
      const dragging = gesture.mode === "drag";
      gesture = null;
      if (dragging) {
        const { x, y } = place();
        output.mouse("mouseup", x, y, 0);
      }
      return;
    }
    if (event.touches.length > 0) return;
    const finished = gesture;
    gesture = null;
    // A cancelled touch (a system gesture took over) never clicks.
    if (event.type === "touchcancel") return;
    if (finished.mode === "scroll") {
      if (!finished.moved) click(RIGHT_BUTTON);
      return;
    }
    const held = output.now() - finished.startedAt >= HOLD_MS;
    click(held ? RIGHT_BUTTON : LEFT_BUTTON);
  };
}
