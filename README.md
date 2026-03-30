# Workout Bridge

Workout Bridge is a small iPhone app for enthusiasts who want to move Apple Health workout and wellness data into [Intervals.icu](https://intervals.icu/) without relying on a commercial sync product.

It reads workouts from HealthKit, prepares TCX exports on-device, uploads them to Intervals.icu, and can also push daily wellness data such as resting heart rate, HRV, sleep, steps, body metrics, blood pressure, nutrition, and related metrics when available.

## What it does

- Imports workouts from Apple Health / Apple Watch through HealthKit
- Uploads workout files to Intervals.icu
- Uploads extra streams such as ground contact time, vertical oscillation, and optional flights climbed
- Keeps a local workout status history so you can see what synced and what did not
- Supports manual and automatic sync flows
- Uploads daily wellness records separately from workout uploads

## What this app is

- A personal side-project style utility for hobbyists and data nerds
- Not an App Store product
- Not a polished consumer sync service
- Not affiliated with Apple or Intervals.icu

## Setup

1. Open `intervals watch sync.xcodeproj` in Xcode.
2. Select your own Apple development team in Signing & Capabilities if you want to run it on a device.
3. Build and run on iPhone.
4. Grant Health access.
5. Enter your Intervals.icu API key in the app settings. The key is stored locally in the device Keychain.
6. Optionally set athlete ID and custom stream codes, then sync workouts or wellness data.

## What is committed

This repository should keep the usual shareable iOS project files:

- Swift source files
- Asset catalogs
- `Info.plist`
- entitlements
- the Xcode project file
- this README

## What is ignored

The `.gitignore` excludes the usual machine-specific or disposable Xcode files:

- `xcuserdata` and other per-user Xcode UI state
- `DerivedData` and local build outputs
- SwiftPM local caches
- macOS `.DS_Store` files
- optional local secret files if someone adds them later

## Notes

- The Intervals.icu API key is not stored in the repository.
- Health data stays on-device until you explicitly grant permission and trigger sync behavior.
- This project is currently aimed at direct Xcode usage, not App Store distribution.
