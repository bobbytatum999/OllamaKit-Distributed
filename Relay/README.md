# OllamaKit Managed Relay

This Worker provides the managed public endpoint for `ServerExposureMode.publicManaged`.

## What it does

- Registers iPhone/iPad devices and returns:
  - a durable `deviceID`
  - a relay auth token
  - an assigned public URL
  - a WebSocket endpoint for the device tunnel
- Keeps a WebSocket open from the device to a Durable Object room.
- Forwards inbound public HTTP requests to the device over that socket.
- Streams the device response back to the public client with `response_start`, `response_chunk`, and `response_end` envelopes.

## Local commands

```bash
npm --prefix Relay test
```

## Deploy

```bash
cd Relay
npx wrangler deploy
```

Set the deployed Worker URL in OllamaKit’s `Managed Relay Service URL` field in the Server tab.
