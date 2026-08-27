# Security

## Status

The visual demo is suitable for local development. The direct Codex Remote
transport is experimental reference code and must not be represented as a
supported or generally available third-party integration.

## Trust boundary

A controller attached to a Codex task can reach the tools, files, connectors
and credentials that task is allowed to use. Treat controller compromise as
remote access to that task and, with permissive sandbox or approval settings,
potentially to the host account.

The design therefore keeps credentials and task identity in native Swift. The
bundled WebView receives only a WebRTC answer, media events and bounded face
state. It receives no OAuth token, controller token, environment ID, task ID,
raw App Server method name, shell field or approval response.

## Implemented safeguards

- non-exportable Secure Enclave P-256 device key;
- Face ID required for a foreground control session;
- device-only Keychain accessibility for token and pairing records;
- PKCE and state validation for the experimental browser sign-in;
- exact manual pairing code submission, once;
- explicit selection and revalidation of one paired environment;
- short-lived controller session token held in memory;
- TLS/WSS for the experimental relay;
- no automatic retry after an uncertain pairing, start or stop mutation;
- bounded WebSocket frames, SDP, prompts, chunks and session duration;
- no arbitrary App Server method or approval route from the WebView;
- background lifecycle checks and explicit session teardown.

## Known limitations

- The direct relay endpoints, scopes, model name and attestation exchange are
  not documented public interfaces and may change or reject third-party apps.
- The repository intentionally ships with no OAuth client ID. Reusing a
  first-party application identifier is not an acceptable workaround.
- The public Codex App Server WebSocket transport is itself documented as
  experimental and unsupported for production workloads.
- A selected Codex task may still perform powerful actions according to its
  own configuration. Use a least-privilege task, sandbox and approval policy.
- Compromise of the iPhone, Mac, OpenAI account or upstream service remains
  outside this app's protection boundary.

## Reporting a vulnerability

Until a maintainer publishes a private security contact, do not put exploit
details in a public issue. Use GitHub's private vulnerability-reporting or
Security Advisory feature if it is enabled for the repository. A public fork
should replace this paragraph with a maintained response address and policy.

## Release rule

Never publish generated Xcode projects, `xcuserdata`, provisioning profiles,
certificates, archives, account tokens, device IDs, host names, local URLs or
private repository history. Run `make audit`, inspect the complete staged diff,
and perform an independent second review before adding a remote or pushing.
