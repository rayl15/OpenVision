# OpenVision Setup Guide

Complete step-by-step guide to set up and run OpenVision.

> ## Read this first: you must build from source
>
> Meta's Wearables Device Access Toolkit — the SDK that lets any app talk to Ray-Ban Meta
> glasses — is in **developer preview**. Meta's own FAQ: *"Publishing is currently not available
> during the Developer Preview phase."* Builds can only be shared through **invite-only release
> channels, capped at 100 testers**, and only select partners may publish to the public.
>
> So there is **no App Store build, no TestFlight, and no downloadable IPA** — not because of
> Apple, but because glasses features would be dead for anyone outside the developer's own Meta
> release channel. Building it yourself sidesteps that entirely: you register your own Meta app
> and are your own developer, so you never need an invite from anyone.
>
> What you need: a **Mac**, an **iPhone**, and a free **Meta developer account**. An Apple
> Developer account is free too. The glasses are optional — the iPhone camera works as a fallback.

## Prerequisites

### Required
- **Mac** with macOS 13.0 (Ventura) or later
- **Xcode 15.0** or later
- **iOS device** running iOS 16.0+ (simulator doesn't support Bluetooth)
- **Apple Developer Account** (free or paid)
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`. The Xcode
  project is generated from `project.yml`; re-run `xcodegen generate` after adding or removing files
- **Metal Toolchain** — `xcodebuild -downloadComponent MetalToolchain` (~688 MB, one-time).
  Recent Xcode versions ship without a Metal compiler, and the on-device AI runtime compiles its
  own Metal shaders. Skip this and the build fails with *"cannot execute tool 'metal'"*

### Optional
- **Meta Ray-Ban smart glasses** - For glasses integration (iPhone camera works as fallback)
- **OpenClaw instance** - For OpenClaw AI backend
- **Gemini API key** - For Gemini Live AI backend

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/rayl15/OpenVision.git
cd OpenVision
```

---

## Step 2: Configure Build Settings

### 2.1 Create Config.xcconfig

```bash
cp Config.xcconfig.example Config.xcconfig
```

Edit `Config.xcconfig` with your values:

```
// Your development team ID (from developer.apple.com)
DEVELOPMENT_TEAM = XXXXXXXXXX

// Unique bundle identifier for your app
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.openvision

// Meta App ID from developer.meta.com (required for glasses)
META_APP_ID = your_meta_app_id_here
```

### 2.2 Create Config.swift

```bash
cp OpenVision/Config/Config.swift.example OpenVision/Config/Config.swift
```

This file can contain default API keys (optional - users can also enter them in-app):

```swift
enum Config {
    // Leave empty if users will enter in Settings
    static let defaultOpenClawURL = ""
    static let defaultOpenClawToken = ""
    static let defaultGeminiAPIKey = ""
}
```

### 2.3 Get Your Development Team ID

1. Open Xcode
2. Go to **Xcode → Settings → Accounts**
3. Sign in with your Apple ID
4. Click your team name
5. Your Team ID is shown (10 characters)

### 2.4 Get Your Meta App ID and Client Token (For Glasses)

If you want to use Meta Ray-Ban glasses:

1. Go to [wearables.developer.meta.com](https://wearables.developer.meta.com/)
2. Create an account, an organization, and an app
3. Add the **Meta Wearables** product
4. Copy your **App ID** and **Client Token** from the dashboard
5. Add both to `Config.xcconfig`, along with a URL scheme:

```
META_APP_ID = 1234567890
CLIENT_TOKEN = AR|1234567890|your_client_token_hash
APP_LINK_URL_SCHEME = openvision
```

`CLIENT_TOKEN` needs the **full `AR|<app id>|<hash>` form**, not just the hash.

> **Leaving these as placeholders has a confusing symptom.** The app builds and launches fine,
> but glasses registration never completes — and because the camera permission prompt sits behind
> registration, Connect just appears to do nothing rather than reporting a credentials error.

### 2.5 Enable Developer Mode in the Meta AI app

**Required** — glasses will not register without it:

1. Open the **Meta AI** app on your iPhone
2. Go to **Settings → About**
3. Tap the **version number 5 times**
4. Toggle **Developer Mode** on

**Note:** You can skip 2.4 and 2.5 if testing with the iPhone camera only.

---

## Step 3: Add Meta DAT SDK

The Meta Wearables Device Access Toolkit (DAT) SDK is required for glasses integration.

**Nothing to do — this is already wired up.** `project.yml` declares the SDK
(`https://github.com/facebook/meta-wearables-dat-ios`, pinned to `0.4.0`) and pulls in
`MWDATCore` + `MWDATCamera`, so `xcodegen generate` and a build resolve it for you.

> The pin is deliberate: 0.6.0 made `StreamSession.init` inaccessible and 0.7.0 renamed the
> type outright. Don't float it without updating `GlassesManager`.

---

## Step 4: Configure Capabilities

In Xcode, select your target and go to **Signing & Capabilities**:

### Required Capabilities

1. **Background Modes**
   - Audio, AirPlay, and Picture in Picture
   - Background fetch
   - Background processing

2. **App Groups** (optional, for sharing data)

### Info.plist Keys

Add these to your `Info.plist`:

```xml
<!-- Microphone access for voice input -->
<key>NSMicrophoneUsageDescription</key>
<string>OpenVision needs microphone access for voice conversations with AI.</string>

<!-- Camera access for photo capture -->
<key>NSCameraUsageDescription</key>
<string>OpenVision uses the camera to capture photos for AI analysis.</string>

<!-- Speech recognition for wake word -->
<key>NSSpeechRecognitionUsageDescription</key>
<string>OpenVision uses speech recognition to detect your wake word and voice commands.</string>

<!-- Bluetooth for glasses connection -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>OpenVision connects to Meta Ray-Ban glasses via Bluetooth.</string>

<!-- Meta Wearables callback URL scheme -->
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>openvision</string>
        </array>
    </dict>
</array>
```

---

## Step 5: Build and Run

### In Xcode

1. Generate the project: `xcodegen generate` (re-run whenever files are added or removed)
2. Connect your iOS device via USB and **unlock it**
3. Select your device as the run destination
4. Press **Cmd+R** to build and run
5. Trust the developer certificate on your device if prompted:
   - Go to **Settings → General → VPN & Device Management**
   - Tap your developer certificate and trust it
   - You must do this again after switching Xcode versions — the certificate changes, and until
     it's trusted the app installs but refuses to launch

### From the command line

```bash
xcodegen generate

xcodebuild -scheme OpenVision -project OpenVision.xcodeproj -configuration Debug \
  -destination 'id=<your-device-udid>' -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation build

xcrun devicectl device install app --device <your-device-udid> \
  build/DerivedData/Build/Products/Debug-iphoneos/OpenVision.app
```

`xcrun devicectl list devices` prints your UDID.

Both `-skipMacroValidation` and `-skipPackagePluginValidation` are required: the MLX packages
ship a Swift macro and a build plugin, which Xcode's GUI trusts with a click but the CLI does not.

**Run the tests** with the same flags: `xcodebuild test -scheme OpenVision -destination 'id=<udid>'`

### Troubleshooting the build

| Symptom | Cause |
|---|---|
| `cannot execute tool 'metal'` | Metal Toolchain not installed — see Prerequisites |
| `Macro ... must be enabled` | Missing `-skipMacroValidation` |
| `The developer disk image could not be mounted` | Device is **locked** (unlock and keep it awake), or your Xcode is older than the device's iOS — install a newer Xcode; `-downloadPlatform iOS` will *not* fix this |
| `cannot find X in scope` after adding files | Run `xcodegen generate` |

---

## Step 6: Configure AI Backend

Once the app is running:

### OpenClaw Setup

1. Go to **Settings → AI Backend**
2. Select **OpenClaw**
3. Tap **OpenClaw Settings**
4. Enter:
   - **Gateway URL**: Your OpenClaw WebSocket URL (e.g., `wss://your-server.com:18789`)
   - **Auth Token**: Your OpenClaw authentication token
5. Tap **Test Connection** to verify

**If the gateway is on your local network** (not localhost), it will not grant
the app write access on a token alone — `chat.send` fails with
`missing scope: operator.write`. The app presents a signed device identity, and
the gateway holds it as a pairing request until you approve it once, on the
machine running the gateway:

```bash
openclaw devices list                  # find the pending request id
openclaw devices approve <requestId>
```

The first connection is expected to fail with "pairing required: device is not
approved yet". Approve it, and the app connects on the next attempt. The app's
key is stored in the Keychain, so this is a one-time step per device.

### Gemini Live Setup

1. Go to **Settings → AI Backend**
2. Select **Gemini Live**
3. Tap **Gemini Settings**
4. Enter your [Gemini API key](https://aistudio.google.com/app/apikey)

---

## Step 7: Register Glasses (Optional)

If you have Meta Ray-Ban glasses:

1. Ensure glasses are paired with your iPhone via Bluetooth
2. Go to **Settings → Glasses**
3. Tap **Register with Meta AI**
4. Follow the Meta AI app authentication flow
5. Return to OpenVision when prompted
6. Your glasses should now show as "Connected"

### Troubleshooting Glasses

- **Glasses not appearing**: Ensure Bluetooth is on and glasses are paired in iOS Settings
- **Registration fails**: Check your Meta App ID in Config.xcconfig
- **Streaming issues**: Try disconnecting and reconnecting the glasses

---

## Step 8: Start Using OpenVision

### OpenClaw Mode

1. Tap the main orb button OR say **"Hey Vision"**
2. Wait for "Listening..." status
3. Speak your question or command
4. AI responds via text-to-speech

### Gemini Live Mode

1. Tap the main orb button to start
2. Just speak naturally (no wake word needed)
3. AI responds with natural voice
4. Video streams continuously from glasses

---

## Testing Without Glasses

OpenVision includes iPhone camera fallback for development:

1. Go to **Settings → Glasses**
2. Toggle **Use iPhone Camera** (if glasses aren't connected)
3. Photo commands will use your iPhone's camera

---

## Troubleshooting

### Build Errors

| Error | Solution |
|-------|----------|
| "Signing certificate not found" | Add your Apple ID in Xcode → Settings → Accounts |
| "Missing package dependencies" | File → Packages → Resolve Package Versions |
| "MWDATCore not found" | Add Meta DAT SDK via Swift Package Manager |
| "Bundle identifier already in use" | Change PRODUCT_BUNDLE_IDENTIFIER in Config.xcconfig |

### Runtime Errors

| Error | Solution |
|-------|----------|
| "Microphone access denied" | Grant permission in iOS Settings → OpenVision |
| "WebSocket connection failed" | Check your OpenClaw URL and network connection |
| "Invalid API key" | Verify your Gemini API key in Settings |
| "Wake word not working" | Grant speech recognition permission |

### Connection Issues

| Issue | Solution |
|-------|----------|
| OpenClaw disconnects frequently | Check network stability; auto-reconnect will retry 12 times |
| Gemini audio choppy | Ensure stable WiFi connection |
| Glasses not streaming | Toggle streaming off/on in Glasses settings |

---

## Development Tips

### Running on Simulator

The iOS Simulator doesn't support:
- Bluetooth (no glasses connection)
- Some audio features

Use a physical device for full testing.

### Debug Logging

Enable verbose logging in Xcode console:
- Filter by `[OpenClaw]`, `[Gemini]`, `[Voice]`, `[Glasses]`

### Hot Reloading Settings

Settings changes are applied immediately without restart. WebSocket sessions receive updated configuration in real-time.

---

## Getting Help

- **GitHub Issues**: Report bugs or request features
- **Discussions**: Ask questions and share tips
- **CLAUDE.md**: Technical documentation for AI assistants

---

## Next Steps

- Read the [Contributing Guide](CONTRIBUTING.md) to contribute
- Check out [OpenClaw](https://github.com/openclaw/openclaw) for tool development
- Explore [Gemini Live API](https://ai.google.dev/gemini-api/docs/live-api) capabilities
