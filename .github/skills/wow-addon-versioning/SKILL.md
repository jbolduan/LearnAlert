---
name: wow-addon-versioning
description: 'Determine and apply the correct version bump for a World of Warcraft addon. Use when: updating the version, bumping the version, preparing a release, determining what version to use, incrementing the version number, semantic versioning for a WoW addon.'
argument-hint: 'Optionally describe the changes made (e.g., "added new feature" or "fixed a bug")'
---

# WoW Addon Versioning

## When to Use

Invoke this skill whenever a code change requires updating the addon version across all `.toc` files and `README.md`.

## Rules

- Version is defined in the `## Version:` field of each `.toc` file at the root of the repository.
- Use standard semantic versioning: `MAJOR.MINOR.PATCH`.
- Do **not** increment the version multiple times within a session. Apply one bump based on the highest-impact change in the full diff since the last tag.
- All `.toc` files must be updated to the **same** version.
- When the version changes, also update any version reference in `README.md`.

## Procedure

1. Find all `.toc` files at the root of the repository:
   ```
   Get-ChildItem -Path . -MaxDepth 1 -Filter "*.toc"
   ```
2. Run `git tag --list --sort=-version:refname` to find the most recently tagged version (e.g. `1.0.5`).
3. Run `git diff <tag>` to review **all** changes since that tag, including working tree and session changes.
4. Categorize the **full set of changes together** and apply a **single increment**:

| Change Type | Bump | Example |
|---|---|---|
| Bug fixes and minor corrections only, no new functionality | **PATCH** (`1.0.x`) | Fix nil check |
| Any new features or functionality added in a backward-compatible way | **MINOR** (`1.x.0`) | Add new command; resets PATCH to 0 |
| Breaking changes, major rewrites, or SavedVariables schema migrations | **MAJOR** (`x.0.0`) | Schema migration; resets MINOR and PATCH to 0 |

5. Update `## Version:` in **every** `.toc` file found in step 1 to the new version.
6. Find and update any matching version string in `README.md`.
