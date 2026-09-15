# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
git clone https://github.com/IndianTinker/quills.git
cd quills
swift build -c release
sudo install -m 755 .build/release/quill /usr/local/bin/quill
quill models --download           # downloads only if VoiceInk has not already
quill install --launch-at-login   # optional: start in the menu bar on login
```

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
quill install --launch-at-login
quill install --uninstall
```

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
