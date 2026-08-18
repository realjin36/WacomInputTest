"use strict";

// Example client for the Wacom Native Input Bridge protocol.

const inputArea = document.querySelector("#inputArea");
const canvas = document.querySelector("#canvas");
const ctx = canvas.getContext("2d");
const pointerList = document.querySelector("#pointerList");
const eventLog = document.querySelector("#eventLog");
const emptyState = document.querySelector("#emptyState");
const pointerCountElement = document.querySelector("#pointerCount");
const touchCountElement = document.querySelector("#touchCount");
const maxTouchCountElement = document.querySelector("#maxTouchCount");
const eventCountElement = document.querySelector("#eventCount");
const supportStatusElement = document.querySelector("#supportStatus");

const inputs = new Map();
const recentEvents = [];
const colors = { mouse: "#8b9cff", touch: "#45d6a1", touchUntrusted: "#ff5d73", pen: "#ffb84d" };
const MAX_TRAIL_POINTS = 64;
const PANEL_INTERVAL = 80;
const TOUCH_UP_HOLD_MS = 250;
const TOUCH_STALE_MS = 500;
const PEN_STALE_MS = 180;
const RECONNECT_MAX_MS = 3000;
const DEFAULT_BRIDGE_HTTP_URL = "http://127.0.0.1:8765";
const PEN_TILT_INDICATOR_LENGTH = 72;

function resolveBridgeEndpoints(search = globalThis.location?.search || "") {
  const configured = new URLSearchParams(search).get("bridge") || DEFAULT_BRIDGE_HTTP_URL;
  let httpUrl;
  try {
    httpUrl = new URL(configured);
  } catch (_) {
    httpUrl = new URL(DEFAULT_BRIDGE_HTTP_URL);
  }
  if (httpUrl.protocol !== "http:" && httpUrl.protocol !== "https:") {
    httpUrl = new URL(DEFAULT_BRIDGE_HTTP_URL);
  }
  httpUrl.pathname = "/";
  httpUrl.search = "";
  httpUrl.hash = "";

  const webSocketUrl = new URL("ws", httpUrl);
  webSocketUrl.protocol = httpUrl.protocol === "https:" ? "wss:" : "ws:";
  return {
    http: httpUrl.href.replace(/\/$/, ""),
    webSocket: webSocketUrl.href
  };
}

const bridgeEndpoints = resolveBridgeEndpoints();

let socket = null;
let reconnectTimer = 0;
let reconnectDelay = 250;
let clientActive = null;
let clientActivityGeneration = 0;
let bridgeState = "연결 중";
let bridgeStatus = null;
let lastSequence = 0;
let sequenceGaps = 0;
let eventCount = 0;
let maxTouchCount = 0;
let areaRect = inputArea.getBoundingClientRect();
let dpr = 1;
let animationFrame = 0;
let panelTimer = 0;
let lastPanelUpdate = 0;
let canvasDirty = true;
let panelDirty = true;
let eventLogDirty = true;

const timeFormatter = new Intl.DateTimeFormat("ko-KR", {
  hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false
});

