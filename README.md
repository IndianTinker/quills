# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

This repository is a downstream fork of [digimata/quill](https://github.com/digimata/quill),
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
- **Model download command** — added `quill models --download` to install the
  multilingual Parakeet v3 model before an important meeting.
- **Custom model locations** — added `transcription.model_dir` support so a
  compatible model can be selected directly or through a symlink.
- **Improved model diagnostics** — `quill doctor` checks the selected model
  location, and the menu bar reports model-loading and transcription progress.
- **Documentation and installation updates** — documented shared-model reuse,
  first-use setup, custom model paths, and background launch-at-login usage.

### 2026-09-16 — downstream fork contributions

- **Local read-only MCP server** — added a loopback-only, multi-client MCP
  endpoint for meeting status, metadata, transcript search, and transcript
  reads. It has no recording, editing, or deletion tools and does not make
  outbound network requests.
- **Menu-bar MCP lifecycle controls** — added MCP status plus Start, Stop, and
  Restart actions to the feather menu. Quill stops the MCP child before a
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
sudo install -m 755 .build/release/quill /usr/local/bin/quill
quill models --download           # downloads only if VoiceInk has not already
quill install --launch-at-login   # optional: start in the menu bar on login
```

### Updating an existing installation

After pulling new Quill changes, stop the old LaunchAgent, replace the binary,
and register the LaunchAgent again:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.digimata.quill.plist 2>/dev/null || true
swift build -c release
sudo install -m 755 .build/release/quill /usr/local/bin/quill
quill install --launch-at-login
```

The last command starts Quill and its MCP server in the menu bar. The Terminal
window can then be closed; the LaunchAgent keeps Quill running at login. The
feather menu shows MCP status and provides Start, Stop, and Restart controls.
Quill handles normal LaunchAgent termination gracefully and closes its MCP
child before exiting.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically. The status bar shows model loading and transcription
   progress; a notification fires when the transcript is ready.

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
VoiceInk has already installed v3, Quill reuses it immediately. If it is not
there, `quill models --download` (or the first transcription while online)
downloads v3 into that same shared cache. Quill never keeps a second private
model copy.

Before a meeting, run this once to make model setup explicit:

```sh
quill models --download
quill doctor
```

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
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
    "model_dir": "~/Models/parakeet-tdt-0.6b-v3"
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.model_dir` — optional path to a **FluidAudio-compatible
  Parakeet TDT v3 Core ML bundle**. It can be a folder used by another local
  transcription app, or a symlink to that folder. When absent, Quill uses the
  standard FluidAudio shared cache. `quill models --download`, automatic
  first-use downloads, and `quill doctor` all use this selected path.
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
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill models --download      # pre-download/reuse shared multilingual v3 model
quill mcp                    # run the local read-only MCP server directly
quill install --launch-at-login
quill install --uninstall
```

## MCP server

Quill includes a local, read-only [MCP](https://modelcontextprotocol.io/)
server for consuming meeting data from MCP clients. When Quill is running in
the menu bar, it starts the server automatically at:

```text
http://127.0.0.1:47777/mcp
```

The server binds only to loopback, reads only from the configured recordings
folder and Quill's local runtime-status file, and has no outbound network
client. It exposes status, meeting metadata, transcript search, and complete
transcript reads. It does not expose recording, editing, deletion, or any
other write operation. The endpoint uses independent MCP sessions, so Claude
Code, Codex, OpenCode, and other clients can connect concurrently to the same
running Quill instance.

The `get_status` tool and `quill://status` resource include both Quill runtime
state and MCP connection details: state, loopback host, port, full endpoint,
transport, and read-only mode.

Use the feather menu-bar icon to see whether MCP is running and to **Start**,
**Stop**, or **Restart** it. Choosing **Quit quill** stops the MCP child
process before Quill exits. With `quill install --launch-at-login`, the menu
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
- The first v3 download is about 600 MB. Run `quill models --download` on a
  reliable connection before recording an important meeting.
- A model from another app must be the FluidAudio Parakeet v3 Core ML bundle;
  Whisper, GGUF, or other model formats cannot be loaded by Quill. To avoid
  duplication, point `transcription.model_dir` directly at it or use a
  symlink, for example: `ln -s "/path/to/model" ~/Models/parakeet-v3`.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
