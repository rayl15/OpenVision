# Meeting Notes

Record a meeting hands-free, transcribe it on the phone, and get a summary with decisions and
action items from whichever AI backend is selected.

## Using it

- **Start:** "Ok Vision, start taking notes" (Hinglish: "notes lena shuru karo"), the notes icon on
  the Voice screen, or **Start** in the **Meetings** tab.
- **Stop:** "stop taking notes" (Hindi: "नोट्स बंद करो", Hinglish: "notes band karo"), or the Stop
  button. The stop phrase and anything after it are left out of the transcript.
- **Settings → Voice → Meeting Notes:** language and microphone. The phone mic (default) hears the
  whole room; the glasses mic mostly hears the wearer and isn't used while the camera streams.

## How it fits together

| File | Role |
|------|------|
| `Services/Meetings/MeetingTranscriber.swift` | Owns its own mic engine and the recognizer; watchdog |
| `Services/Meetings/MeetingNotesController.swift` | One meeting at a time: start/stop, autosave, stop phrase, summary, health log |
| `Services/Meetings/MeetingSummarizer.swift` | Picks the model, splits long meetings, merges the parts |
| `Services/Meetings/MeetingNotesLogic.swift` | Pure, unit-tested: phrases, chunking, prompts, parsing, recap |
| `Services/Meetings/MeetingStore.swift` | One JSON file per meeting in `Documents/Meetings` |
| `Services/NativeTools/MeetingsTool.swift` | The `meetings` tool for asking about past meetings |
| `Views/Meetings/` | The Meetings tab and meeting detail |

The voice agent (`VoiceAgentViewModel`) owns everything around a meeting: it suspends the
wake-word listener (`VoiceCommandService.suspend()`, so no restart path can start a second
recognizer), sets the audio route, and speaks. The Meetings tab's button goes through
`MeetingNotesController.onToggleRequested` to the same code as the voice command.

## Transcription

- **iOS 26+:** `SpeechAnalyzer` + `SpeechTranscriber`, long-form with no time limit. Supports
  English, Hindi, `mul_IN` (Apple's multilingual Indian model, used for Hinglish) and other Indian
  languages; check `SpeechTranscriber.supportedLocales` on a device for the current list.
- **Fallback:** `SFSpeechRecognizer` in ~50 s segments (one task stops after about a minute), with
  per-task ids so a finished or cancelled task can only commit its own text once and can never
  restart recognition.
- **Audio never leaves the phone.** If the language's `SpeechAnalyzer` model isn't installed: for a
  language the fallback can transcribe on-device (English), the model downloads in the background
  for next time; otherwise (Hindi) it downloads first, with progress in the banner. A language
  that can only be recognised on Apple's servers is refused rather than sent there.

### Watchdog (every 5 s)

- No mic buffers for 6 s → re-arm the mic (new engine; a stopped engine reports a stale format).
- The recognizer's results end while recording → restart it. Five restarts in ten minutes ends the
  meeting, keeping the transcript.
- 20 s of loud audio with no text → restart the recognizer. This never ends the meeting (it may be
  music or noise).
- In-progress text is committed before a restart, and stopping gives a stuck recognizer at most
  5 s.

## Summaries

Privacy: audio never leaves the phone. The transcript text goes to every backend the summariser
tries: the selected one first, then Apple Intelligence if it can't or fails. So with OpenAI (or
the OpenAI-compatible server set as its base URL), Grok or Gemini selected, that provider receives
the transcript even if Apple Intelligence ends up writing the notes. Apple Intelligence and Local
(MLX) keep it on the phone; Hermes and OpenClaw never receive it. The spoken recap goes through the
selected Speech Engine, so a cloud voice (Grok, OpenAI) receives the recap text.

- `AIBackend.completeText(system:prompt:)` — one-off text with no history, tools or document
  context. Hermes and OpenClaw return nil (they're agents with their own sessions), so the
  summariser falls back to Apple Intelligence.
- Size: cloud models get up to 60,000 transcript characters per request; on-device models get what
  fits `textContextTokens` minus 2,000 tokens for instructions and the reply, at ~3 characters per
  token for Latin script and ~1 for others. Longer meetings are condensed part by part (up to three
  rounds) and the parts' notes merged.
- Language: the meeting's language, except mixed-language meetings (English) and models that can't
  write it (`canWriteLanguage`; Apple Intelligence has no Hindi), which write English and say so.
- On-device models can't run in the background. A summary needed while the phone is locked is
  marked `summaryWaitingForApp` and written when the app next becomes active.

## Soak testing

While recording, a line is logged every minute (counts only, never transcript text):

```
[Meeting] health 5:00 words=313 segments=11 engine=SpeechAnalyzer mul_IN restarts=1 mem=99MB headroom=6045MB cpu=26% thermal=nominal battery=90% app=foreground
```

Launch with `xcrun devicectl device process launch --console …` to capture it.
