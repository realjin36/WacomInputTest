# Wacom macOS Multi-Touch vendor sources

This directory contains source material needed to develop the macOS touch
bridge. It intentionally does not contain the WacomMultiTouch framework
binary. The application must weak-link or dynamically load the framework
installed by the Wacom tablet driver at runtime.

## Official sample

- Repository: https://github.com/Wacom-Developer/wacom-device-kit-macos-multi-touch
- Commit: `99ed97ba104c14034be302ce2193931f901c9fce`
- Commit date: 2024-12-19
- Local copy: `sample/`
- License statement: the upstream `README.md` identifies the sample as MIT
  licensed. Upstream third-party notice: `sample/THIRD-PARTY.md`.

The nested Git repository metadata was not copied. The sample source,
resources, Xcode project, entitlements, and upstream documentation are kept
unchanged.

## API headers

The following headers were copied from the framework installed by Wacom
Tablet Driver 6.4.13-4 (`CFBundleVersion` `6.4.13f4`) on 2026-08-15:

- Source: `/Library/Frameworks/WacomMultiTouch.framework/Headers/WacomMultiTouch.h`
- Copy: `include/WacomMultiTouch.h`
- SHA-256: `5a824d0f5aaaa68cd3d2b92d5dd4ee7c1212dc4740857a3149d4cd7caf10d732`
- Source: `/Library/Frameworks/WacomMultiTouch.framework/Headers/WacomMultiTouchTypes.h`
- Copy: `include/WacomMultiTouchTypes.h`
- SHA-256: `b2eab753012c0a7d3c983a5471490ddbaa2ad97b060bc15711e67c3f9e7f0c9d`

These headers declare Multi-Touch API version 4. Their original Wacom
copyright notices are preserved.

## Runtime framework

Expected runtime location:

`/Library/Frameworks/WacomMultiTouch.framework`

The installed framework is a universal `arm64`/`x86_64` binary. Do not copy
it into this vendor directory or embed it in the application bundle.
