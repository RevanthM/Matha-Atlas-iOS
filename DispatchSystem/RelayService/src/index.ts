export interface Env {
  DISPATCH_ROOMS: DurableObjectNamespace;
  PAIRING_SECRET: string;
}

function unauthorized(): Response {
  return new Response("Unauthorized", { status: 401 });
}

async function validBearer(request: Request, secret: string): Promise<boolean> {
  const supplied = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const encoder = new TextEncoder();
  const [suppliedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(secret)),
  ]);
  const left = new Uint8Array(suppliedHash);
  const right = new Uint8Array(expectedHash);
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index += 1) mismatch |= left[index] ^ right[index];
  return mismatch === 0 && supplied.length > 0;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({ status: "ok", protocolVersion: 1 });
    }
    const match = url.pathname.match(/^\/v1\/rooms\/([a-zA-Z0-9_-]{8,128})\/connect$/);
    if (!match) return new Response("Not found", { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket upgrade required", { status: 426 });
    }
    if (!(await validBearer(request, env.PAIRING_SECRET))) return unauthorized();

    const id = env.DISPATCH_ROOMS.idFromName(match[1]);
    return env.DISPATCH_ROOMS.get(id).fetch(request);
  },
} satisfies ExportedHandler<Env>;

export class DispatchRoom {
  private readonly state: DurableObjectState;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.state.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    for (const peer of this.state.getWebSockets()) {
      if (peer !== socket && peer.readyState === WebSocket.OPEN) peer.send(message);
    }
  }

  async webSocketClose(
    socket: WebSocket,
    code: number,
    reason: string,
    wasClean: boolean,
  ): Promise<void> {
    // The runtime has already closed the peer. Code 1006 is reserved and must
    // never be echoed in a close frame.
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    socket.close(1011, "Relay socket error");
  }
}
