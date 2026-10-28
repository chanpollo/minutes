# Minutes — plan

Records meetings on the Mac (audio and the meeting window), transcribes them locally, summarises them on request with the AI subscription you already pay for, keeps them in a workspace folder that also goes to Google Drive, and shows them in a Notion-style window.

## Scope

- Mac first (macOS 14.2+). The team gets it later, so the meeting folder format and the summary step must not depend on Swift.
- Notes are files on disk; the app window reads and edits the same files.
- Flow: a call takes the mic → "Record this meeting?" with a default title → record → the folder lands in the workspace named `date time title` → transcript is made locally → the user presses Summarise when wanted.

## Stack

| Part | Choice | Why |
|---|---|---|
| App shell | Swift, AppKit menu bar + floating prompt | Needs Core Audio process taps and non-activating panels |
| Notes window | SwiftUI in an AppKit window | List, editable title, video, transcript, notes without a web runtime |
| Audio | Core Audio process tap (others) + AVAudioEngine (me), 16 kHz mono WAV | Two tracks give "Me / Others" without diarization |
| Video | ScreenCaptureKit, the meeting app's largest window (whole display if none), 15 fps HEVC | Only the call, not notifications or other apps |
| Final media | `meeting.mp4`: the video passed through plus both WAVs mixed to AAC | One file to watch; no video re-encode |
| Transcription | whisper.cpp `whisper-cli`, large-v3-turbo q5_0, Silero VAD, language auto per track | Offline; Thai and English both verified |
| Summary | On request. `claude -p` with no tools, MCP or settings; model Sonnet by default, Opus or Haiku selectable | Runs on the Claude subscription login; nothing else in the session can act |
| Workspace | A folder the user picks (default `~/Documents/Meetings`); recordings are staged in Application Support and moved in when finished | Plain files; a synced folder never sees half-written audio |
| Google Drive | The app uploads each meeting itself: OAuth (desktop client, PKCE, loopback on 127.0.0.1), scope `drive.file`, resumable uploads, refresh token in the Keychain | No Drive for Desktop needed; the app can only see what it created |
| Search | In-memory over titles and transcripts first; SQLite FTS5 later | Small workspaces first |
| Calendar | Later: EventKit to prefill the title | The title is typed or edited by hand for now |

## Meeting folder

```
2026-10-27 1400 Sprint review/
  meta.json        id, title, start, end, app, summary model, Drive file ids
  me.wav
  others.wav
  meeting.mp4      meeting window + mixed audio
  transcript.md    timestamped, Me / Others
  summary.md       summary, decisions, action items (owner, due) — only after Summarise
  notes.md         typed in the notes window
```

Drive gets `meeting.mp4` (or the two WAVs when there is no video), `transcript.md`, `summary.md` and `notes.md`, under `Minutes/<folder name>`. `meta.json` stays local: it records the Drive ids, so uploading it would change it on every upload.

## Build order

1. **Title and workspace** — default title in the record prompt, editable; Choose Workspace…; staging then move; `meta.json`.
2. **Summary on request** — Summarise button on "Transcript ready" and in the notes window; model menu (Sonnet default); `Minutes --summarize <folder> [--model opus]`.
3. **Screen video** — meeting window capture, `meeting.mp4` after stop; Record Screen switch; Screen Recording permission.
4. **Notes window** — meetings by day with search; page with an editable title (renames the folder), video player, Summary / Transcript tabs (click a line to seek), `notes.md` editor, Summarise with model choice.
5. **Google Drive** — Connect / Disconnect in the menu; upload after transcription and after each summary or rename; retry on the next launch.

## Later

- Prefill the title from Google Calendar (EventKit).
- Split "Others" into speakers (sherpa-onnx diarization).
- Codex CLI and API key as summary providers.
- Signed and notarised build for the team; Windows client on the same folder format.

## Open points

- The prompt appears for any app holding the mic for 4 s; a meeting-app allow list may be quieter.
- Recording consent: other participants are not told the call is recorded.
- Drive needs an OAuth client ID (Google Cloud, type Desktop app) before Connect works.
