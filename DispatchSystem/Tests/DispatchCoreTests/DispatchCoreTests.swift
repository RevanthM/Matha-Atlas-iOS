import DispatchCore
import Foundation
import Testing

@Test func policyScopesAutomaticExecutionToApprovedWorkspace() {
    let policy = ExecutionPolicy(approvedWorkspaceRoots: ["/tmp/approved"])
    let request = OperationRequest(
        kind: .xcodeBuild,
        workspacePath: "/tmp/approved/project",
        executable: "/usr/bin/xcrun",
        summary: "Build application"
    )
    #expect(ExecutionPolicyEngine().evaluate(request, against: policy) == .allow)
}

@Test func policyDeniesWorkspaceEscape() {
    let policy = ExecutionPolicy(approvedWorkspaceRoots: ["/tmp/approved"])
    let request = OperationRequest(
        kind: .writeWorkspace,
        workspacePath: "/tmp/approved-neighbor",
        summary: "Write outside workspace"
    )
    let decision = ExecutionPolicyEngine().evaluate(request, against: policy)
    guard case .deny = decision else {
        Issue.record("Expected workspace escape to be denied")
        return
    }
}

@Test func unapprovedDeviceRequiresApproval() {
    let policy = ExecutionPolicy(approvedWorkspaceRoots: ["/tmp/project"])
    let request = OperationRequest(
        kind: .installSignedApp,
        workspacePath: "/tmp/project",
        executable: "/usr/bin/xcrun",
        deviceID: "device-1",
        summary: "Install application"
    )
    let decision = ExecutionPolicyEngine().evaluate(request, against: policy)
    guard case .requireApproval = decision else {
        Issue.record("Expected an unapproved device to require approval")
        return
    }
}

@Test func recursiveTaskGraphHonorsDepthLimit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try TaskGraphStore(fileURL: directory.appendingPathComponent("graph.json"))
    let root = try await store.createRoot(title: "Root", prompt: "Coordinate")
    let first = try await store.createChild(
        parentID: root.id,
        title: "Child",
        prompt: "Work",
        kind: .code,
        limits: DispatchLimits(maximumDepth: 1)
    )

    await #expect(throws: TaskGraphError.maximumDepthReached) {
        try await store.createChild(
            parentID: first.id,
            title: "Too deep",
            prompt: "Should fail",
            kind: .code,
            limits: DispatchLimits(maximumDepth: 1)
        )
    }
}

@Test func relayEnvelopeRoundTrips() throws {
    let task = DispatchTask(title: "Build", prompt: "Build the app", kind: .code)
    let envelope = RelayEnvelope(payload: .submit(task))
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(RelayEnvelope.self, from: data)
    #expect(decoded == envelope)
}
