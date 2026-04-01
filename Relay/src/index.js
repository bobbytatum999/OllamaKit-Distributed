import {
  buildRegistrationResponse,
  headersToObject,
  jsonResponse,
  normalizeRelayPath,
  readBodyBase64,
  uint8ArrayFromBase64
} from "./helpers.js";

const REQUEST_TIMEOUT_MS = 30_000;

export class DeviceRelayRoom {
  constructor(state) {
    this.state = state;
    this.deviceSocket = null;
    this.pending = new Map();
  }

  async fetch(request) {
    const url = new URL(request.url);

    switch (url.pathname) {
      case "/register":
        return this.handleRegister(request);
      case "/connect":
        return this.handleConnect(request);
      case "/proxy":
        return this.handleProxy(request);
      default:
        return new Response("Not found", { status: 404 });
    }
  }

  async handleRegister(request) {
    const payload = await request.json();
    const deviceID = String(payload.device_id || crypto.randomUUID()).trim();
    const relayToken = crypto.randomUUID().replace(/-/g, "");

    await this.state.storage.put("registration", {
      deviceID,
      relayToken,
      buildVariant: payload.build_variant || "stockSideload"
    });

    return jsonResponse({ ok: true, deviceID, relayToken });
  }

  async handleConnect(request) {
    const url = new URL(request.url);
    const deviceID = url.searchParams.get("device_id") || "";
    const relayToken = url.searchParams.get("token") || "";
    const registration = await this.state.storage.get("registration");

    if (!registration || registration.deviceID !== deviceID || registration.relayToken !== relayToken) {
      return new Response("Unauthorized", { status: 401 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();

    this.deviceSocket = server;
    server.addEventListener("message", event => {
      this.handleSocketMessage(event.data).catch(error => {
        console.error("relay socket message failed", error);
      });
    });
    server.addEventListener("close", () => {
      this.deviceSocket = null;
      this.failAllPending("Device tunnel closed.");
    });
    server.addEventListener("error", () => {
      this.deviceSocket = null;
      this.failAllPending("Device tunnel errored.");
    });

    server.send(JSON.stringify({ type: "relay_ready", message: "Managed relay socket ready." }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async handleProxy(request) {
    if (!this.deviceSocket) {
      return jsonResponse({ error: "The device tunnel is offline." }, 503);
    }

    const url = new URL(request.url);
    const relayPath = url.searchParams.get("path") || "/";
    const requestID = crypto.randomUUID();
    const stream = new TransformStream();
    const writer = stream.writable.getWriter();

    const start = {};
    start.promise = new Promise((resolve, reject) => {
      start.resolve = resolve;
      start.reject = reject;
    });

    const timeout = setTimeout(() => {
      start.reject(new Error("Timed out waiting for the device to begin responding."));
      this.pending.delete(requestID);
      writer.abort("Timed out waiting for the device.");
    }, REQUEST_TIMEOUT_MS);

    this.pending.set(requestID, {
      writer,
      start,
      timeout
    });

    const bodyBase64 = ["GET", "HEAD"].includes(request.method.toUpperCase())
      ? ""
      : await readBodyBase64(request);

    this.deviceSocket.send(JSON.stringify({
      type: "proxy_request",
      request_id: requestID,
      method: request.method,
      path: relayPath,
      headers: headersToObject(request.headers),
      body_base64: bodyBase64
    }));

    let started;
    try {
      started = await start.promise;
    } catch (error) {
      clearTimeout(timeout);
      return jsonResponse({ error: error.message }, 504);
    }

    return new Response(stream.readable, {
      status: started.status,
      headers: started.headers
    });
  }

  async handleSocketMessage(rawData) {
    const payload = typeof rawData === "string" ? JSON.parse(rawData) : JSON.parse(new TextDecoder().decode(rawData));
    const requestID = payload.request_id;
    const pending = requestID ? this.pending.get(requestID) : null;

    switch (payload.type) {
      case "pong":
      case "device_ready":
        return;
      case "response_start":
        if (!pending) return;
        pending.start.resolve({
          status: Number(payload.status || 200),
          headers: payload.headers || {}
        });
        return;
      case "response_chunk":
        if (!pending) return;
        if (payload.chunk_base64) {
          await pending.writer.write(uint8ArrayFromBase64(payload.chunk_base64));
        }
        return;
      case "response_end":
        if (!pending) return;
        clearTimeout(pending.timeout);
        await pending.writer.close();
        this.pending.delete(requestID);
        return;
      case "response_error":
        if (!pending) return;
        clearTimeout(pending.timeout);
        pending.start.reject(new Error(payload.message || "Device request failed."));
        await pending.writer.abort(payload.message || "Device request failed.");
        this.pending.delete(requestID);
        return;
      default:
        return;
    }
  }

  failAllPending(message) {
    for (const [requestID, pending] of this.pending.entries()) {
      clearTimeout(pending.timeout);
      pending.start.reject(new Error(message));
      pending.writer.abort(message);
      this.pending.delete(requestID);
    }
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/api/device/register") {
      const payload = await request.clone().json();
      const durableID = env.DEVICE_RELAY_ROOM.idFromName(String(payload.device_id || crypto.randomUUID()));
      const stub = env.DEVICE_RELAY_ROOM.get(durableID);
      const registerResponse = await stub.fetch(new Request("https://relay.internal/register", request));
      const registerPayload = await registerResponse.json();

      if (!registerResponse.ok) {
        return jsonResponse(registerPayload, registerResponse.status);
      }

      return jsonResponse(buildRegistrationResponse(url.origin, registerPayload.deviceID, registerPayload.relayToken));
    }

    if (url.pathname === "/api/device/connect") {
      const deviceID = url.searchParams.get("device_id") || "";
      const durableID = env.DEVICE_RELAY_ROOM.idFromName(deviceID);
      const stub = env.DEVICE_RELAY_ROOM.get(durableID);
      return stub.fetch("https://relay.internal/connect" + url.search);
    }

    if (url.pathname.startsWith("/relay/")) {
      let relayInfo;
      try {
        relayInfo = normalizeRelayPath(url.pathname, url.search);
      } catch (error) {
        return jsonResponse({ error: error.message }, 400);
      }

      const durableID = env.DEVICE_RELAY_ROOM.idFromName(relayInfo.deviceID);
      const stub = env.DEVICE_RELAY_ROOM.get(durableID);
      const proxyURL = new URL("https://relay.internal/proxy");
      proxyURL.searchParams.set("path", relayInfo.path);
      return stub.fetch(new Request(proxyURL.toString(), request));
    }

    return jsonResponse({
      ok: true,
      service: "ollamakit-managed-relay"
    });
  }
};
