## Global Constraints

- Root causes, not patches. TDD: a failing test first for every behaviour change; app-only AppKit changes that have no
  test seam are verified by building and by eye, and say so in the report.
- Docs (README, specs) updated in the same commit as the behaviour they describe. Australian English.
- Never run restic against the owner's B2 repository. Never read the Keychain or
  `~/Library/Application Support/com.jaydenkerr.restorey*` (logs and state are read-only, and only when a task says).
- No CPU-load or repeated test loops on this Mac. Per task: the filtered tests plus the package suite it touches;
  `scripts/ci.sh` once at the end of the branch.
- Agent status paths stay disk-free (`StatusPathPurityTests`).
- Commits: no Co-Authored-By or session lines.

## Project notes for every task
- Repo: /Users/kerrj/Documents/Development/restorey, branch v0.1.2-fixes (work on it directly; no new branches or worktrees).
- Swift 6.4, macOS 27. RestoreyCore SPM package has targets RestoreyCore and AgentCore; app built by XcodeGen
  (`project.yml`). Build the app with: `xcodegen generate --quiet && xcodebuild -project Restorey.xcodeproj -scheme Restorey
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData-unsigned CODE_SIGNING_ALLOWED=NO build
  > build/xcodebuild.log 2>&1; tail -5 build/xcodebuild.log`. Do NOT run `scripts/ci.sh` or `scripts/install-dev.sh` — the controller runs them at the end.
- The Mac is often heavily loaded: run filtered tests while iterating, then the package suite once before committing.
- Commit messages: plain subject + optional body. NO Co-Authored-By, NO Claude-Session or other trailers.
- TODO.md is gitignored; never `git add` it. Never `git add -A`; add the files you changed.
- Australian English in docs, comments and UI text (e.g. "behaviour", "colour", "organise").
- Docs live in README.md and docs/superpowers/specs/*. Update the ones your task names in the same commit.
