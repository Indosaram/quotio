# Suggested commands for Quotio

- Debug build: `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build`
- Release build: `./scripts/build.sh`
- Full release pipeline: `./scripts/release.sh`
- Manual app run: open `Quotio.xcodeproj` in Xcode and run the `Quotio` scheme
- Optional compile-error quick check: `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build 2>&1 | head -50`

No automated tests are documented in the repo; verification is primarily manual/Xcode build-based.
