<h1 align="center">Team Fortress 2 Mixes</h1>

A SourceMod plugin that sets up a 6v6 competitive mixe where 2 captains can pick players in an XYXY XYXY XY fashion. Random drafting, votes and more.

> [!IMPORTANT]
> The plugin is in an early stage and currently serves as a base. 12v12 and much more is planned.

https://github.com/user-attachments/assets/c4f7fb5f-11e5-462c-bfda-3497f4b0330c


## How It Works

1. **Setup Phase**:
   - 2 Players use `!captain` or `!cap` to become or drop themselves as team captains.
   - Once two captains are selected and a minimum of 12 players are present, All other players are moved to spectator with 2 captains randomly assigned to red or blu

2. **Drafting Phase**:
   - Captains take turns picking players (XYXY XYXY XY pattern)
   - Each captain has a 30 second timer to make their pick, if the timer is over the turn is passed to the other team
   - If a captain disconnects or drop thier captain stat, a 30 second grace period starts for a replacement after which the game is canceled if no replacement is present
   - Picked players are automatically moved to their captain's team

3. **Gameplay Phase**:
   - Teams are locked to prevent switching
   - Players can change classes but not teams
   - At the end of each round, a vote starts for:
     - Continue with same teams
     - Start new draft
     - End mix
   - 2/3 majority required for vote to pass

## Commands

- `!captain` Become or get dropped as a team captain 
- `!draft` or `!pick` Open the draft menu to pick players (only works for current captain during their turn)
- `!draft player123` or `!pick player123` Directly pick a player by name (only works for current captain during their turn, partial names work too)
- `!votemix` Start a vote to cancel the current mix (2-minute global cooldown between votes)

## Admin Commands

- `!setcaptain <player>` Set or remove a player as captain 
- `!adminpick <player>` Force pick a player for the current captain's team
- `!autodraft` Automatically draft remaining players to open team slots
- `!cancelmix` Cancel current mix and reset

## Requirements

- The latest [SourceMod](https://www.sourcemod.net/downloads.php) release

## Installation

1. Download the latest `mixes.smx` from the [Releases](https://github.com/vexx-sm/TF2-Mixes/releases) page and place it in your `sourcemod\plugins` folder.
2. Reload the plugin or restart your server.

## License & Contributing

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

**Requests** & Contributions are welcome! Feel free to submit a Pull Request.
