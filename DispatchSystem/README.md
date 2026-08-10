# Matha Atlas Dispatch

Matha Atlas Dispatch adds a native iOS task coordinator, Agent View, Remote Control, authenticated WebSocket relay, and a policy-scoped macOS executor to the on-device app.

The repository root [README](../README.md) contains the complete setup walkthrough. This file is the component-level reference.

## Components

- `DispatchCore`: versioned task, event, approval, host, execution-policy, and relay-envelope models.
- `DispatchUI`: SwiftUI Dispatch, Agent View, task detail, child delegation, approvals, pairing, retry, offline outbound queue, and local history.
- `local-gemma-agent`: macOS executable for approved Codex, Xcode, CoreDevice install, and app launch operations.
- `RelayService`: authenticated Cloudflare Worker/Durable Object WebSocket relay.
- `Tests`: protocol, recursion-limit, workspace-boundary, and device-approval tests.

## Build and test

```sh
swift test
swift build -c release
.build/release/local-gemma-agent doctor
```

## Configure the host

```sh
.build/release/local-gemma-agent approve-workspace /absolute/path/to/workspace
.build/release/local-gemma-agent devices
.build/release/local-gemma-agent approve-device CORE_DEVICE_IDENTIFIER
.build/release/local-gemma-agent set-relay \
  ws://127.0.0.1:8787/v1/rooms/matha-atlas-dev/connect
```

Non-secret host configuration is stored in:

```text
~/Library/Application Support/LocalGemmaDispatch/AgentConfiguration.json
```

The pairing secret is read from macOS Keychain service `com.matha.atlas.DispatchRelay`, account `local-development`. It must never be added to the JSON configuration or committed to the repository.

## Start the local stack

```sh
cd RelayService
npm ci
npm run typecheck
cd ..
swift build -c release
./scripts/run-dispatch-host.zsh
```

The host script resolves paths relative to its own location, so a contributor can clone the repository anywhere.

## Execution boundary

- Automatic operations must stay inside an explicitly approved workspace.
- Apple-device actions must target an explicitly approved CoreDevice identifier.
- Symlink-resolved paths are checked before execution.
- Operations outside the configured boundary enter `awaitingApproval` or are denied.
- The iPhone can approve a held operation once or deny it.
- The relay accepts outbound authenticated WebSocket connections; it does not expose an inbound shell on the Mac.

## Current limitations

- The relay broadcasts live messages but does not persist disconnected traffic.
- Pending execution approvals are stored in the running Mac daemon's memory.
- State pause/cancel does not yet forcibly terminate a blocking child process.
- A Mac must remain awake for Xcode, local repository, and attached-device operations.
- The Cloudflare worker uses one configured pairing secret and is intended for a single trusted development environment.

See [ARCHITECTURE.md](ARCHITECTURE.md) for design boundaries and planned reliability work.
