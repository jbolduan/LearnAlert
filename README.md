# LearnAlert

A World of Warcraft addon that opens a clickable list when there are mounts, toys, battle pets, or housing decor items in your bags or bank that you can learn.

## Features

- **Clickable Learnable List**: Opens a clickable list of learnable items when items are found
- **Mount Detection**: Automatically detects mounts in bags/bank that you haven't learned
- **Toy Detection**: Automatically detects toys in bags/bank that you haven't collected
- **Battle Pet Detection**: Automatically detects battle pets in bags/bank that you haven't collected
- **Housing Decor Detection**: Automatically detects housing decor items in bags/bank that you haven't collected
- **Bank Support**: Automatically scans character bank, reagent bank, and warbank when opened
- **Auto-Check**: Periodically checks for learnable items
- **Moveable List Window**: Drag the list window anywhere on your screen
- **Verbose Logging**: Get detailed messages about found items

## How It Works

1. The addon automatically scans your bags every 2 seconds
2. When you open your bank (character bank, reagent bank, or warbank), it automatically scans those containers too
3. When it finds mounts, toys, battle pets, or housing decor items, it opens a clickable list
4. Click an entry in the list to use and learn that item from its bag slot
5. The list updates in real-time as items are learned or moved

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
| `/la debugmount` or `/la dm` | Show mount detection diagnostics for all items in bags |
| `/la debugpet` or `/la dp` | Show pet detection diagnostics for all items in bags |
| `/la debugtoy` or `/la dt` | Show toy detection diagnostics for all items in bags |
| `/la debugdecor` or `/la dd` | Show housing decor detection diagnostics for all items in bags |
| `/la debugbank` or `/la db` | Show bank inventory and detection status (requires bank to be open) |

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

- **Drag the list window** to reposition it anywhere on your screen
- **Toggle on/off** with `/la toggle`
- **Adjust check frequency** by editing the addon settings
- **Enable/disable verbose messages** with `/la verbose`

## Supported Items

- **Mounts**: Any mount item that can be learned by your character
- **Toys**: Any toy item in the toy collection system
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
