# Meeting Assistant

A native macOS menu-bar app that watches your calendar, automatically captures
meetings (Zoom, Google Meet, Microsoft Teams) when they start, and produces a
speaker-labeled transcript plus an AI summary with action items — all processed
locally on Apple Silicon.

## Goals

- **Reads your calendar** (EventKit) and auto-starts capture when a calendared
  meeting begins and the meeting app is detected running.
- **100% local transcription** via WhisperKit (runs on the Apple Neural Engine).
- **Speaker labeling** — exact "you vs. others" via separate mic/system-audio
  channels, with on-screen active-speaker detection for remote participant names.
- **Local AI summary + action items**, with one-click re-summarize via the Claude API.
- **Runs smoothly during calls** — cheap live capture, heavy post-processing after
  the meeting ends, so your Mac stays responsive.

Target hardware: MacBook Pro M1 Pro / 32 GB, macOS 14 (Sonoma)+.

## Status

Early planning. Implementation plan is being refined before build begins.
