# Copilot Instructions for LearnAlert

## Versioning

The addon version is defined in the `## Version:` field of `LearnAlert.toc`. Use standard semantic versioning (`MAJOR.MINOR.PATCH`):

- **PATCH** (`1.0.x`) - Bug fixes and minor corrections with no new functionality.
- **MINOR** (`1.x.0`) - New features or item-type detection added in a backward-compatible way. Resets PATCH to 0.
- **MAJOR** (`x.0.0`) - Breaking changes, major rewrites, or SavedVariables schema migrations that are not backward-compatible. Resets MINOR and PATCH to 0.

When making any code change, increment the appropriate version component in `LearnAlert.toc` and update the version referenced in `README.md` if it appears there.

## Build and Deploy

- **Never automatically execute `build\deploy.ps1`** - This script deploys files to the user's WoW installation and should only be run when explicitly requested by the user.
- When the user asks to deploy, remind them to run the deploy script manually rather than executing it automatically.

## Documentation Maintenance

- **Keep `README.md` up to date** - When adding new features, commands, or settings, update the README.md to reflect those changes.
- **Keep this instructions file up to date** - When adding new key files, changing project structure, or establishing new development guidelines, update this copilot-instructions.md file.
- **Limit emoji usage** - Avoid using emojis in the README.md and other documentation files. Use plain text formatting instead. Note: The LearnAlert.lua code contains emojis for UI display (🔔 for mounts, 🎁 for toys) - these are intentional game UI elements and should be kept.
- **Ensure markdown passes linting** - All markdown files must pass linter checks with no errors or warnings. This includes proper heading hierarchy, consistent list formatting, no trailing spaces, blank lines around code blocks, and proper link syntax.

## Project Overview

This is a World of Warcraft addon that detects learnable mounts and toys in the player's bags and bank, displaying a bouncing alert when such items are found.

## Key Files

- `LearnAlert.lua` - Main addon code
- `LearnAlert.toc` - Addon metadata/manifest
- `README.md` - User documentation
- `build\deploy.ps1` - Deployment script (DO NOT AUTO-EXECUTE)
- `.instructions.md` - Architecture and development guidelines (for AI assistant reference)
- `.prompt.md` - AI assistant guidance for feature implementation and debugging
- `.github\copilot-instructions.md` - This file (Copilot workspace instructions)

## Feature Development Guidelines

### Core Functionality

- The addon's primary function is detecting learnable items and displaying alerts
- Maintain backward compatibility with existing SavedVariables format
- All changes must work within WoW's combat lockdown restrictions

### UI/UX Considerations

- The alert frame should remain visually distinctive through animations
- Commands should follow the established pattern: `/la [command] [args]`
- Chat output should be prefixed with `|cff00a0ff[LearnAlert]|r` for consistency

### Testing Requirements

After any code modifications:
1. Verify addon loads without errors using `/reload`
2. Test all slash commands with `/la help`
3. Verify alert displays correctly with test items
4. Check that position/settings persist across reload
5. Confirm no errors in WoW's console

## API Usage

- Uses WoW API exclusively (no external libraries)
- Compatible with WoW patch 12.0.1 and later (current interface version)
- Key APIs: `C_MountJournal`, `C_ToyBox`, `C_Container`, `C_Item`, `C_Timer`

## Code Style

- Use snake_case for all variables and local functions
- Use descriptive names starting with verbs (Create, Update, Scan, etc.)
- Add comments for complex logic or non-obvious game API usage
- Keep functions focused on single responsibilities
- Indent with 4 spaces (consistent with original code)

## Common Tasks

### Adding New Item Types

1. Create a cache function (e.g., `CacheLearnedPerks()`)
2. Add detection logic to `ScanForLearnableItems()`
3. Update `UpdateAlert()` to display new item type
4. Add slash command if needed
5. Update README.md with new feature

### Modifying Alert Appearance

1. Edit `CreateAlertFrame()` for frame styling
2. Edit animation in the alert display logic
3. Test frame rendering and positioning
4. Update README.md with visual changes if significant

### Performance Optimization

- Profile using WoW's built-in /console showfps command
- Cache results when appropriate
- Avoid per-frame iterations - use event-driven updates
- Test with large inventories (100+ items)

## SavedVariables Schema

LearnAlertDB contains:
```lua
{
    enabled = boolean,        -- Addon active state
    showAlert = boolean,      -- Alert display state
    alertX = number,          -- Alert frame X position
    alertY = number,          -- Alert frame Y position
    verbose = boolean,        -- Console output verbosity
    alertScale = number,      -- UI scale multiplier (1.0 = normal)
    checkInterval = number    -- Seconds between auto-checks (default 2)
}
```

Never add breaking changes to this schema without migration logic.

## Deployment Process

For users deploying the addon:
1. Ensure WoW is not running
2. Run: `.\build\deploy.ps1` (or specify `-GameVersion retail/classic/all`)
3. Start WoW or use `/reload` to refresh

## Troubleshooting

Common issues and solutions:

- **Alert not appearing**: Check `/la show` status, verify items exist, test with `/la check`
- **Bank scan not working**: Reagent bank must be open and unlocked
- **Items not detecting**: Ensure items are in bags 0-4 or reagent bank slots
- **High CPU usage**: Check timer frequency in `LearnAlertDB.checkInterval`

## Known Limitations

- Bank scanning requires the reagent bank to be open and unlocked
- Cannot perform any UI modifications during combat (WoW API restriction)
- Item detection depends entirely on WoW's collection systems
- Animation performance varies based on system specs and UI scale
