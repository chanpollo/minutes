# Real Windows validation

This build is an incomplete preview. Check PARITY.md before testing. Missing features are not accepted as passed. Use synthetic meetings and an isolated test workspace. Do not commit recordings, credentials or user data.

## Install and start

1. Download `Minutes-0.7.0-win-x64-unsigned` from the Windows workflow run. Extract the entire ZIP to a writable folder; do not run inside the ZIP. Launch Minutes.App.exe. The ZIP is unsigned; record any SmartScreen result.
2. Use a Windows 11 x64 PC first. Also test Windows 10 2004+ whole-system fallback once supported. Note OS build, CPU, audio devices, app commit and artifact run URL.
3. Open Settings. Choose an empty workspace. Download speech models; check progress, retry after interrupted network, checksum failure, and completed sizes under `%LOCALAPPDATA%\Minutes\models`.
4. Verify light/dark themes, text scaling, keyboard focus, high contrast, accessible names and no decorative panels. Close the window, reopen through the tray. Check Ctrl+Alt+R and collisions with an existing registered hotkey.
5. Enable Open at login; sign out/in and verify exactly one instance. Disable it and verify it no longer starts.

## Notes and workspace interoperability

1. New Note, title `Synthetic planning`. Enter Thai and English Markdown; close/reopen and check bytes in notes.md.
2. Pin, archive/reopen, search by title and note text, create a group. Treat missing group assignment/reorder/delete/undo as open parity gaps.
3. Open a copy of a synthetic Mac workspace. Confirm ISO timestamps, legacy `call`/`inPerson`, attendees, groups, confidential state, notes and unknown meta fields survive a Windows save.
4. Rename the meeting. Original `# title` headers should follow; hand-edited headers should stay. Reopen on Mac and check the same identity and metadata.
5. Select a summary/transcript quote. Add a comment and reply, resolve/reopen. Inspect comments.json/comments.md. Reanchoring after a rerun, legacy comments and AI revisions require separate acceptance once their UI is built.
6. Export a note and a recorded meeting. Check Unicode filenames and contents.

## Teams, audio and screen

1. Start a Teams test call with a second consenting tester. Explicitly tell them it is recorded. Test both Teams desktop and browser, then Zoom/LINE. Automatic detection and process loopback are pending; manually start Voice in this preview.
2. Record with **headphones**: both people speak distinct numbered synthetic sentences, pause, overlap, mute the Minutes microphone for ten seconds, unmute. Stop. Listen separately to me.wav and others.wav; microphone mute must not remove the call track or shorten time.
3. Repeat on **loudspeakers**. Check echo/leak and the AEC policy. AEC is pending; document the gap, do not label it verified.
4. Play unrelated audio in another app. Whole-system fallback will include it; process-loopback acceptance requires proving the unrelated app is excluded and the meeting app's child processes remain included.
5. Screen acceptance (pending implementation): choose the newest eligible meeting window, resize, minimize, change monitors/DPI, deny capture consent, unplug a monitor. Verify meeting.mp4 is H.264 plus mixed AAC, full window resolution, correct start offset, no drift at 30/60 minutes, screen failure explicitly reported, and Voice has no video.
6. Detector acceptance (pending): two consecutive two-second mic polls before Record?, 3-second release before Stop?, 30-second stop, short mute/rejoin, Same Meeting/New Meeting, Always Record, Not now expiry, app allow list, Keep Recording stopping after call audio ceases.
7. Quit during a recording, crash/kill, restart, disk full, unplug capture device. The unfinished recording must remain recoverable; recovery behavior is pending.

## Transcript and summary

1. Transcribe a short Thai/English synthetic call. Verify first-party bundled whisper and sherpa executables load on a PC without a compiler or Python. Check Me/Others, numbered speakers by first appearance, Thai token joins, short phantom voices, silent tracks and no-speech text.
2. Compare with Mac using identical synthetic whisper JSON and diarizer output. Second-pass loop repair, measured-leak filtering, speaker rename and verified FLAC conversion are still open gates.
3. For **each** Claude, Codex, agy and Ollama, test an installed native CLI, npm shim, explicit custom path, PATH containing spaces, missing tool, unsigned-in tool, timeout and cancellation. Check model menu discovery (pending) and account login independently.
4. Sign In… opens Windows Terminal or cmd with exactly `claude auth login`, `codex login`, or `agy`; no transcript is part of that command. Cancel login; retry; reopen Settings. Ollama has no Sign In.
5. Summarise with Thai, English and meeting language. Confirm exactly summary/decisions/actions, unchanged original terms, grounded owners/deadlines, and timestamps. Provider tools/MCP/settings must be disabled as on Mac.
6. Start an existing Ollama on 11434 and monitor it. Minutes must use only 21434 and terminate only its own server on exit. Test missing model, context overflow and `<think>` removal.
7. Set Summary Off: all summary requests must refuse. Mark a meeting confidential: automatic summary must skip, explicit summary must ask, sync must withdraw. Record whether a concurrent confidentiality change stops a running job (open hardening gate).
8. Calendar (pending adapter): classic Outlook current title/invitees, room vs call ranking, declined/all-day events, overlapping events, hand-selected event, external-domain confidentiality; new Outlook/365 needs separately configured Graph consent.

## Media, sync and retention

1. Existing briefing.md: Listen, change meeting, start recording. No briefing or meeting audio may continue into a recording. Saved AAC, voice choices, sentence marks and script generation remain pending.
2. Frame extraction/OCR (pending): synthetic Thai/English slides; same 64×36 grid, ≥3s stillness, max 40, correct frames.json and hh-mm-ss.jpg, max six known summary links. Capture and attachments must survive video deletion.
3. Point folder sync at an isolated OneDrive/Google Drive/Dropbox directory. Sync text and media, repeat unchanged, edit notes, rename/group, disconnect the folder and retry. Ensure meta.json, comments.json, revisions, briefing.m4a, unreferenced frames and confidential meetings are excluded.
4. Mark a copied meeting confidential with Sync Off and Folder modes; prior copies must be withdrawn. Switch destination while old location is offline and retry later. Test confidentiality during a large copy (open hardening gate).
5. Direct Google OAuth (pending): user-supplied Desktop client, PKCE/loopback, refresh/revoke, resumable upload, token protected with DPAPI/Locker. Never use a developer's bundled client or real credentials in fixtures.
6. Retention (pending): age synthetic media past 90 days, keep audio forever by default, delete tracks only after a transcript, never delete notes/summary/transcript/pictures/comments; busy jobs protected. Test synced deletion only when explicitly enabled.

## Record results

For each step record pass/fail/not implemented, artifact SHA, OS/device setup and synthetic fixture. Attach screenshots/logs with private paths and identities removed. CI compilation does not replace any step above. Full parity requires closing every pending row in PARITY.md and running this checklist.
