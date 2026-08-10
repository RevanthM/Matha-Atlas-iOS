# Matha Atlas Dispatch Architecture

## Requirements

### Functional

1. Submit a high-level mission from iPhone or Mac.
2. Represent recursively created child tasks and their dependencies.
3. Route approved desktop, repository, and Apple/Xcode work to the paired Mac.
4. Show live status, output, artifacts, failures, and approvals on iPhone.
5. Pause, resume, cancel, and redirect work remotely.
6. Build, install, launch, and inspect a signed app on an approved connected iPhone.
7. Queue iPhone submissions during temporary network loss and send them when the client reconnects.

### Non-functional

- Local-first history on iPhone and Mac.
- Best-effort relay delivery with bounded reconnect backoff.
- No inbound port on the Mac.
- Explicit workspace and device boundaries.
- Locally retained task events for consequential state transitions.
- Recursive-task limits to prevent runaway fan-out.
- Eventual consistency during temporary network loss.

### Physical constraints

- Xcode and CoreDevice tasks require an awake, online Mac.
- Cloud workers cannot access unsynchronized local files or USB devices.
- A signed iOS app cannot reinstall itself; the paired Mac performs installation and relaunch.

## Components

```text
Matha Atlas iOS
  DispatchUI
    Dispatch composer
    Agent View
    Remote Control / approvals
         |
         | WSS + paired-device identity
         v
Relay Service
  authenticated WebSocket room
       |
       v
Mac Companion
  policy engine
  task executor
  Xcode/CoreDevice
```

## Data flow

1. The iPhone writes a root `DispatchTask` locally and wraps it in a versioned `RelayEnvelope`.
2. If disconnected, the client holds the envelope in its outbound queue. On reconnection it sends the queued message.
3. The relay forwards the live envelope to other connected peers in the authenticated room.
4. Coordinators can create children until `DispatchLimits` is reached.
5. The desktop agent accepts only typed operations. `ExecutionPolicyEngine` checks workspace, executable, operation class, and CoreDevice identifier.
6. Output arrives as `DispatchEvent` records. The iPhone merges them into its local snapshot.
7. A task needing a consequential action enters `awaitingApproval`. The approval is retained by the running desktop agent until it is resolved or the agent process exits.

## Storage

| Layer | Storage | Purpose |
|---|---|---|
| iPhone | Application Support JSON; in-process relay queue | Tasks and events persist; unsent relay envelopes do not survive process termination |
| Mac | Atomic JSON snapshots initially; SQLite in the next migration | Host configuration, task graph, audit events |
| Relay | Durable Object sockets | Live room membership and message forwarding |
| Secrets | iOS/macOS Keychain and relay secret store | Pairing and refresh credentials |

JSON is being used for the first slice because the schema is small and inspectable. Before high-volume terminal streaming, events should move to SQLite with indexed `(taskID, sequence)` storage.

## Protocol

`RelayEnvelope` contains:

- protocol version
- globally unique message identifier
- send timestamp
- typed payload

Implemented payloads include host hello/heartbeat, task submission, snapshots, events, approval requests/responses, and pause/resume/cancel commands.

Live delivery is best effort. The iPhone retains unsent envelopes while its process remains alive and reconnects with bounded backoff. A later schema will persist relay envelopes, add acknowledgements, and restore unsent client queues after process termination.

## Execution policy

Automatic operations can be granted for an exact workspace and exact CoreDevice identifier. Path validation resolves symlinks and checks path components, preventing `/approved-neighbor` from passing a naive `/approved` prefix test.

The following always require an explicit decision:

- destructive operations
- external messages
- secret access
- unknown executables
- deployment to an unapproved device
- access outside approved workspace roots

Approvals do not expire merely because the user did not answer quickly. They remain pending while the desktop agent process is running. Restarting that process discards pending executions. A user can pre-authorize a narrow operation category for one workspace/device.

## Scale and reliability

The initial target is one user, up to four hosts, 30 tasks per mission, six active children per root, and 10,000 retained local events. WebSocket reconnect uses an in-process outbound queue. Task state transitions are validated so late events cannot silently resurrect terminal work.

For larger deployments:

- move events to an ordered append-only stream;
- persist acknowledgement cursors per client;
- store terminal output as compressed artifacts rather than unbounded events;
- isolate every cloud job in an ephemeral VM/container;
- introduce per-user relay rooms rather than a shared pairing secret;
- add tracing for route, queue, execution, and approval latency.

## Trade-offs

- **Typed operations vs. arbitrary shell:** typed operations require more adapters but are auditable and can be narrowly pre-approved.
- **Outbound relay vs. direct LAN connection:** relay adds infrastructure cost but works across networks without exposing the Mac.
- **Future cloud fallback vs. local-only:** cloud fallback could enable offline progress but is not implemented and could not use local secrets, Xcode, or physical devices without additional synchronization and isolation.
- **Recursive agents vs. fixed children:** recursion improves decomposition but requires depth, concurrency, runtime, and cost ceilings.
- **JSON first vs. SQLite immediately:** JSON accelerates the first vertical slice; SQLite is necessary before sustained streaming.

## Revisit as the system grows

1. Replace JSON event storage with SQLite.
2. Add end-to-end payload encryption so the relay cannot inspect mission content.
3. Use hardware-backed pairing keys and remote attestation where supported.
4. Add idempotency keys to typed build/install/launch actions.
5. Add cloud-worker scheduling and Git-based workspace synchronization.
6. Add wake-on-LAN as a best-effort optimization, never as a correctness dependency.
