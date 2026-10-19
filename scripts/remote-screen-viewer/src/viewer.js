// Runs inside the WebView that shows a Host's screen. The app owns the
// connection (an SSH tunnel to the Host's VNC server) and relays its bytes
// through `window.heelerScreen`; noVNC sees them as a WebSocket. Adapted from
// agents-app's Orgo computer viewer.
import RFB from "@novnc/novnc";

import { diffInput, FILLER, SPECIAL_KEYS } from "./keyboard-input";
import { createTouchMouse, RIGHT_BUTTON } from "./touch-mouse";

const post = (message) => window.webkit?.messageHandlers?.screen?.postMessage(message);
let rfb = null;
let channel = null;
let closedByApp = false;
let frameTimer = null;
let failed = false;

function toBase64(bytes) {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(index, index + 0x8000));
  }
  return btoa(binary);
}

function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

// The WebSocket surface noVNC drives (core/websock.js `rawChannelProps`).
// Bytes go to the app as base64; the app's replies arrive through `receive`.
class AppChannel {
  constructor() {
    this.binaryType = "arraybuffer";
    this.protocol = "";
    this.readyState = "connecting";
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
  }

  send(data) {
    if (this.readyState !== "open") return;
    const bytes =
      data instanceof ArrayBuffer
        ? new Uint8Array(data)
        : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    post({ type: "send", data: toBase64(bytes) });
  }

  close() {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    post({ type: "close" });
    this.onclose?.({ code: 1000, reason: "", wasClean: true });
  }

  opened() {
    this.readyState = "open";
    this.onopen?.({});
  }

  received(text) {
    if (this.readyState === "open") this.onmessage?.({ data: fromBase64(text) });
  }

  ended(reason) {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    this.onclose?.({ code: 1006, reason: reason ?? "", wasClean: false });
  }
}

// A small still of the screen, so the app can show the last view while the
// live connection is being reopened. Null until noVNC has drawn something.
function captureStill() {
  const source = canvas();
  if (!source || source.width === 0 || source.height === 0) return null;
  const scale = Math.min(1, 480 / source.width);
  const still = document.createElement("canvas");
  still.width = Math.max(1, Math.round(source.width * scale));
  still.height = Math.max(1, Math.round(source.height * scale));
  const context = still.getContext("2d");
  if (!context) return null;
  context.drawImage(source, 0, 0, still.width, still.height);
  const pixels = context.getImageData(0, 0, still.width, still.height).data;
  for (let index = 3; index < pixels.length; index += 4) {
    if (pixels[index] !== 0) return still.toDataURL("image/jpeg", 0.5);
  }
  return null;
}

// noVNC reports "connect" before the first framebuffer is drawn, so poll
// quickly until something is on screen.
function watchFrames() {
  frameTimer = setInterval(() => {
    if (!captureStill()) return;
    clearInterval(frameTimer);
    frameTimer = null;
    post({ type: "rendered" });
  }, 200);
}

function teardown() {
  closedByApp = true;
  clearInterval(frameTimer);
  frameTimer = null;
  document.activeElement?.blur?.();
  rfb?.disconnect();
  channel?.close();
  rfb = null;
  channel = null;
}

function canvas() {
  return document.querySelector("#screen canvas");
}

// A mousedown makes noVNC capture the pointer. WebKit has no
// Element.setCapture, so noVNC shows a full-screen proxy element that forwards
// mouse events to the canvas and releases the capture on mouseup. Real mouse
// events reach that proxy by hit testing; synthetic ones must be sent to it,
// or the capture is never released and the proxy covers the screen.
function mouseTarget() {
  if (document.captureElement) {
    const proxy = document.getElementById("noVNC_mouse_capture_elem");
    if (proxy) return proxy;
  }
  return canvas();
}

const handleTouch = createTouchMouse({
  bounds() {
    const rect = canvas()?.getBoundingClientRect();
    if (rect && rect.width > 0 && rect.height > 0) return rect;
    return { bottom: window.innerHeight, left: 0, right: window.innerWidth, top: 0 };
  },
  mouse(type, x, y, buttons) {
    mouseTarget()?.dispatchEvent(
      new MouseEvent(type, {
        bubbles: true,
        button: type === "mousemove" ? 0 : buttons === RIGHT_BUTTON ? 2 : 0,
        buttons,
        cancelable: true,
        clientX: x,
        clientY: y,
      }),
    );
  },
  now: () => Date.now(),
  wheel(x, y, deltaX, deltaY) {
    canvas()?.dispatchEvent(
      new WheelEvent("wheel", {
        bubbles: true,
        cancelable: true,
        clientX: x,
        clientY: y,
        deltaMode: 0,
        deltaX,
        deltaY,
      }),
    );
  },
});

