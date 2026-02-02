# GlucoBar

A macOS menu bar app that displays real-time blood glucose readings from Dexcom CGM sensors via the Dexcom Share API.

<img width="353" height="437" alt="Screenshot 2026-02-02 at 16 42 37" src="https://github.com/user-attachments/assets/9c0f2e87-bbd0-4a96-ba1d-165d05e0939b" />

## Features

- **Real-time glucose display** in the menu bar (e.g., "6.0 →")
- **Trend arrows** showing glucose direction (↑↑, ↑, ↗, →, ↘, ↓, ↓↓)
- **Color-coded values**:
  - 🟢 Green: In range (4.0-10.0 mmol/L)
  - 🟡 Yellow: Warning (3.3-4.0 or 10.0-13.9 mmol/L)
  - 🔴 Red: Urgent (<3.3 or >13.9 mmol/L)
- **3-hour glucose graph** in the popover
- **Launch at Login** option
- **Automatic refresh** every 5 minutes

## Requirements

- macOS 14.0 (Sonoma) or later
- Dexcom CGM sensor (G6, G7, ONE, ONE+)
- Dexcom Share enabled with at least one follower

## Installation

### Option 1: Download Release
Download the latest `GlucoBar.app` from the [Releases](../../releases) page.

### Option 2: Build from Source
1. Clone this repository
2. Open `GlucoBar/GlucoBar.xcodeproj` in Xcode
3. Build and run (⌘R)

## Setup

1. Launch GlucoBar
2. Click the `---` in your menu bar
3. Click "Set Up Dexcom"
4. Enter your Dexcom credentials:
   - **Username**: Your Dexcom account email or phone number (the one with the CGM sensor)
   - **Password**: Your Dexcom password
   - **Region**: Select US or Non-US based on your location
5. Click Connect

### Important Notes

- Use the credentials for the account that **has the CGM sensor** (the sharer), not a follower account
- Dexcom Share must be enabled in your Dexcom mobile app
- You must have at least one follower set up for Share to work

## How It Works

GlucoBar uses the unofficial Dexcom Share API to fetch glucose readings. This is the same API used by the Dexcom Follow app. The app:

1. Authenticates with Dexcom Share servers
2. Fetches glucose readings every 5 minutes
3. Displays the latest reading in your menu bar
4. Shows a 3-hour history graph when you click the icon

## Privacy

- Your credentials are stored securely in the macOS Keychain
- No data is sent anywhere except to Dexcom's servers
- The app runs entirely locally on your Mac

## Troubleshooting

**"Invalid credentials" error**
- Make sure you're using the account that has the CGM sensor, not a follower account
- Try logging into [share.dexcom.com](https://share.dexcom.com) or [shareous1.dexcom.com](https://shareous1.dexcom.com) to verify your credentials

**"No data available"**
- Check that your CGM sensor is active and transmitting
- Verify Dexcom Share is enabled in the Dexcom mobile app
- Make sure you have at least one follower set up

**App shows "---"**
- The app is still loading or waiting for data
- Click the refresh button to manually fetch readings

## License

MIT License - feel free to use, modify, and distribute.

## Disclaimer

This app is not affiliated with or endorsed by Dexcom, Inc. It uses an unofficial API that may change without notice. Use at your own risk and always verify glucose readings with your official Dexcom app or a blood glucose meter for medical decisions.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
