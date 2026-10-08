# Working in Quills

Quills is a macOS menu-bar meeting recorder and local transcriber. It ships as
one Swift Package Manager executable, not an `.app` bundle. Requires macOS 15+
and Swift 6; use the full Xcode toolchain on this machine. Read `README.md` and
the relevant source before changing behavior.

## Repository map

- `Package.swift`: dependencies, executable/test targets, and embedded
  `Sources/quills/Info.plist`. Preserve the `com.indiantinker.quills` bundle identifier and privacy strings.
- `Sources/quills/Quills.swift`: CLI entry point and `@MainActor` `AppController`;
  owns recording, menu actions, transcription status, and MCP lifecycle.
- `Sources/quills/UI/`: AppKit menu/status icon and global recording shortcut
  (Control–Option–Command–R).
- `Sources/quills/RecordingSession.swift`: session directory creation, two-track
  capture, start offsets, finalization, and discarding unsuccessful starts.
- `Sources/quills/Audio/`: microphone and Core Audio system capture.
- `Sources/quills/Transcription/`: serial transcription actor, shared Parakeet
  v3 model, transcript serialization, and microphone echo filtering.
- `Sources/quills/AudioRetention.swift`: Storage policies and audio cleanup.
- `Sources/quills/Config.swift`: JSON config and default paths.
- `Sources/quills/MCP/`: loopback HTTP MCP server, filesystem reader, child
  process management, and runtime status.
- `Sources/quills/Install.swift`: LaunchAgent installation/removal.
- `Tests/quillsTests/`: XCTest coverage; use temporary session fixtures.

## Local workflow

1. Check `git status --short` and the relevant diff first. This checkout can
   contain ongoing changes from other work. Preserve them, including unrelated
   untracked files (currently a `~/` directory exists inside the repo).
2. Make focused changes using existing Swift/AppKit conventions. Update the
   README for user-visible behavior or config changes.
3. Run meaningful checks appropriate to the change. Documentation-only changes
   need `git diff --check`; Swift behavior changes normally need the tests and a
   release build. Do not use real meeting audio as test data or start recording
   without task authorization.
4. Report the result, verification, and any remaining limitation. When the user
   asks to update the installed app, carry the work through signing, installation,
   restart, and verification. Documentation-only tasks do not need an app restart.

Build and test from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/private/tmp/quill-clang-module-cache swift test -c debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/private/tmp/quill-clang-module-cache swift build -c release
git diff --check
```

SwiftPM can fail inside the agent sandbox with `sandbox_apply: Operation not
permitted` or cache permission errors. Rerun through the tool's escalation flow;
do not change project settings to work around the sandbox. Keychain access and
local HTTP/process inspection may also require escalation. Dependencies are
already cached in `.build`; avoid unnecessary dependency updates.

## Behavior to preserve

- AppKit and recording lifecycle control run on the main actor. Enter
  `NSApplication.run()` directly on the main thread, as the existing comments
  explain; entering it inside a dispatched main-queue block can freeze tasks.
- Mic and system audio are separate mono AAC tracks in CAF files. Transcript
  speakers are `me` and `them`; timestamps use per-track offsets from `meta.json`.
  Audio callbacks need synchronization. Recovery must preserve captured audio
  and timestamp alignment; voice processing defaults off.
- Session directories use `yyyy.MM.dd-HHmm`, with numeric collision suffixes.
  A successfully stopped session has `meta.json`. Failed starts are discarded.
- Transcription runs serially and resumes from the filesystem at launch.
  Preserve `.quill-on-stop-fired` and `.quill-transcription-failed` semantics.
  `on_stop` fires after transcription, or after recording when transcription is
  disabled. Partial track failures can still yield a useful transcript.
- `transcript.json` is canonical; `transcript.md` is the readable companion.
  Keep schema compatibility and atomic writes. Model loading/transcription can
  happen while a subsequent recording is active.
- Storage defaults to `keep_all`. Other config values are
  `delete_after_transcription` and `keep_last`. Cleanup requires
  `.quill-audio-transcribed` plus both transcript files; the marker is published
  only when every track transcribed successfully. Delete only `mic.caf` and
  `system.caf`, preserving transcripts, metadata, logs, pending/failed/partial
  sessions, and pre-update recordings. `keep_last` keeps both tracks of the
  newest eligible session, using numeric ordering for collision suffixes.
- Config is `~/.config/quill/config.json`. Recording root precedence is
  `--out` > `recordings_dir` > `~/Recordings`. Preserve unrelated config keys
  when saving preferences; do not overwrite malformed JSON.
- MCP is read-only and loopback-only, defaulting to `127.0.0.1:47777/mcp`.
  Preserve traversal/symlink protections and independent client sessions.
  Normal app shutdown stops the MCP child; the child also watches its parent.

## Updating the installed app

The local installation is `/usr/local/bin/quills`, managed by the LaunchAgent
`~/Library/LaunchAgents/com.indiantinker.quills.plist`. Label and signing identifier:
`com.indiantinker.quills`. Logs are `/tmp/quills.out.log` and `/tmp/quills.err.log`.
Runtime status remains `~/Library/Application Support/Quill/status.json` and
config remains `~/.config/quill/config.json` for compatibility. Session markers
and the MCP status JSON `quill` field also remain compatible; MCP advertises
`quills://` resources and accepts legacy `quill://` resources.

The old Quill installation used `/usr/local/bin/quill` and
`com.digimata.quill`. Migration must stop and remove the old LaunchAgent before
starting the new one. The user authorized the new identity; this migration
requires fresh macOS recording permission grants even with the same certificate.

Before restarting, check the runtime status and logs for active recording or
transcription. Do not interrupt a live meeting. Build and validate first, then
inspect the installed signing requirement and available identities:

```sh
codesign -d -r- /usr/local/bin/quills
security find-identity -v -p codesigning
```

Use the same real signing identity and `com.indiantinker.quills` identifier for updates.
Ad-hoc signing changes its identity and can lose macOS microphone/system-audio
permission grants. Do not hard-code a certificate fingerprint into automation.

```sh
codesign --force --sign "<existing signing identity>" --identifier com.indiantinker.quills .build/release/quills
codesign --verify --strict .build/release/quills
```

Keep a copy of the previous installed binary in a temporary directory before
replacement. `/usr/local/bin/quills` is root-owned: use the tool's required
escalation and administrator authentication. If `sudo -n` reports that a
password is required, use macOS's administrator prompt via
`osascript ... with administrator privileges`; never request the password in
chat or put it into a command. Prepare the tested, signed binary before asking
for installation privileges.

With administrator access ready, stop the agent, install the signed binary, and
bootstrap it again:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.indiantinker.quills.plist"
sudo install -m 755 .build/release/quills /usr/local/bin/quills
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.indiantinker.quills.plist"
```

If the replacement inherits `com.apple.provenance` and macOS refuses to launch
it, inspect extended attributes and remove that attribute with administrator
access. Prefer graceful bootout/bootstrap over `kickstart -k`: forcibly killing
the parent can briefly leave its MCP child holding the port.

Verify the installed binary matches the release artifact (`shasum -a 256`),
its signature verifies, the LaunchAgent is running, and fresh logs show both
`quills up` and `quills MCP up`. Check the configured MCP endpoint when needed;
there is no `/health` route, so a 404 there is not a health check. For a port
conflict, inspect the listener and confirm ownership before terminating anything.
Do not leave Quill stopped or MCP broken after an update.
