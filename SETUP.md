# OpenVision Setup Guide

Complete step-by-step guide to set up and run OpenVision.

## Prerequisites

### Required
- **Mac** with macOS 13.0 (Ventura) or later
- **Xcode 15.0** or later
- **iOS device** running iOS 16.0+ (simulator doesn't support Bluetooth)
- **Apple Developer Account** (free or paid)

### Optional
- **Meta Ray-Ban smart glasses** - For glasses integration (iPhone camera works as fallback)
- **OpenClaw instance** - For OpenClaw AI backend
- **Gemini API key** - For Gemini Live AI backend

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/user/OpenVision.git
cd OpenVision/meta-vision
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

### 2.4 Get Your Meta App ID (For Glasses)

If you want to use Meta Ray-Ban glasses:

1. Go to [developer.meta.com](https://developer.meta.com)
2. Create a new app or select existing
3. Add the **Meta Wearables** product
4. Copy your App ID from the dashboard
5. Add it to `Config.xcconfig`

**Note:** You can skip this if testing with iPhone camera only.

---

## Step 3: Add Meta DAT SDK

The Meta Wearables Device Access Toolkit (DAT) SDK is required for glasses integration.

### Option A: Swift Package Manager (Recommended)

1. Open `OpenVision.xcodeproj` in Xcode
2. Go to **File → Add Package Dependencies**
3. Enter URL: `https://github.com/anthropics/meta-wearables-dat-ios`
4. Add these packages:
   - `MWDATCore`
   - `MWDATCamera`

### Option B: Manual Download

1. Download from [Meta GitHub](https://github.com/facebook/meta-wearables-dat-ios)
2. Drag the frameworks into your project
3. Ensure "Copy items if needed" is checked

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

1. Connect your iOS device via USB
2. Select your device as the run destination
3. Press **Cmd+R** to build and run
4. Trust the developer certificate on your device if prompted:
   - Go to **Settings → General → VPN & Device Management**
   - Tap your developer app and trust it

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