function resizeCanvas() {
  areaRect = inputArea.getBoundingClientRect();
  dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.width = Math.round(areaRect.width * dpr);
  canvas.height = Math.round(areaRect.height * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  canvasDirty = true;
  requestRender();
}

function clamp01(value) {
  return Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
}

function mapRange(value, min, max, size, invert = false) {
  const ratio = clamp01((value - min) / Math.max(1, max - min));
  return (invert ? 1 - ratio : ratio) * size;
}

function viewportOriginOnCurrentScreen() {
  const borderX = Math.max(0, (window.outerWidth - window.innerWidth) / 2);
  const chromeTop = Math.max(0, window.outerHeight - window.innerHeight - borderX);
  const monitorLeft = Number.isFinite(window.screen.availLeft) ? window.screen.availLeft : 0;
  const monitorTop = Number.isFinite(window.screen.availTop) ? window.screen.availTop : 0;
  return {
    x: window.screenX - monitorLeft + borderX,
    y: window.screenY - monitorTop + chromeTop
  };
}

function viewportOriginGlobal() {
  const borderX = Math.max(0, (window.outerWidth - window.innerWidth) / 2);
  const chromeTop = Math.max(0, window.outerHeight - window.innerHeight - borderX);
  return {
    x: window.screenX + borderX,
    y: window.screenY + chromeTop
  };
}

function globalScreenPoint(x, y) {
  const origin = viewportOriginGlobal();
  return {
    x: x - origin.x - areaRect.left,
    y: y - origin.y - areaRect.top,
    sx: 1,
    sy: 1
  };
}

function screenPoint(x, y, minX, maxX, minY, maxY, invertY = false) {
  const origin = viewportOriginOnCurrentScreen();
  const screenX = mapRange(x, minX, maxX, window.screen.width);
  const screenY = mapRange(y, minY, maxY, window.screen.height, invertY);
  return {
    x: screenX - origin.x - areaRect.left,
    y: screenY - origin.y - areaRect.top,
    sx: window.screen.width / Math.max(1, maxX - minX),
    sy: window.screen.height / Math.max(1, maxY - minY)
  };
}

function touchDevice(deviceId) {
  return bridgeStatus?.native?.touchDevices?.find(device => device.deviceId === deviceId)
    || bridgeStatus?.native?.touchDevices?.[0];
}

function touchPoint(contact, deviceId) {
  const device = touchDevice(deviceId);
  if (!device) return { x: contact.x, y: contact.y, sx: 1, sy: 1 };
  if (bridgeStatus?.native?.touchCoordinateSpace === "core-graphics-global-logical"
      || bridgeStatus?.native?.platform === "macos") {
    return globalScreenPoint(contact.x, contact.y);
  }
  return screenPoint(
    contact.x, contact.y,
    device.logicalOriginX, device.logicalOriginX + device.logicalWidth,
    device.logicalOriginY, device.logicalOriginY + device.logicalHeight
  );
}

function penPoint(packet) {
  if (packet.hasScreenLocation !== false
      && Number.isFinite(packet.screenX)
      && Number.isFinite(packet.screenY)) {
    return globalScreenPoint(packet.screenX, packet.screenY);
  }
  const xAxis = bridgeStatus?.native?.wintabX;
  const yAxis = bridgeStatus?.native?.wintabY;
  if (xAxis && yAxis) {
    return screenPoint(packet.x, packet.y, xAxis.min, xAxis.max, yAxis.min, yAxis.max, true);
  }
  const device = bridgeStatus?.native?.touchDevices?.[0];
  return device
    ? { x: mapRange(packet.x, 0, device.logicalWidth, areaRect.width), y: mapRange(packet.y, 0, device.logicalHeight, areaRect.height) }
    : { x: 0, y: 0 };
}

function addTrail(input) {
  input.trail.push({ x: input.x, y: input.y });
  if (input.trail.length > MAX_TRAIL_POINTS) input.trail.splice(0, input.trail.length - MAX_TRAIL_POINTS);
}

function inputLabel(type) {
  if (type === "pen") return "펜";
  if (type === "touch") return "터치";
  return "마우스";
}

function inputColor(input) {
  return input.type === "touch" && input.confidence === false
    ? colors.touchUntrusted
    : colors[input.type];
}

function mouseAction(eventType, down) {
  if (eventType === "pointerenter") return "Mouse Enter";
  if (eventType === "pointerdown") return "Mouse Down";
  if (eventType === "pointerup") return "Mouse Up";
  if (eventType === "pointerleave") return "Mouse Leave";
  if (eventType === "pointercancel") return "Mouse Cancel";
  return down ? "Mouse Move" : "Mouse Hover";
}

function handleMousePointer(event) {
  if (event.pointerType !== "mouse") return;

  const key = `mouse:${event.pointerId}`;
  if (event.type === "pointerleave" || event.type === "pointercancel") {
    const previous = inputs.get(key);
    inputs.delete(key);
    eventCount += 1;
    recordEvent(
      mouseAction(event.type, false),
      `x ${fmt(previous?.x)} · y ${fmt(previous?.y)}`
    );
    emptyState.classList.toggle("hidden", inputs.size > 0 || eventCount > 0);
    canvasDirty = true;
    panelDirty = true;
    requestRender();
    return;
  }

  const previous = inputs.get(key);
  const down = event.buttons !== 0;
  const input = {
    key, id: event.pointerId, deviceId: -1, type: "mouse",
    x: event.clientX - areaRect.left,
    y: event.clientY - areaRect.top,
    rawX: event.screenX,
    rawY: event.screenY,
    pressure: Number.isFinite(event.pressure) ? event.pressure : down ? 0.5 : 0,
    buttons: event.buttons,
    down,
    hover: !down,
    trail: previous?.trail || [],
    updatedAt: performance.now()
  };
  addTrail(input);
  inputs.set(key, input);
  eventCount += 1;
  const action = mouseAction(event.type, down);
  recordEvent(
    action,
    `x ${fmt(input.x)} · y ${fmt(input.y)} · ${buttonLabel(input)}`,
    isCoalescibleAction(action)
  );
  emptyState.classList.add("hidden");
  canvasDirty = true;
  panelDirty = true;
  requestRender();
}

function isDownState(state) {
  return state === "down" || state === "hold"
    || state === "WMTFingerStateDown" || state === "WMTFingerStateHold";
}

function isUpState(state) {
  return state === "up" || state === "none"
    || state === "WMTFingerStateUp" || state === "WMTFingerStateNone";
}

function touchAction(previous, input, state) {
  if (isUpState(state)) return previous?.down ? "Touch Up" : null;
  if (input.down && !previous?.down) return "Touch Down";
  if (input.down) return "Touch Move";
  return null;
}

function penAction(previous, input) {
  if (input.tipDown && !previous?.tipDown) return "Pen Down";
  if (!input.tipDown && previous?.tipDown) return "Pen Up";
  return input.tipDown ? "Pen Move" : "Pen Hover";
}

function penSideButtonChanges(previousButtons = 0, currentButtons = 0) {
  const changed = (previousButtons ^ currentButtons) & ~1;
  const changes = [];
  for (let button = 1; button < 31; button += 1) {
    const mask = 2 ** button;
    if ((changed & mask) !== 0) {
      changes.push({ button, down: (currentButtons & mask) !== 0 });
    }
  }
  return changes;
}

function stablePenTipDown(
  previous,
  rawTipDown,
  hasExplicitTipDown,
  currentButtons,
  sideButtonsChanged,
  absoluteZ
) {
  if (!hasExplicitTipDown || !previous || rawTipDown === previous.tipDown) {
    return rawTipDown;
  }
  const sideButtonDown = (currentButtons & ~1) !== 0;
  const remainsAtSurface = Number.isFinite(absoluteZ) && absoluteZ <= 0;
  if (previous.tipDown && !rawTipDown
      && (sideButtonDown || sideButtonsChanged || remainsAtSurface)) {
    return previous.tipDown;
  }
  return rawTipDown;
}

function isCoalescibleAction(action) {
  return action === "Touch Move" || action === "Pen Move" || action === "Pen Hover"
    || action === "Mouse Move" || action === "Mouse Hover";
}

function handleTouchFrame(message) {
  const seen = new Set();
  for (const contact of message.touch.contacts) {
    const key = `touch:${message.deviceId}:${contact.id}`;
    const state = contact.commonState || contact.state;
    if (state === "none" || state === "WMTFingerStateNone") {
      const previous = inputs.get(key);
      if (previous?.down) {
        recordEvent("Touch Up", `x ${fmt(previous.x)} · y ${fmt(previous.y)}`);
      }
      inputs.delete(key);
      continue;
    }
    const previous = inputs.get(key);
    const point = touchPoint(contact, message.deviceId);
    const down = isDownState(state);
    const input = {
      key, id: contact.id, deviceId: message.deviceId, type: "touch",
      x: point.x, y: point.y,
      rawX: contact.x, rawY: contact.y,
      width: contact.width * point.sx, height: contact.height * point.sy,
      rawWidth: contact.width, rawHeight: contact.height,
      sensitivity: contact.sensitivity, orientation: contact.orientation,
      confidence: contact.confidence, state,
      down, hover: false, buttons: down ? 1 : 0, pressure: 0,
      trail: previous?.trail || [], updatedAt: performance.now()
    };
    if (down) addTrail(input);
    inputs.set(key, input);
    seen.add(key);
    scheduleRemoval(key, input, isUpState(state) ? TOUCH_UP_HOLD_MS : TOUCH_STALE_MS);
    const action = touchAction(previous, input, state);
    if (action) {
      recordEvent(
        action,
        `x ${fmt(input.x)} · y ${fmt(input.y)}`,
        isCoalescibleAction(action)
      );
    }
  }

  const activeTouches = [...inputs.values()].filter(input => input.type === "touch" && input.down).length;
  maxTouchCount = Math.max(maxTouchCount, activeTouches);
}

function handlePenPacket(message) {
  const packet = message.pen;
  const identity = Number.isFinite(packet.uniqueId) && packet.uniqueId !== 0 ? packet.uniqueId : packet.cursor;
  const key = `pen:${message.deviceId}:${identity}`;
  const previous = inputs.get(key);
  const point = penPoint(packet);
  const maxPressure = Math.max(1, bridgeStatus?.native?.wintabMaxPressure || 32767);
  const pressure = Number.isFinite(packet.normalizedPressure)
    ? clamp01(packet.normalizedPressure)
    : clamp01(packet.pressure / maxPressure);
  const hasExplicitTipDown = typeof packet.tipDown === "boolean";
  const rawTipDown = hasExplicitTipDown
    ? packet.tipDown
    : pressure > 0 || (packet.buttons & 1) !== 0;
  const sideButtonChanges = penSideButtonChanges(previous?.buttons, packet.buttons);
  const tipDown = stablePenTipDown(
    previous,
    rawTipDown,
    hasExplicitTipDown,
    packet.buttons,
    sideButtonChanges.length > 0,
    packet.absoluteZ
  );
  const deviceType = packet.pointingDeviceType || ((packet.status & 0x10) !== 0 ? "eraser" : "pen");
  const hasCommonTilt = Number.isFinite(packet.tiltX) && Number.isFinite(packet.tiltY);
  const altitude = packet.altitude / 10;
  const azimuth = packet.azimuth / 10;
  const input = {
    key, id: packet.cursor, deviceId: message.deviceId, type: "pen",
    x: point.x, y: point.y,
    rawX: Number.isFinite(packet.absoluteX) ? packet.absoluteX : packet.x,
    rawY: Number.isFinite(packet.absoluteY) ? packet.absoluteY : packet.y,
    screenX: Number.isFinite(packet.screenX) ? packet.screenX : null,
    screenY: Number.isFinite(packet.screenY) ? packet.screenY : null,
    z: Number.isFinite(packet.absoluteZ) ? packet.absoluteZ : packet.z,
    pressure, rawPressure: packet.pressure,
    tangentialPressure: Number.isFinite(packet.normalizedTangentialPressure)
      ? packet.normalizedTangentialPressure : packet.tangentialPressure,
    buttons: packet.buttons, tipDown,
    down: tipDown || packet.buttons !== 0,
    hover: !tipDown && packet.buttons === 0,
    tiltX: hasCommonTilt ? packet.tiltX : null,
    tiltY: hasCommonTilt ? packet.tiltY : null,
    hasCommonTilt,
    azimuth, altitude,
    rotation: Number.isFinite(packet.rotation) ? packet.rotation : packet.twist / 10,
    twist: Number.isFinite(packet.rotation) ? packet.rotation : packet.twist / 10,
    deviceType,
    uniqueId: packet.uniqueId || 0,
    inverted: deviceType === "eraser" || (packet.status & 0x10) !== 0,
    status: packet.status, changed: packet.changed,
    trail: previous?.trail || [], updatedAt: performance.now()
  };
  addTrail(input);
  inputs.set(key, input);
  scheduleRemoval(key, input, PEN_STALE_MS);
  for (const change of sideButtonChanges) {
    const deviceDetail = deviceType === "pen" ? "" : `${deviceType} · `;
    recordEvent(
      change.down ? "Pen Button Down" : "Pen Button Up",
      `button ${change.button} · ${deviceDetail}x ${fmt(input.x)} · y ${fmt(input.y)}`
    );
  }
  const action = penAction(previous, input);
  if (sideButtonChanges.length === 0 || action === "Pen Down" || action === "Pen Up") {
    const deviceDetail = deviceType === "pen" ? "" : `${deviceType} · `;
    recordEvent(
      action,
      `${deviceDetail}x ${fmt(input.x)} · y ${fmt(input.y)} · ${buttonLabel(input)}`,
      isCoalescibleAction(action)
    );
  }
}

function handleProximity(message) {
  const proximity = message.proximity;
  const entering = typeof proximity.entering === "boolean"
    ? proximity.entering
    : proximity.hardware || proximity.context;
  const deviceType = proximity.pointingDeviceType || "pen";
  recordEvent(entering ? "Pen Enter" : "Pen Leave", deviceType === "pen" ? "" : deviceType);
  if (!entering) {
    for (const [key, input] of inputs) if (input.type === "pen") inputs.delete(key);
  }
}

function scheduleRemoval(key, expected, delay) {
  window.setTimeout(() => {
    if (inputs.get(key) === expected) {
      inputs.delete(key);
      canvasDirty = true;
      panelDirty = true;
      requestRender();
    }
  }, delay);
}

function recordEvent(type, detail, coalesce = false) {
  const time = timeFormatter.format(new Date());
  const latest = recentEvents[0];
  if (coalesce && latest?.coalesce && latest.type === type) {
    latest.detail = detail;
    latest.time = time;
    latest.count += 1;
    eventLogDirty = true;
    return;
  }
  recentEvents.unshift({ type, detail, time, count: 1, coalesce });
  recentEvents.splice(12);
  eventLogDirty = true;
}

function handleMessage(message) {
  if (message.type === "bridge.hello") {
    bridgeStatus = message.status;
    bridgeState = "연결됨";
    reconnectDelay = 250;
    recordEvent("Bridge Connected", `protocol ${message.protocolVersion}`);
  } else {
    eventCount += 1;
    if (lastSequence && message.sequence > lastSequence + 1) sequenceGaps += message.sequence - lastSequence - 1;
    if (Number.isFinite(message.sequence)) lastSequence = Math.max(lastSequence, message.sequence);
    if (message.type === "touch.frame" && message.touch) handleTouchFrame(message);
    else if (message.type === "pen.packet" && message.pen) handlePenPacket(message);
    else if (message.type === "pen.proximity" && message.proximity) handleProximity(message);
  }
  emptyState.classList.toggle("hidden", eventCount > 0);
  canvasDirty = true;
  panelDirty = true;
  requestRender();
}

function connectBridge() {
  window.clearTimeout(reconnectTimer);
  bridgeState = "연결 중";
  panelDirty = true;
  requestRender();
  socket = new WebSocket(bridgeEndpoints.webSocket);
  socket.addEventListener("open", () => reportClientActivity(true));
  socket.addEventListener("message", event => {
    try { handleMessage(JSON.parse(event.data)); }
    catch (error) { recordEvent("Data Error", error.message); }
  });
  socket.addEventListener("close", () => {
    bridgeState = "연결 끊김 · 재시도 중";
    socket = null;
    clientActive = null;
    panelDirty = true;
    requestRender();
    reconnectTimer = window.setTimeout(connectBridge, reconnectDelay);
    reconnectDelay = Math.min(RECONNECT_MAX_MS, reconnectDelay * 2);
  });
  socket.addEventListener("error", () => socket?.close());
}

function reportClientActivity(force = false) {
  const active = document.visibilityState === "visible" && document.hasFocus();
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  if (!force && active === clientActive) return;

  clientActive = active;
  clientActivityGeneration += 1;
  socket.send(JSON.stringify({
    type: active ? "bridge.activate" : "bridge.deactivate",
    generation: clientActivityGeneration
  }));
}

async function refreshBridgeStatus() {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  try {
    const response = await fetch(`${bridgeEndpoints.http}/api/status`, { cache: "no-store" });
    if (!response.ok) return;
    bridgeStatus = await response.json();
    panelDirty = true;
    requestRender();
  } catch (_) {
    // The WebSocket reconnect path owns connection error reporting.
  }
}

function buttonLabel(input) {
  if (!input.buttons) return "없음";
  if (input.type === "pen") {
    const labels = [];
    if (input.buttons & 1) labels.push("펜촉");
    for (let button = 1; button < 31; button += 1) {
      if ((input.buttons & (2 ** button)) !== 0) labels.push(`버튼${button}`);
    }
    return labels.join("+") || `비트 ${input.buttons}`;
  }
  const labels = [];
  if (input.buttons & 1) labels.push(input.type === "mouse" ? "왼쪽" : "접촉");
  if (input.buttons & 2) labels.push(input.type === "mouse" ? "오른쪽" : "버튼2");
  if (input.buttons & 4) labels.push(input.type === "mouse" ? "가운데" : "버튼3");
  if (input.buttons & 8) labels.push("뒤로");
  if (input.buttons & 16) labels.push("앞으로");
  return labels.join("+") || `비트 ${input.buttons}`;
}

function fmt(value, digits = 0) {
  return Number.isFinite(value) ? Number(value).toFixed(digits) : "—";
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[char]);
}

