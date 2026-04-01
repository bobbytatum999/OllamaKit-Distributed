export function buildRegistrationResponse(origin, deviceID, relayToken) {
  const normalizedOrigin = origin.replace(/\/+$/, "");
  return {
    deviceID,
    relayToken,
    publicURL: `${normalizedOrigin}/relay/${deviceID}`,
    websocketURL: `${normalizedOrigin.replace(/^http/i, "ws")}/api/device/connect`
  };
}

export function normalizeRelayPath(pathname, search = "") {
  const match = pathname.match(/^\/relay\/([^/]+)(\/.*)?$/);
  if (!match) {
    throw new Error("Invalid relay path");
  }

  return {
    deviceID: decodeURIComponent(match[1]),
    path: `${match[2] || "/"}${search || ""}`
  };
}

export function headersToObject(headers) {
  const result = {};
  for (const [key, value] of headers.entries()) {
    const lowered = key.toLowerCase();
    if (lowered === "cf-connecting-ip" || lowered === "x-forwarded-proto" || lowered === "x-real-ip") {
      continue;
    }
    result[key] = value;
  }
  return result;
}

export async function readBodyBase64(request) {
  const arrayBuffer = await request.arrayBuffer();
  return base64FromArrayBuffer(arrayBuffer);
}

export function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

export function base64FromArrayBuffer(arrayBuffer) {
  const bytes = new Uint8Array(arrayBuffer);
  let binary = "";

  for (let index = 0; index < bytes.length; index += 1) {
    binary += String.fromCharCode(bytes[index]);
  }

  return btoa(binary);
}

export function uint8ArrayFromBase64(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }

  return bytes;
}
