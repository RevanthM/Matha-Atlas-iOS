# Third-party notices

Matha Atlas includes or resolves the following third-party components. Each component remains under its own license; the Matha Atlas Source Available License does not replace those notices.

## Google LiteRT-LM Swift wrapper

- Location: `Vendor/LiteRTLM`
- Copyright: Copyright 2026 Google LLC
- License: Apache License 2.0
- Upstream: <https://github.com/google-ai-edge/LiteRT-LM>
- Version represented by the local package: `v0.15.0`

The vendored files retain their original copyright and Apache-2.0 headers. The corresponding license is included at `Vendor/LiteRTLM/LICENSE`.

The `CLiteRTLM.xcframework` binary is not committed to this repository. Swift Package Manager downloads it from the official Google GitHub release URL declared in `Vendor/LiteRTLM/Package.swift` and verifies the declared checksum.

## Model Context Protocol Swift SDK

- Dependency: `modelcontextprotocol/swift-sdk`
- Upstream: <https://github.com/modelcontextprotocol/swift-sdk>
- Resolved through Swift Package Manager
- License: the upstream repository describes a transition covering Apache-2.0 and MIT-licensed contributions; consult the license at the resolved version.

Its transitive Swift dependencies are resolved by Swift Package Manager and retain their upstream licenses.

## Cloudflare Workers tooling

The Dispatch relay development dependencies are declared in `DispatchSystem/RelayService/package.json`, resolved through npm, and not vendored in this repository. Each package retains the license declared by its publisher.

## Gemma model weights

No Gemma weights are included in this repository. Any downloaded or imported model is governed by the terms published with that model, independently of Matha Atlas source code.

## Apple SDKs

Apple frameworks, SDKs, Xcode components, signing materials, and provisioning profiles are not redistributed in this repository. They are supplied by the developer's local Xcode installation and Apple developer account.
