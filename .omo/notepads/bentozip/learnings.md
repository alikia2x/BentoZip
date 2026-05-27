# Learnings

## Session started 2026-05-27
- Project is a fresh Xcode 26.1 SwiftUI macOS app template
- MACOSX_DEPLOYMENT_TARGET needs to be set to 14.0 across all targets
- ENABLE_APP_SANDBOX = YES must be changed to NO
- Uses PBXFileSystemSynchronizedRootGroup (Xcode 16+ format) - directories added under BentoZip/ are auto-discovered
- No CODE_SIGN_ENTITLEMENTS set in project.pbxproj (no entitlement file to clean up)
- Info.plist is empty (default generated file, no custom entitlements)
