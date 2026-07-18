# Native Productivity Tools

Hands-free productivity actions the AI can invoke by voice — timers, Pomodoro, reminders,
calendar, notes, and clipboard. Built on stable Apple frameworks (EventKit, UserNotifications,
CoreLocation, UIPasteboard), so they are **deterministic** with no vision/hallucination surface:
the model only decides *when* to call a tool and *with what arguments*; the tool does the work.

## The tools

| Tool | Name | Backing framework | Notes |
|------|------|-------------------|-------|
| Timer | `set_timer` | UserNotifications | Countdown; foreground banner + in-app chime |
| Pomodoro | `start_pomodoro` | UserNotifications | Work block → break (defaults 25/5) |
| Reminder | `create_reminder` | EventKit (Reminders) | Optional due time |
| Calendar | `calendar` | EventKit (Events) | `today` / `upcoming` / `add` |
| Note | `note` | UserDefaults + CoreLocation | `save` / `search` / `list` / `delete`, auto-tagged with place + time |
| Clipboard | `copy_to_clipboard` | UIPasteboard | — |

> There is intentionally **no alarm tool**. iOS gives third-party apps no API to create alarms in
> the Clock app, and a plain notification is a poor substitute for a wake-up alarm. Use a reminder
> with a due time instead.

## Architecture — one registry, four backends

All tools implement a single `NativeTool` protocol (name, description, JSON-schema parameters,
`execute`). `NativeToolRegistry.shared` owns the instances and exposes backend-shaped specs:

```
NativeTool  ──►  NativeToolRegistry.shared
                 ├─ openAISpecs          → OpenAI Chat Completions tools loop  (OpenAIService)
                 ├─ geminiDeclarations    → Gemini Live setup + toolCall loop    (GeminiLiveService)
                 ├─ (AppleNativeTools)    → Apple FoundationModels `Tool`        (AppleFoundationService)
                 └─ (JSON-in-text)        → on-device Gemma 4 via LocalAgent      (GemmaLocalService)
```

- **OpenAI / Gemini Live** — the model emits a native function call; we dispatch to
  `NativeToolRegistry.shared.execute(name:args:)` and feed the result back in the same turn.
- **Apple Intelligence** — Apple's `Tool` protocol needs a typed `@Generable` Arguments struct, so
  `AppleNativeTools.swift` wraps each tool in a thin forwarder to the same registry.
- **On-device Gemma 4** — small VLMs don't do reliable native tool-calling, so `LocalAgent.route`
  reuses the app's existing JSON-in-text pattern (already used for face actions + web search): the
  model replies with `{"tool":"set_timer","seconds":300}`, we parse the first `{…}` and dispatch.
  (mlx-swift-lm can't yet parse Gemma 4's native `<|tool_call>` tokens — [issue #259][259] — so the
  JSON path is both more portable and more robust here.)

Adding a tool = implement `NativeTool`, register it in `NativeToolRegistry`, add an
`AppleNativeTools` wrapper, and add one line to each backend's prompt. The dispatch is shared.

## Pixel-perfect times

Small models are unreliable at clock arithmetic (an early test turned "remind me at 6 PM" into a
reminder at 4:02 PM). So **the tool does the date math, never the model.** Reminder and Calendar
accept, in priority order (`NativeToolSupport.resolveDate`):

1. **Clock time** — `hour` (0–23) + optional `minute` + `day_offset` (0=today, 1=tomorrow). The
   model only maps "6 PM → hour 18", which even a 2B model does reliably. If no day is given and the
   time already passed today, it rolls to the next occurrence.
2. **Relative** — `minutes_from_now`, for "in N minutes / from now".
3. **ISO 8601** — `due_iso8601` / `start_iso8601`, last-resort fallback.

Every backend's prompt steers time-of-day requests to `hour`/`minute` and relative requests to
`minutes_from_now`, so times are exact on all four backends.

## Notifications & sound

Timer/Pomodoro alerts fire even while the app is foregrounded via
`NotificationForegroundPresenter` (a `UNUserNotificationCenterDelegate` returning
`[.banner, .sound, .list]`). Because an active audio session + the silent switch can suppress the
notification sound, the presenter also plays an in-app chime (`SoundService.playAlert()`, audible in
silent mode) for `timer-` / `pomodoro-` notification IDs.

## Permissions

`Info.plist` declares `NSRemindersUsageDescription` / `NSRemindersFullAccessUsageDescription`,
`NSCalendarsUsageDescription` / `NSCalendarsFullAccessUsageDescription`, and
`NSLocationWhenInUseUsageDescription` (note geotagging). Access is requested on first use.

## Privacy

Notes are stored **in-app** (UserDefaults + Codable via `ContextualNoteStore`) — they are *not*
written to Apple Notes. Tool logging records the tool name and which parameter *keys* were passed —
never the values (note text, event titles, clipboard contents).

[259]: https://github.com/ml-explore/mlx-swift-lm/issues/259
