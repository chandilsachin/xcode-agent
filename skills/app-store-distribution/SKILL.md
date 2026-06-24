---
name: app-store-distribution
description: Archive, export, and upload an iOS app build to App Store Connect
---

# App Store Distribution

Prepare and ship an iOS build to App Store Connect / TestFlight.

## Prerequisites
- Full Xcode installed and selected (`xcode doctor` is green).
- A valid Distribution signing certificate and provisioning profile.
- An app record created in App Store Connect.

## Steps
1. Bump the build number (`CFBundleVersion`) and marketing version
   (`CFBundleShortVersionString`).
2. Archive:
   `xcodebuild -workspace App.xcworkspace -scheme App -configuration Release \
     -archivePath build/App.xcarchive archive`
3. Export with an `ExportOptions.plist` (`method: app-store`):
   `xcodebuild -exportArchive -archivePath build/App.xcarchive \
     -exportOptionsPlist ExportOptions.plist -exportPath build/export`
4. Upload:
   `xcrun altool --upload-app -f build/export/App.ipa -t ios \
     --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>`
   (or use `xcrun notarytool` / Transporter as appropriate).

## Verify
- The build appears in App Store Connect → TestFlight within a few minutes.
- Processing completes without ITMS errors.
