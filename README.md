# LearnAlert

A World of Warcraft addon that opens a clickable list when there are mounts, toys, transmog items, follower curios, profession knowledge items, battle pets, or housing decor items in your bags or bank that you can use or learn.

## Features

- **Clickable Learnable List**: Opens a clickable list of learnable items when items are found
- **Ignore Items**: Right-click any row to suppress that item from the alert; restore it with `/la unignore <id>`
- **Settings Panel**: Configure LearnAlert in the built-in WoW Settings UI, including general toggles (enable addon, show alert, verbose output) and per-item-type detection toggles
- **Warning Auto-confirm Options**: Optional separate toggles to auto-confirm bind-to-you and non-refundable warnings only for items used from LearnAlert rows
- **Ignored Items Manager**: In the Settings panel, view all ignored items, remove them with a button, or drag bag items into the drop box to add them to the ignore list
- **Custom Items Manager**: In the Settings panel, manage custom follower-curio tracked items (seeded with Rattling Bag o' Gold), remove entries, or drag bag items into the drop box to add more

## How It Works

1. The addon automatically scans your bags every 2 seconds
2. When you open your bank (character bank, reagent bank, or warbank), it automatically scans those containers too
3. When it finds mounts, toys, transmog items, follower curios, profession knowledge items, battle pets, or housing decor items, it opens a clickable list
4. Click an entry in the list to use and learn that item from its bag slot (equippable transmog gear uses a swap-back flow to restore your previously equipped item)
5. Right-click an entry to ignore it; the item will no longer appear in the alert until you restore it with `/la unignore <id>`
6. The list updates in real-time as items are learned or moved

## Commands

| Command | Description |
| ------- | ----------- |
| `/la` or `/learnalert` | Show help |
| `/la show` | Show the learnable-items list |
| `/la hide` | Hide the learnable-items list |
| `/la toggle` | Toggle the learnable-items list |
| `/la list` or `/la l` | List learnable items in chat |
| `/la check` or `/la c` | Check for learnable items now |
| `/la verbose` or `/la v` | Toggle verbose messages |
| `/la settings` | Open the LearnAlert settings panel |
| `/la debugmount` or `/la dm` | Show mount detection diagnostics for all items in bags |
| `/la debugpet` or `/la dp` | Show pet detection diagnostics for all items in bags |
| `/la debugtoy` or `/la dt` | Show toy detection diagnostics for all items in bags |
| `/la debugtransmog` or `/la dtr` | Show transmog detection diagnostics for all items in bags |
| `/la debugcurio` or `/la dcu` | Show follower curio detection diagnostics for all items in bags |
| `/la debugknowledge` or `/la dk` | Show profession knowledge detection diagnostics for all items in bags |
| `/la debugdecor` or `/la dd` | Show housing decor detection diagnostics for all items in bags |
| `/la debugbank` or `/la db` | Show bank inventory and detection status (requires bank to be open) |
| `/la debugclick` or `/la dc` | Toggle click payload debug logging for learnable-item rows (chat + copyable window) |
| `/la ignorelist` or `/la il` | List all currently ignored items |
| `/la unignore <id>` or `/la ui <id>` | Restore an ignored item by its item ID |
| `/la clearignored` or `/la ci` | Clear all ignored items |

## Installation

1. Download the addon
2. Extract to: `World of Warcraft\_retail_\Interface\AddOns\LearnAlert`
3. Restart WoW or type `/reload`

## Usage

1. The addon automatically runs in the background
2. A clickable list opens when learnable items are found in your bags or bank
3. Use `/la list` to see detailed information about learnable items
4. Click items in your inventory to learn them
5. The list hides automatically when no more learnable items are found

## Configuration

- **Settings panel**: Open the in-game Settings screen and find **LearnAlert** in the AddOns section, or type `/la settings`. In **General**, toggle addon enable state, alert visibility, verbose output, and warning auto-confirm options (bind warning and non-refundable warning). Warning auto-confirm only applies to items used from LearnAlert rows. In **Item Type Detection**, toggle each type (Mounts, Toys, Transmog, Follower Curios, Profession Knowledge, Battle Pets, Housing Decor).
- **Ignored Items section**: In LearnAlert settings, open the **Ignored Items** sub-page to see every ignored item, click **Remove** to unignore, or drag bag items to the drop target to add them.
- **Custom Items section**: In LearnAlert settings, open the **Custom Items** sub-page to see always-tracked custom follower-curio items, click **Remove** to stop tracking one, or drag bag items to add more.
- **Drag the list window** to reposition it anywhere on your screen
- **Toggle on/off** with `/la toggle`
- **Adjust check frequency** by editing the addon settings
- **Enable/disable verbose messages** with `/la verbose`

## Supported Items

- **Mounts**: Any mount item that can be learned by your character
- **Toys**: Any toy item in the toy collection system
- **Transmog**: Equippable armor/weapon items and Ensemble/Arsenal containers with uncollected appearances (based on tooltip transmog state). Clickable transmog gear uses a swap-back flow: LearnAlert equips the item to learn the appearance, then immediately re-equips your previously equipped item in that slot.
- **Follower Curios**: Follower curio consumables and related items detected from tooltip/use text (includes explicit tracking for Rattling Bag o' Gold)
- **Profession Knowledge**: Profession knowledge consumables and related items detected from tooltip/use text
- **Battle Pets**: Any caged battle pet that you haven't collected yet
- **Housing Decor**: Any housing decor item (always shown as repeatable)

Housing decor is treated as repeatable content and always appears in LearnAlert when detected in bags/bank.

## Note

- Bank scanning automatically activates when you open the bank window
- Scans character bank (bags 5-12), reagent bank, and warbank (account-wide bank)
- The addon respects the "do not disturb" feature during combat
- Item detection uses the game's own collection systems

## License

MIT License - Feel free to modify and distribute!