// Captured at the document, above noVNC's canvas listeners and its capture
// proxy, so its gesture handler never sees a touch; cancelled so WebKit adds
// no emulated mouse events of its own. noVNC's mouse and wheel listeners then
// receive plain DOM events.
function onTouch(event) {
  if (!rfb || rfb.viewOnly) return;
  event.preventDefault();
  event.stopPropagation();
  handleTouch(event);
}

for (const type of ["touchstart", "touchmove", "touchend", "touchcancel"]) {
  document.addEventListener(type, onTouch, { capture: true, passive: false });
}

// The iOS keyboard only opens for a focused text field. This one is invisible
// and pinned to the top, so WebKit never scrolls the page to reveal it; the
// app shows and hides the keyboard by focusing it. Touches never move focus
// (they are cancelled above), so the keyboard stays up while the pointer moves.
const keyboard = document.createElement("textarea");
for (const [name, value] of Object.entries({
  "aria-hidden": "true",
  autocapitalize: "off",
  autocomplete: "off",
  autocorrect: "off",
  spellcheck: "false",
})) {
  keyboard.setAttribute(name, value);
}
keyboard.style.cssText =
  "position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;border:0;padding:0;" +
  "font-size:16px;resize:none;caret-color:transparent;pointer-events:none";
let typed = FILLER;
function resetKeyboard() {
  typed = FILLER;
  keyboard.value = FILLER;
  keyboard.setSelectionRange(FILLER.length, FILLER.length);
}
resetKeyboard();
keyboard.addEventListener("keydown", (event) => {
  const special = SPECIAL_KEYS[event.key];
  if (!special) return;
  event.preventDefault();
  rfb?.sendKey(special.keysym, special.code);
});
keyboard.addEventListener("input", () => {
  const { keys, next } = diffInput(typed, keyboard.value);
  for (const key of keys) rfb?.sendKey(key.keysym, key.code);
  if (next === FILLER && keyboard.value !== FILLER) resetKeyboard();
  else typed = next;
});
keyboard.addEventListener("focus", () => post({ type: "keyboard", open: true }));
keyboard.addEventListener("blur", () => post({ type: "keyboard", open: false }));
document.body.appendChild(keyboard);

window.heelerScreen = {
  // Starts a session over a fresh channel; the app then calls `opened` once
  // its tunnel is up, `receive` for each chunk, and `ended` when it drops.
  connect(options = {}) {
    teardown();
    closedByApp = false;
    failed = false;
    channel = new AppChannel();
    rfb = new RFB(document.getElementById("screen"), channel, {
      shared: true,
      credentials: { password: options.password ?? "" },
    });
    // Only no auth or a VNC password: macOS offers Apple's account login
    // first, which would want the user's Mac password. Pinned noVNC 1.7.0.
    rfb._isSupportedSecurityType = (type) => type === 1 || type === 2;
    rfb.viewOnly = options.viewOnly ?? true;
    // A click would focus the canvas and close the keyboard.
    rfb.focusOnClick = false;
    // Some desktops hide their pointer; a dot keeps it findable.
    rfb.showDotCursor = true;
    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.background = "transparent";
    rfb.qualityLevel = 6;
    rfb.compressionLevel = 2;
    rfb.addEventListener("connect", () => {
      post({ type: "connected" });
      watchFrames();
    });
    rfb.addEventListener("disconnect", () => {
      // A specific failure was already reported; keep it.
      if (!closedByApp && !failed) post({ type: "disconnected" });
    });
    rfb.addEventListener("credentialsrequired", () => {
      if (!options.password) {
        // The app asks the user rather than trying an empty password.
        failed = true;
        post({ type: "error", reason: "auth" });
        teardown();
        return;
      }
      rfb?.sendCredentials({ password: options.password });
    });
    rfb.addEventListener("securityfailure", () => {
      failed = true;
      post({ type: "error", reason: "auth" });
    });
  },
  opened() {
    channel?.opened();
  },
  receive(text) {
    channel?.received(text);
  },
  ended(reason) {
    channel?.ended(reason);
  },
  toggleKeyboard() {
    if (document.activeElement === keyboard) {
      keyboard.blur();
      return;
    }
    if (!rfb || rfb.viewOnly) return;
    resetKeyboard();
    keyboard.focus({ preventScroll: true });
  },
  setViewOnly(viewOnly) {
    if (rfb) rfb.viewOnly = viewOnly;
  },
  disconnect: teardown,
};

post({ type: "ready" });
