@~/.agents/instructions/agents.md
@./README.md

- Release tags: each app is tagged on its own, `<component>-v<version>`, at
  the version its `project.yaml` states, by `make deploy <component>...`.
- macOS distribution: the Mac app is sandboxed and goes to the App Store as
  the iOS and Apple TV apps do; no DMG, notarization or Sparkle.
- Each top-level directory owns its tooling; the root `Makefile` fans the
  standard targets out to them. `apple/` is the kit, its tests and the API
  package, compiled into all three apps.
- Red-green: write the failing test first, then the minimum code. Unit and
  simulator UI tests are both first class. Judge coverage by the defects
  caught at seams: the API boundary, device capability parsing, playback
  and downloads against a real server.
- Comments explain intent, invariants and side effects of non-obvious code.
  Never what the code does, never history or rationale.
- No Markdown beyond `README.md`, `AGENTS.md` and `memory.md`. No ADRs, no
  decision logs.
- `openapi.yaml` is the server's file, replaced whole by `make spec` and
  never edited here. Its `info.version` is the server release the apps are
  built against and tested with, and the apps may assume that API.
  `apple/api/Sources/RabbitEarsAPI/Generated` is generated from it by
  `make generate`.
- An app's version is a counter: `MARKETING_VERSION` in its `project.yaml`,
  one higher in the first change after its last release.
- Store temporal values as UTC instants.
