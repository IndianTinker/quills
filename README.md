# Quills

A local macOS meeting recorder and multilingual transcriber, built on
[Quill](https://github.com/digimata/quill) by Andrew Jones. Quills extends the
original project with shared multilingual Parakeet v3 models, model setup and
diagnostics, and a local read-only MCP server for working with meeting transcripts
from tools such as Codex, Claude Code, and OpenCode.

The menu-bar controls record your mic and system audio as separate tracks. When you
stop, Quills transcribes both on-device and writes a speaker-tagged transcript.
Recording and transcription stay on your Mac. Connected MCP clients may send
transcripts to their own services or hosted models.

Quills works on its own; VoiceInk and other transcription apps are optional.
On first transcription, it downloads its speech model if needed (an internet
connection is required for that download). After setup, transcription runs
offline. You can also download the model in advance with `quills models --download`.

Quills keeps the original Quill architecture: a single Swift binary, a feather
menu-bar icon, and no app bundle.

Quills is a downstream fork of [Quill](https://github.com/digimata/quill),
which provides the original macOS menu-bar recorder, two-track audio capture,
local transcription pipeline, and LaunchAgent support. The changes made in
this fork are documented below so the upstream work and downstream
contributions remain clearly separated.

## Downstream changes

The following additions were made in this fork:

### 2026-09-15 — downstream fork contributions

- **Shared Parakeet v3 model support** — reuse FluidAudio's shared
  `parakeet-tdt-0.6b-v3` cache, including models already installed by VoiceInk,
  instead of maintaining a second private copy.
- **Model download command** — added `quills models --download` to install the
  multilingual Parakeet v3 model before an important meeting.
- **Custom model locations** — added `transcription.model_dir` support so a
  compatible model can be selected directly or through a symlink.
- **Improved model diagnostics** — `quills doctor` checks the selected model
  location, and the menu bar reports model-loading and transcription progress.
- **Documentation and installation updates** — documented shared-model reuse,
  first-use setup, custom model paths, and background launch-at-login usage.

### 2026-09-16 — downstream fork contributions

- **Local read-only MCP server** — added a loopback-only, multi-client MCP
  endpoint for meeting status, metadata, transcript search, and transcript
  reads. It has no recording, editing, or deletion tools and does not make
  outbound network requests.
- **Menu-bar MCP lifecycle controls** — added MCP status plus Start, Stop, and
  Restart actions to the feather menu. Quills stops the MCP child before a
  normal application exit, and launch-at-login starts both without an open
  terminal.

These changes are maintained here as downstream contributions on top of the
upstream project. See the repository history for the individual commits and
implementation details.

## Install

```sh
git clone https://github.com/IndianTinker/quills.git
cd quills
swift build -c release
codesign --force --sign "<your codesigning identity>" --identifier com.indiantinker.quills .build/release/quills
sudo install -m 755 .build/release/quills /usr/local/bin/quills
quills models --download           # optional: prepare the model before first use
quills install --launch-at-login   # optional: start in the menu bar on login
```

See [Code signing (why it matters)](#code-signing-why-it-matters) — without this
step, Quills asks for microphone and System Audio Recording permission on every
recording.

### Updating an existing installation

Quills uses the `quills` command and `/usr/local/bin/quills` install path.
For compatibility with existing Quill installations, it retains
`~/.config/quill/config.json`, `~/Library/Application Support/Quill/status.json`,
and existing `.quill-*` session markers. The signing identifier and LaunchAgent
label are now `com.indiantinker.quills`. Migrating from Quill requires granting
microphone and system-audio permissions again; subsequent updates should use
the same signing identity and identifier to preserve those permissions.
The MCP status JSON retains its `quill` field;
legacy `quill://` resource links remain readable alongside `quills://` links.
New LaunchAgent logs are `/tmp/quills.out.log` and `/tmp/quills.err.log`.
The upstream MIT copyright and license are preserved in [LICENSE](LICENSE).

The menu's **Storage** submenu saves one of three audio retention settings:
**Delete audio after transcription**, **Keep last audio** (both tracks of the
newest fully transcribed session), or **Do not delete anything** (the default).
Cleanup runs when the selection changes, after transcription, and at startup. Transcripts, metadata, and logs
are kept. Pending, failed, partially transcribed, and pre-update recordings keep
their audio. Changing the setting applies immediately to eligible recordings; deleted audio
cannot be restored by selecting a different option. The setting is stored as
`audio_retention` in `~/.config/quill/config.json`, with values
`delete_after_transcription`, `keep_last`, or `keep_all`.

After pulling new Quills changes, build and sign first. Wait until recording
and transcription finish before stopping the old LaunchAgent, installing the
new binary, and registering the LaunchAgent again:

```sh
swift build -c release
codesign --force --sign "<your codesigning identity>" --identifier com.indiantinker.quills .build/release/quills
codesign --verify --strict .build/release/quills
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.indiantinker.quills.plist 2>/dev/null || true
sudo install -m 755 .build/release/quills /usr/local/bin/quills
quills install --launch-at-login
```

When migrating an existing Quill installation, run
`/usr/local/bin/quill install --uninstall` after building and signing, before
starting Quills. This removes the old `com.digimata.quill` LaunchAgent so both
apps do not start at login and compete for the MCP port. Keep the old binary
until the new installation is verified.

### Code signing (why it matters)

The signed binary is not optional. `swift build` produces an ad-hoc, linker-signed
executable with no stable code identity, and macOS privacy (TCC) binds permission
grants — microphone, System Audio Recording — to the binary's identity. An ad-hoc
binary has no usable identity, so macOS prompts for permissions on every single
recording and never remembers the grant.

Sign with a real codesigning identity once and the prompts stop: the first
recording asks, every later recording is remembered. Rebuilds keep the grants as
long as the same identity signs the new binary. List available identities with:

```sh
security find-identity -v -p codesigning
```

Any Apple Development identity works; a self-signed code-signing certificate
created in Keychain Access works too.

The last command starts Quills and its MCP server in the menu bar. The Terminal
window can then be closed; the LaunchAgent keeps Quills running at login. The
feather menu shows MCP status and provides Start, Stop, and Restart controls.
Quills stops its MCP child before a normal exit. If the menu-bar parent is
terminated unexpectedly, the child detects that its parent disappeared and
closes its loopback server as well.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quills` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   white feather shows a red dot at its bottom-right, the menu shows a
   running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically. The status bar shows model loading and transcription
   progress; a notification fires when the transcript is ready.

Option-click the feather to start or stop recording. A single click or
right-click opens the menu immediately.

Press **Control–Option–Command–R (⌃⌥⌘R)** from any app to start or stop a
recording. This provides access even if macOS hides Quills in a crowded menu
bar. The feather stays one fixed icon wide; status details live in its menu
and tooltip. If another app has claimed the shortcut, Quills logs a warning
and its menu control remains available. The shortcut needs no Accessibility
permission.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The engine is **Parakeet TDT 0.6B v3**
(multilingual: 25 European languages plus Japanese) via
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port.
It uses FluidAudio's shared user-level cache at
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`. If
another app such as VoiceInk has already installed a compatible v3 bundle,
Quills reuses those files. If the model is absent,
`quills models --download` (or the first transcription while online)
downloads v3 into that same shared cache. Quills never keeps a second private
model copy.

The **Models** submenu lists supported models, their language/size guidance,
and whether they are installed. Click an installed model to select it; click
an absent model to download and validate it before selecting it. Downloads run
in the background, and failed downloads leave the previous selection in place.
Models are stored in FluidAudio's shared cache, each in its own directory.

| Model | Guidance |
|---|---|
| Parakeet TDT 0.6B v3 (default) | Fast, multilingual; recommended starting point |
| Parakeet TDT 0.6B v2 | Fast, English only; 600M parameters |
| Parakeet TDT-CTC 110M | English only; smaller, faster loading, less memory |

Speed and accuracy depend on hardware, language, and audio quality. These labels
are selection guidance, not a measured accuracy ranking for meeting recordings.
Whisper and other model families require additional engines and are not yet
supported by Quills.

Use **Browse for existing model…** to choose a model type and an existing
FluidAudio-compatible Core ML folder. Quills checks that it loads, then saves
the path and reuses the files in place, including folders shared with another
app or accessed through a symlink. Choose the matching type; a folder contains
multiple compiled `.mlmodelc` bundles and a vocabulary JSON file, rather than
one universal model file. An incomplete custom folder reports an error and is
never populated by automatic downloads. **Show selected model in Finder** opens
its location.

A model change takes effect at the next transcription session. A session already
being transcribed keeps the same model for both tracks; queued sessions use the
new selection. Transcript JSON records the model used. Files on disk are shared;
loaded model instances in memory belong to each app separately.

Before a meeting, run this once to make model setup explicit:

```sh
quills models --download
quills doctor
```

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Before writing, Quills filters long,
nearly identical microphone spans that overlap the same system speech, keeping
the system version as `them`. This reduces speaker playback appearing twice.
Replies under five words, distinct speech, and later repetitions are preserved.
It is conservative and may leave echoes with substantially different recognition.
The feather pulses continuously during both model loading and transcription
(recording still takes priority with a white feather and red dot). The dropdown also shows the selected model.

Shared model files do not mean shared live inference: Quills loads its own
Core ML model instance and releases it when the queue drains. Reusing a model
already loaded inside VoiceInk would require VoiceInk to expose an inference
service that Quills can call.

Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true,
    "engine": "parakeet",
    "model": "parakeet-tdt-0.6b-v3",
    "model_dir": "~/Models/parakeet-tdt-0.6b-v3"
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.model` — `parakeet-tdt-0.6b-v3` (default),
  `parakeet-tdt-0.6b-v2`, or `parakeet-tdt-ctc-110m`. The Models menu saves this.
- `transcription.model_dir` — optional path to a **FluidAudio-compatible
  Core ML bundle matching the selected model type**. It can be a folder used by another local
  transcription app, or a symlink to that folder. When absent, Quills uses the
  standard FluidAudio shared cache. `quills models --download`
  and `quills doctor` use this selected path. Custom paths must already contain
  a complete model. Selecting a built-in model in the menu clears the custom path.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quills                        # run the menu-bar daemon (^C to quit)
quills run --out <dir>        # custom recordings root (default ~/Recordings)
quills doctor                 # check permissions, recordings folder, models
quills models                 # list supported models and cache locations
quills models --download      # pre-download/reuse the selected model
quills models --download --model parakeet-tdt-ctc-110m # download without changing selection
quills mcp --out <dir>        # run the local read-only MCP server directly
quills install --launch-at-login
quills install --uninstall
```

## MCP server

Quills includes a local, read-only [MCP](https://modelcontextprotocol.io/)
server for consuming meeting data from MCP clients. When Quills is running in
the menu bar, it starts the server automatically at:

```text
http://127.0.0.1:47777/mcp
```

The server binds only to loopback, reads only from the configured recordings
folder and Quills’ local runtime-status file, and has no outbound network
client. It exposes status, meeting metadata, transcript search, and complete
transcript reads. It does not expose recording, editing, deletion, or any
other write operation. The endpoint uses independent MCP sessions, so Claude
Code, Codex, OpenCode, and other clients can connect concurrently to the same
running Quills instance.

The `get_status` tool and `quills://status` resource include both Quills runtime
state and MCP connection details: state, loopback host, port, full endpoint,
transport, and read-only mode.

Use the feather menu-bar icon to see whether MCP is running and to **Start**,
**Stop**, or **Restart** it. Choosing **Quit Quills** stops the MCP child
process before Quills exits. With `quills install --launch-at-login`, the menu
bar app (and its MCP server) starts without leaving a terminal open.

The port can be changed in `~/.config/quill/config.json`:

```json
{
  "mcp_port": 47777
}
```

This server being local does not make a cloud MCP client local: a client that
sends transcript content to a hosted model can still transmit that content.
For end-to-end local processing, use a local MCP client and local model.

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- The first v3 download is about 600 MB. Run `quills models --download` on a
  reliable connection before recording an important meeting.
- A model from another app must be the FluidAudio Core ML bundle for the selected Parakeet type;
  Whisper, GGUF, or other model formats cannot be loaded by Quills. To avoid
  duplication, point `transcription.model_dir` directly at it or use a
  symlink, for example: `ln -s "/path/to/model" ~/Models/parakeet-v3`.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quills itself when running as a LaunchAgent.
