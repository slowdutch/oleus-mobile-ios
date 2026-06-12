# OleusMobile (iOS)

Crash reporting, sessions, breadcrumbs, and MetricKit reconciliation for the Oleus platform.

## Install (Swift Package Manager)

Published as a standalone repo (mirrored from the Bopser monorepo via
`git subtree split --prefix sdk/packages/ios/OleusMobile`; develop here, push splits on release):

```swift
.package(url: "https://github.com/slowdutch/oleus-mobile-ios.git", from: "1.0.0")
```

## Usage

```swift
import OleusMobile

// As early as possible in AppDelegate/App init:
OleusMobile.start(
    endpoint: URL(string: "https://oleus.example.com/otlp")!,
    service: "rondo-ios",
    apiKey: ProcessInfo.processInfo.environment["OLEUS_INGEST_KEY_IOS"] ?? "<key>"
)

OleusMobile.addBreadcrumb(message: "EventDetail opened", category: "navigation")
OleusMobile.capture(error: error, context: ["flow": "checkout"])
```

## How crash capture works

1. **At crash time** the C target (`OleusCrashCore`) handles
   SIGABRT/SEGV/BUS/ILL/TRAP/FPE on a sigaltstack using only
   async-signal-safe calls: frame-pointer walk from the *crashed* thread's
   ucontext, raw addresses written via `write(2)`. No allocation, no ObjC
   runtime, no JSON in the signal context. Previous handlers are chained.
2. **On next launch** the Swift layer pairs the addresses with the persisted
   dyld binary-image list (UUID + load address per image), breadcrumbs, and
   the previous session id, then ships the report through the disk-backed
   batch queue with the `Authorization: Bearer` ingest key.
3. **Server side** symbolicates against dSYMs uploaded per release:

```bash
# in your archive/CI step
zip -r dSYMs.zip "$ARCHIVE_PATH/dSYMs"
curl -F "service=rondo-ios" -F "version=$MARKETING_VERSION+$BUILD_NUMBER" \
     -F "dsyms=@dSYMs.zip" https://oleus.example.com/api/symbols/dsym
```

NSExceptions are captured in a normal (non-signal) context with both symbol
and raw-address stacks. MetricKit `MXCrashDiagnostic`/`MXHangDiagnostic`
payloads are shipped tagged `crash_source: metrickit` for reconciliation —
run one release cycle comparing both sources before retiring the old reporter.

Sessions (`session_start`/`session_end` with `release`, `session.id`,
`device.id`) power the crash-free-sessions and release-adoption views.
