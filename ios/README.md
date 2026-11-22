# iWalk iOS + watchOS

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). `iWalk.xcodeproj` is git-ignored, so regenerate it after pulling or after adding files.

## Setup
1. Install XcodeGen once:
   ```bash
   brew install xcodegen
   ```
2. Create your local config (git-ignored), then set `DEVELOPMENT_TEAM`, `BUNDLE_PREFIX` and, once the server is up, `IWALK_BASE_URL` / `IWALK_API_KEY`:
   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```
3. Generate and open:
   ```bash
   xcodegen generate && open iWalk.xcodeproj
   ```
4. Run the `iWalk` scheme on your iPhone. Xcode installs the Watch app with it. Keep the phone cabled and the Watch on the same Wi-Fi.

Free-account notes: don't change `BUNDLE_PREFIX` once set (10 App IDs per 7 days), and re-run from Xcode every 7 days.

## Targets
| Target | What it is |
|---|---|
| `iWalk` | iOS app: planner, saved routes, live tracking, history, sync debug |
| `iWalkWidgets` | Live Activity (lock screen + Dynamic Island) |
| `iWalkWatch` | watchOS app: workouts with HealthKit, route view, sync |
| `iWalkCore` (package) | `iWalkCore`: models, Valhalla client, geometry, sync payloads. `iWalkStore`: SwiftData models |

## Command-line builds
```bash
xcodebuild -project iWalk.xcodeproj -scheme iWalk -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Notes
- On iPhone, `HKLiveWorkoutBuilder` / `associatedWorkoutBuilder()` need iOS 26. iWalk targets iOS 18, so the Watch sends live stats to the phone itself (`MirrorUpdate` over `sendToRemoteWorkoutSession`).
- Apple has no walking directions in Mombasa. The Apple fallback planner only helps where Apple has coverage; plan with the Valhalla server.
