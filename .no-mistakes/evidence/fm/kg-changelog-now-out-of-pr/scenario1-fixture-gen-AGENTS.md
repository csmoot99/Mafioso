# gen project rules
## Knowledge map upkeep
- An ordinary PR never edits `ai-map/CHANGELOG.md` or `ai-map/NOW.md`.
- `ai-map/CHANGELOG.md` is generated from git history by `scripts/gen-changelog.sh`; nobody hand-writes entries.
- Only an integration PR (one that combines several PRs) overwrites `ai-map/NOW.md`, replacing it whole with the current state, max 40 lines.
