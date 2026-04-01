import test from "node:test";
import assert from "node:assert/strict";
import {
  buildRegistrationResponse,
  headersToObject,
  normalizeRelayPath
} from "../src/helpers.js";

test("buildRegistrationResponse derives public and websocket URLs", () => {
  const result = buildRegistrationResponse("https://relay.example.com", "device-1", "token-1");

  assert.equal(result.deviceID, "device-1");
  assert.equal(result.relayToken, "token-1");
  assert.equal(result.publicURL, "https://relay.example.com/relay/device-1");
  assert.equal(result.websocketURL, "wss://relay.example.com/api/device/connect");
});

test("normalizeRelayPath extracts device and request path", () => {
  const result = normalizeRelayPath("/relay/device-1/v1/chat/completions", "?stream=true");

  assert.equal(result.deviceID, "device-1");
  assert.equal(result.path, "/v1/chat/completions?stream=true");
});

test("headersToObject strips proxy transport headers", () => {
  const headers = new Headers({
    authorization: "Bearer test",
    "cf-connecting-ip": "1.2.3.4",
    "x-real-ip": "1.2.3.4",
    "content-type": "application/json"
  });

  const result = headersToObject(headers);
  assert.equal(result.authorization, "Bearer test");
  assert.equal(result["content-type"], "application/json");
  assert.equal("cf-connecting-ip" in result, false);
  assert.equal("x-real-ip" in result, false);
});
