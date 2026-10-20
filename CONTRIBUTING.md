# Contributing to PreviewMD

Thanks for helping out. Bug reports, small fixes, and focused improvements are all welcome.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security issues go through [SECURITY.md](SECURITY.md), not public issues.
- By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build and test

Requirements and details are in the [README](README.md#build-from-source). In short:

```bash
swift build                # debug build
swift run PreviewMD        # launch the app
swift test                 # unit tests (needs full Xcode for XCTest)
make app                   # universal dist/PreviewMD.app (needs full Xcode)
make app ARCHS=arm64       # single-arch app (Command Line Tools are enough)
make install-ql            # install to ~/Applications and register Quick Look
```

CI runs the release build, the tests, and a universal `make app` on every push and pull request.

## Pull requests

- Branch from `develop` and target `develop` with your PR.
- Keep PRs small and about one thing; split unrelated changes.
- Add or update tests in `Tests/MdReaderCoreTests` when you change `MdReaderCore`.
- Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
- Follow the surrounding code style. No new dependencies without discussion first.
- Keep the app private by design: no analytics, telemetry, or network requests of its own.
- Updating a bundled JavaScript library? Update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) too.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