function updatePanels(forceLog = false) {
  const values = [...inputs.values()].sort((a, b) => a.type.localeCompare(b.type) || a.id - b.id);
  const activeTouches = values.filter(input => input.type === "touch" && input.down).length;
  pointerCountElement.textContent = values.filter(input => input.down || input.hover).length;
  touchCountElement.textContent = activeTouches;
  maxTouchCountElement.textContent = maxTouchCount;
  eventCountElement.textContent = eventCount.toLocaleString("ko-KR");

  const native = bridgeStatus?.native;
  const platform = native?.platform === "macos" ? "macOS" : native ? "Windows" : "—";
  const nativeCounters = native
    ? ` · frames ${native.touchFrames || 0} · packets ${native.penPackets || 0}`
    : "";
  const platformDiagnostics = native?.platform === "macos"
    ? ` · dedupe ${native.deduplicatedPenEvents || 0}`
    : native
      ? ` · overlap ${native.wintabOverlapMessages || 0} · promote ${native.wintabPromotionSuccesses || 0}/${native.wintabPromotionAttempts || 0}`
      : "";
  supportStatusElement.innerHTML = `<span class="${bridgeState === "연결됨" ? "ok" : "warn"}">● ${bridgeState}</span>`
    + (native ? ` · ${platform} · Touch ${native.touchReady ? "OK" : "실패"} · Pen ${native.penReady ? "OK" : "실패"}` : "")
    + nativeCounters
    + platformDiagnostics
    + (native ? ` · active ${native.activeBrowserClients || 0}` : "")
    + ` · seq ${lastSequence || "—"} · 누락 ${sequenceGaps}`;

  pointerList.innerHTML = values.length ? values.map(input => {
    const deviceData = input.type === "touch"
      ? `<div class="datum"><span>접촉 크기(raw)</span><b>${fmt(input.rawWidth, 2)} × ${fmt(input.rawHeight, 2)}</b></div>
         <div class="datum"><span>감도 / 방향</span><b>${input.sensitivity} / ${fmt(input.orientation, 1)}°</b></div>
         <div class="datum"><span>신뢰도</span><b>${input.confidence}</b></div>`
      : input.type === "pen"
      ? `<div class="datum"><span>압력(raw / normalized)</span><b>${input.rawPressure} / ${fmt(input.pressure, 3)}</b></div>
         <div class="datum"><span>${input.hasCommonTilt ? "Tilt X / Y" : "고도 / 방위"}</span><b>${input.hasCommonTilt ? `${fmt(input.tiltX, 3)} / ${fmt(input.tiltY, 3)}` : `${fmt(input.altitude, 1)}° / ${fmt(input.azimuth, 1)}°`}</b></div>
         <div class="datum"><span>Rotation / Z</span><b>${fmt(input.rotation, 1)}° / ${input.z}</b></div>
         <div class="datum"><span>장치 / Unique ID</span><b>${escapeHtml(input.deviceType)} / ${input.uniqueId || "—"}</b></div>`
      : `<div class="datum"><span>화면 좌표</span><b>${fmt(input.rawX)} / ${fmt(input.rawY)}</b></div>
         <div class="datum"><span>버튼</span><b>${escapeHtml(buttonLabel(input))} (${input.buttons})</b></div>`;
    return `<article class="pointer-card" style="--pointer-color:${inputColor(input)}">
      <div class="pointer-head"><strong>${inputLabel(input.type)} #${input.id}</strong><span class="badge">${input.hover ? "HOVER" : input.down ? "DOWN" : "UP"}</span></div>
      <div class="data-grid">
        <div class="datum"><span>원시 좌표 X / Y</span><b>${fmt(input.rawX, 2)} / ${fmt(input.rawY, 2)}</b></div>
        <div class="datum"><span>표시 좌표 X / Y</span><b>${fmt(input.x)} / ${fmt(input.y)}</b></div>
        <div class="datum"><span>상태 / 버튼</span><b>${escapeHtml(input.state || buttonLabel(input))}</b></div>
        ${deviceData}
        ${input.type === "pen" ? `<div class="datum pressure"><span>압력 ${fmt(input.pressure, 3)} · ${escapeHtml(buttonLabel(input))}${input.inverted ? " · 지우개" : ""}</span><div class="meter"><i style="--value:${input.pressure * 100}%"></i></div></div>` : ""}
      </div>
    </article>`;
  }).join("") : '<p class="no-pointers">감지된 입력이 없습니다.</p>';

  if (eventLogDirty || forceLog) {
    eventLog.innerHTML = recentEvents.map(item => {
      const count = item.count > 1 ? ` ×${item.count}` : "";
      const detail = item.detail ? `${escapeHtml(item.detail)} · ` : "";
      return `<li><b>${escapeHtml(item.type)}${count}</b><span>${detail}${item.time}</span></li>`;
    }).join("");
    eventLogDirty = false;
  }
}

