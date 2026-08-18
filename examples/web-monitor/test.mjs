import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const appSource = fs.readFileSync(path.join(scriptDirectory, "app.js"), "utf8");

class MockClassList {
  values = new Set();
  add(value) { this.values.add(value); }
  remove(value) { this.values.delete(value); }
  toggle(value, force) {
    if (force === true) this.values.add(value);
    else if (force === false) this.values.delete(value);
    else if (this.values.has(value)) this.values.delete(value);
    else this.values.add(value);
  }
}

class MockElement {
  constructor(id) {
    this.id = id;
    this.innerHTML = "";
    this.textContent = "";
    this.classList = new MockClassList();
    this.listeners = new Map();
    this.width = 0;
    this.height = 0;
  }
  addEventListener(type, listener) { this.listeners.set(type, listener); }
  click() { this.listeners.get("click")?.({}); }
  getBoundingClientRect() {
    return { left: 0, top: 0, width: 800, height: 600, right: 800, bottom: 600 };
  }
}

const context2d = new Proxy({}, {
  get(target, property) {
    if (!(property in target)) target[property] = () => {};
    return target[property];
  },
  set(target, property, value) {
    target[property] = value;
    return true;
  }
});

const elements = new Map();
for (const id of [
  "inputArea", "canvas", "pointerList", "eventLog", "emptyState",
  "pointerCount", "touchCount", "maxTouchCount", "eventCount",
  "supportStatus", "clearButton", "fullscreenButton"
]) {
  elements.set(id, new MockElement(id));
}
elements.get("canvas").getContext = () => context2d;

