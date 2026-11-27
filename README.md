# Rabbit Ears for Apple
The macOS, iOS and Apple TV apps for [Rabbit Ears](https://github.com/legitimate-enterprises/rabbit-ears),
a self-hosted open-source media server. They are for anyone who runs a
Rabbit Ears server or is invited to one.

------------------------------------------------------------------------
## How It Works
- Three Swift apps over one shared kit. Each app compiles the kit and the
  API package into its own framework and adds its platform's views.
- The apps talk only to a Rabbit Ears server, through that server's REST
  API. `openapi.yaml` is the server's spec at the release the apps are built
  against. `make spec VERSION=<server version>` replaces it with another
  release's and regenerates the API package; `make lint` fails when the two
  disagree.
- The apps render from a local SQLite replica kept current by the server's
  sync API. A change the server can replay applies there at once and queues
  until the server takes it, so it works offline.
- The Xcode projects are generated from each app's `project.yaml` by
  `make deps` and are not committed.
- The kit reads SQLite through GRDB, built by `make deps` under `build/grdb`
  against the server's own SQLite release, never the system's. Both are
  pinned in `apple/scripts/grdb-source.sh`.
- Tests that need a server build one from its repository at the tag for
  `openapi.yaml`'s version, cloned under `build/`. Set
  `RABBIT_EARS_SERVER_SRC` to a checkout of that repository to use it
  instead.
- Every green CI run on `main` signs all three apps and uploads them to
  App Store Connect, where they land in TestFlight, as version `M.m.N` and
  build `N`: `M.m` from `apple/version.yaml`, and `N` the commit's ordinal
  on `main`. `make deploy` tags `main` `v<M.m.N>` once CI is green there;
  the tag submits nothing.

Limitations: an upload has no rollback, and promotion from TestFlight to
the App Store is done by hand in App Store Connect.

------------------------------------------------------------------------
## Requirements
- macOS with Homebrew, Xcode 27 and `make`.
- iOS and Apple TV tests: an iPhone and a tvOS simulator runtime.
- Tests that run a server: Go and `ffmpeg`, which those targets install,
  and Python 3, `jq` and `git`.
- `make deps` installs the rest.

------------------------------------------------------------------------
## Repository
- `apple/` Common Swift kit, its tests, the API package and release scripts.
- `macos/` macOS app.
- `ios/` iOS app.
- `tvos/` Apple TV app.
- `scripts/` release, CI and demo server tooling.
- `assets/` App Store listing and screenshots.

------------------------------------------------------------------------
## Simulator UI tests and store screenshots
`make -C ios test-ui` and `make -C tvos test-ui` exercise sign-in, profile
selection, movie browsing and advancing video playback. Both run in CI and
through root `make test`. Beyond the requirements of tests that run a server,
they need iOS and tvOS 27+ simulator runtimes, a logged-in macOS desktop
session and `ffprobe`. Missing prerequisites or skipped tests fail the run.

`make screenshots` runs those flows and exports three anonymous images per
client: profiles, home and movie details. Each run creates its own simulator
and local server, with fictional movies, original landscape artwork and demo
profiles. It never connects to a personal server or reuses a signed-in device,
so no credentials or image redaction are needed.

The iPhone images are 1206 × 2622; Apple TV images are 3840 × 2160. Each client
validates its complete set before replacing its directory under
`assets/apple-app-store/`; failed tests or invalid exports keep the previous
set. Logs and XCTest result bundles stay under that client's `build/ui-tests/`.

`make screenshots SCREENSHOT_CLIENTS="ios"` selects a subset; the root target
only runs each selected client's own `screenshots` target. macOS has none. To
add a platform, implement that target, with its store's export validation, in
the platform's directory, then add it to `SCREENSHOT_CLIENTS`.

------------------------------------------------------------------------
*End of README*