function drawCanvas() {
  const width = canvas.width / dpr;
  const height = canvas.height / dpr;
  ctx.clearRect(0, 0, width, height);
  for (const input of inputs.values()) {
    const color = inputColor(input);
    if (input.trail.length > 1) {
      ctx.beginPath();
      input.trail.forEach((point, index) => index ? ctx.lineTo(point.x, point.y) : ctx.moveTo(point.x, point.y));
      ctx.strokeStyle = color;
      ctx.globalAlpha = .3;
      ctx.lineWidth = 2;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }

    const radius = input.type === "touch"
      ? Math.max(12, Math.min(55, Math.max(input.width, input.height) / 2))
      : input.type === "pen" ? 8 + input.pressure * 18 : 7;
    ctx.save();
    ctx.translate(input.x, input.y);
    ctx.strokeStyle = color;
    ctx.fillStyle = color;
    ctx.lineWidth = 2;
    ctx.setLineDash(input.hover ? [5, 4] : []);
    ctx.globalAlpha = input.hover ? .78 : input.down ? .9 : .4;
    ctx.beginPath();
    ctx.arc(0, 0, radius, 0, Math.PI * 2);
    input.down ? ctx.fill() : ctx.stroke();

    if (input.type === "pen") {
      ctx.globalAlpha = 1;
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.moveTo(0, 0);
      if (input.hasCommonTilt) {
        // AppKit tiltY increases upward, while Canvas Y increases downward.
        ctx.lineTo(
          input.tiltX * PEN_TILT_INDICATOR_LENGTH,
          -input.tiltY * PEN_TILT_INDICATOR_LENGTH
        );
      } else {
        const tilt = clamp01((90 - input.altitude) / 90);
        const radians = input.azimuth * Math.PI / 180;
        ctx.lineTo(
          Math.sin(radians) * PEN_TILT_INDICATOR_LENGTH * tilt,
          -Math.cos(radians) * PEN_TILT_INDICATOR_LENGTH * tilt
        );
      }
      ctx.stroke();
    }

    ctx.globalAlpha = 1;
    ctx.setLineDash([]);
    ctx.fillStyle = "#f2f4f8";
    ctx.font = "11px Consolas";
    ctx.fillText(`${inputLabel(input.type)} #${input.id}${input.hover ? " HOVER" : ""}`, radius + 7, -4);
    ctx.restore();
  }
}