const document = {
  visibilityState: "visible",
  fullscreenElement: null,
  documentElement: { requestFullscreen() {} },
  querySelector(selector) { return elements.get(selector.replace(/^#/, "")); },
  addEventListener() {},
  hasFocus() { return true; },
  exitFullscreen() {}
};

class MockWebSocket {
  static OPEN = 1;
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.listeners = new Map();
  }
  addEventListener(type, listener) { this.listeners.set(type, listener); }
  send() {}
  close() {}
}

const windowObject = {
  devicePixelRatio: 1,
  innerWidth: 1920,
  innerHeight: 1040,
  outerWidth: 1920,
  outerHeight: 1080,
  screenX: 0,
  screenY: 0,
  screen: { width: 1920, height: 1080, availLeft: 0, availTop: 0 },
  addEventListener() {},
  setTimeout() { return 1; },
  clearTimeout() {},
  setInterval() { return 1; }
};

const sandbox = {
  console,
  document,
  window: windowObject,
  location: { protocol: "http:", host: "127.0.0.1:8080", search: "" },
  URL,
  URLSearchParams,
  WebSocket: MockWebSocket,
  ResizeObserver: class { observe() {} },
  requestAnimationFrame() { return 1; },
  performance,
  fetch: async () => ({ ok: true, json: async () => ({}) }),
  Intl,
  Date,
  Map,
  Set,
  Math,
  Number,
  JSON
};
sandbox.globalThis = sandbox;

const exportSource = `\n;globalThis.__appTest = {
  handleMessage,
  updatePanels,
  inputColor,
  mouseAction,
  touchAction,
  penAction,
  penSideButtonChanges,
  stablePenTipDown,
  recordEvent,
  resolveBridgeEndpoints,
  getInputs: () => [...inputs.values()],
  getRecentEvents: () => [...recentEvents],
  getSequenceGaps: () => sequenceGaps
};`;
vm.runInNewContext(appSource + exportSource, sandbox, { filename: "app.js" });

const status = {
  protocolVersion: 1,
  url: "http://127.0.0.1:8765",
  native: {
    platform: "windows",
    touchReady: true,
    penReady: true,
    touchDevices: [{
      deviceId: 1,
      logicalOriginX: 0,
      logicalOriginY: 0,
      logicalWidth: 1920,
      logicalHeight: 1080
    }],
    wintabX: { min: 0, max: 10000 },
    wintabY: { min: 0, max: 10000 },
    wintabMaxPressure: 2047,
    wintabOverlapMessages: 3,
    wintabPromotionSuccesses: 2,
    wintabPromotionAttempts: 2,
    activeBrowserClients: 1,
    touchFrames: 1,
    penPackets: 1
  }
};

const test = sandbox.__appTest;
assert.equal(test.resolveBridgeEndpoints("").http, "http://127.0.0.1:8765");
assert.equal(test.resolveBridgeEndpoints("").webSocket, "ws://127.0.0.1:8765/ws");
assert.equal(
  test.resolveBridgeEndpoints("?bridge=http%3A%2F%2F127.0.0.1%3A9876").webSocket,
  "ws://127.0.0.1:9876/ws"
);
assert.equal(
  test.resolveBridgeEndpoints("?bridge=https%3A%2F%2Fbridge.example.test").webSocket,
  "wss://bridge.example.test/ws"
);
assert.equal(test.resolveBridgeEndpoints("?bridge=file%3A%2F%2Ftmp").http, "http://127.0.0.1:8765");
assert.equal(test.mouseAction("pointerenter", false), "Mouse Enter");
assert.equal(test.mouseAction("pointermove", false), "Mouse Hover");
assert.equal(test.mouseAction("pointerdown", true), "Mouse Down");
assert.equal(test.mouseAction("pointermove", true), "Mouse Move");
assert.equal(test.mouseAction("pointerup", false), "Mouse Up");
assert.equal(test.mouseAction("pointerleave", false), "Mouse Leave");
assert.equal(test.mouseAction("pointercancel", false), "Mouse Cancel");
assert.equal(test.touchAction(undefined, { down: true }, "down"), "Touch Down");
assert.equal(test.touchAction({ down: true }, { down: true }, "hold"), "Touch Move");
assert.equal(test.touchAction({ down: true }, { down: false }, "up"), "Touch Up");
assert.equal(test.penAction(undefined, { tipDown: false }), "Pen Hover");
assert.equal(test.penAction({ tipDown: false }, { tipDown: true }), "Pen Down");
assert.equal(test.penAction({ tipDown: true }, { tipDown: true }), "Pen Move");
assert.equal(test.penAction({ tipDown: true }, { tipDown: false }), "Pen Up");
const normalizedButtonChanges = (previous, current) =>
  JSON.parse(JSON.stringify(test.penSideButtonChanges(previous, current)));
assert.deepEqual(
  normalizedButtonChanges(0x1, 0x2),
  [{ button: 1, down: true }]
);
assert.deepEqual(
  normalizedButtonChanges(0x2, 0x1),
  [{ button: 1, down: false }]
);
assert.deepEqual(
  normalizedButtonChanges(0, 0x6),
  [{ button: 1, down: true }, { button: 2, down: true }]
);
assert.equal(
  test.stablePenTipDown({ tipDown: true }, false, true, 0x4, true),
  true
);
assert.equal(
  test.stablePenTipDown({ tipDown: true }, false, true, 0x4, false),
  true
);
assert.equal(
  test.stablePenTipDown({ tipDown: true }, false, true, 0, true),
  true
);
assert.equal(
  test.stablePenTipDown({ tipDown: true }, false, true, 0, false, 0),
  true
);
assert.equal(
  test.stablePenTipDown({ tipDown: true }, false, true, 0, false, 84),
  false
);
assert.equal(
  test.stablePenTipDown({ tipDown: false }, false, true, 0x4, true),
  false
);
assert.equal(
  test.stablePenTipDown({ tipDown: true }, false, true, 0, false, 84),
  false
);
assert.equal(
  test.stablePenTipDown({ tipDown: true }, true, false, 0x4, true),
  true
);

test.handleMessage({ type: "bridge.hello", protocolVersion: 1, status });
test.handleMessage({
  sequence: 1,
  type: "touch.frame",
  deviceId: 1,
  touch: {
    frameNumber: 10,
    contacts: [{
      id: 7,
      state: "WMTFingerStateDown",
      x: 960,
      y: 540,
      width: 24,
      height: 20,
      sensitivity: 12,
      orientation: 45,
      confidence: false
    }]
  }
});
test.handleMessage({
  sequence: 2,
  type: "pen.packet",
  deviceId: 2,
  pen: {
    serial: 20,
    cursor: 1,
    x: 5000,
    y: 5000,
    z: 18,
    pressure: 1024,
    tangentialPressure: 0,
    buttons: 1,
    azimuth: 900,
    altitude: 600,
    twist: 120,
    status: 0,
    changed: 1
  }
});

let inputs = test.getInputs();
const touch = inputs.find(input => input.type === "touch");
const pen = inputs.find(input => input.type === "pen");
assert.equal(inputs.length, 2);
assert.equal(touch.state, "WMTFingerStateDown");
assert.equal(touch.down, true);
assert.equal(touch.confidence, false);
assert.equal(test.inputColor(touch), "#ff5d73");
assert.equal(pen.hasCommonTilt, false);
assert.equal(pen.deviceType, "pen");
assert.equal(pen.down, true);
assert.ok(Math.abs(pen.pressure - 1024 / 2047) < 1e-9);
assert.equal(pen.altitude, 60);
assert.equal(pen.azimuth, 90);
assert.equal(pen.rotation, 12);
assert.ok(test.getRecentEvents().some(event => event.type === "Bridge Connected"));
assert.ok(test.getRecentEvents().some(event => event.type === "Touch Down"));
assert.ok(test.getRecentEvents().some(event => event.type === "Pen Down"));

test.updatePanels(true);
assert.match(elements.get("supportStatus").innerHTML, /Windows/);
assert.match(elements.get("supportStatus").innerHTML, /overlap 3/);
assert.match(elements.get("pointerList").innerHTML, /고도 \/ 방위/);
assert.match(elements.get("pointerList").innerHTML, /압력\(raw \/ normalized\)/);

test.handleMessage({
  sequence: 5,
  type: "pen.proximity",
  deviceId: 2,
  proximity: { hardware: false, context: false }
});
assert.equal(test.getSequenceGaps(), 2);
assert.equal(test.getInputs().filter(input => input.type === "pen").length, 0);
assert.ok(test.getRecentEvents().some(event => event.type === "Pen Leave"));

test.handleMessage({
  type: "bridge.hello",
  protocolVersion: 2,
  status: {
    protocolVersion: 2,
    url: "http://127.0.0.1:8765",
    native: {
      platform: "macos",
      touchReady: true,
      penReady: true,
      touchCoordinateSpace: "core-graphics-global-logical",
      penCoordinateSpace: "core-graphics-global-logical",
      touchDevices: [{ deviceId: 3, logicalOriginX: 0, logicalOriginY: 0, logicalWidth: 1920, logicalHeight: 1080 }]
    }
  }
});
test.handleMessage({
  sequence: 6,
  type: "pen.packet",
  deviceId: 3,
  pen: {
    cursor: 2,
    x: 120,
    y: 240,
    z: 0,
    absoluteX: 120,
    absoluteY: 240,
    absoluteZ: 0,
    screenX: 120,
    screenY: 240,
    hasScreenLocation: true,
    pressure: 32768,
    normalizedPressure: 0.5,
    normalizedTangentialPressure: 0,
    buttons: 0,
    tipDown: false,
    tiltX: 0.25,
    tiltY: -0.5,
    rotation: 30,
    pointingDeviceType: "eraser",
    uniqueId: 99,
    status: 16,
    changed: 0
  }
});

inputs = test.getInputs();
const macPen = inputs.find(input => input.type === "pen");
assert.equal(macPen.hasCommonTilt, true);
assert.equal(macPen.tiltX, 0.25);
assert.equal(macPen.tiltY, -0.5);
assert.equal(macPen.pressure, 0.5);
assert.equal(macPen.deviceType, "eraser");
assert.equal(macPen.inverted, true);
test.updatePanels(true);
assert.match(elements.get("supportStatus").innerHTML, /macOS/);
assert.match(elements.get("pointerList").innerHTML, /Tilt X \/ Y/);
assert.ok(test.getRecentEvents().some(event => event.type === "Pen Hover"));
assert.doesNotMatch(elements.get("eventLog").innerHTML, /touch\.frame|pen\.packet|pen\.proximity/);

test.recordEvent("Pen Down", "separator");
test.recordEvent("Pen Hover", "first", true);
test.recordEvent("Pen Hover", "second", true);
test.recordEvent("Pen Hover", "last", true);
let events = test.getRecentEvents();
assert.equal(events[0].type, "Pen Hover");
assert.equal(events[0].count, 3);
assert.equal(events[0].detail, "last");
assert.equal(events[1].type, "Pen Down");
test.recordEvent("Touch Move", "touch", true);
test.recordEvent("Pen Hover", "new group", true);
events = test.getRecentEvents();
assert.equal(events[0].type, "Pen Hover");
assert.equal(events[0].count, 1);
test.updatePanels(true);
assert.match(elements.get("eventLog").innerHTML, /Pen Hover ×3/);

console.log("example-monitor-tests=ok protocols=1,2 platforms=windows,macos configurable-bridge=ok");