function requestRender() {
  if (!animationFrame) animationFrame = requestAnimationFrame(renderFrame);
}

function renderFrame(now) {
  animationFrame = 0;
  if (canvasDirty) { drawCanvas(); canvasDirty = false; }
  if (panelDirty && now - lastPanelUpdate >= PANEL_INTERVAL) {
    updatePanels(); panelDirty = false; lastPanelUpdate = now;
  }
  if (panelDirty && !panelTimer) {
    panelTimer = window.setTimeout(() => { panelTimer = 0; requestRender(); }, Math.max(0, PANEL_INTERVAL - (now - lastPanelUpdate)));
  }
}

function clearAll() {
  inputs.clear();
  recentEvents.length = 0;
  eventCount = 0;
  maxTouchCount = 0;
  lastSequence = 0;
  sequenceGaps = 0;
  emptyState.classList.remove("hidden");
  canvasDirty = true;
  panelDirty = false;
  eventLogDirty = true;
  updatePanels(true);
  requestRender();
}

document.querySelector("#clearButton").addEventListener("click", clearAll);
document.querySelector("#fullscreenButton").addEventListener("click", () => document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen());
document.addEventListener("keydown", event => {
  if (event.key.toLowerCase() === "c") clearAll();
  if (event.key.toLowerCase() === "f") document.querySelector("#fullscreenButton").click();
});
window.addEventListener("resize", resizeCanvas);
window.addEventListener("focus", reportClientActivity);
window.addEventListener("blur", reportClientActivity);
document.addEventListener("visibilitychange", reportClientActivity);
inputArea.addEventListener("contextmenu", event => event.preventDefault());
["pointerenter", "pointermove", "pointerdown", "pointerup", "pointerleave", "pointercancel"].forEach(type => {
  inputArea.addEventListener(type, handleMousePointer, { passive: true });
});
new ResizeObserver(resizeCanvas).observe(inputArea);
updatePanels(true);
resizeCanvas();
connectBridge();
window.setInterval(refreshBridgeStatus, 1000);
