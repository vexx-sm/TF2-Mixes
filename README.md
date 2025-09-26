<h1 align="center">Team Fortress 2 Mixes</h1>

A SourceMod plugin that sets up a **6v6 competitive mix** where 2 captains pick players in an **XYXY XYXY XY** draft order. Includes random drafting, votes, and more.

> [!IMPORTANT]
> This plugin is in an early stage and currently serves as a base. 12v12 and other formats are planned.

> [!WARNING]
> The plugin currently conflicts with [SOAPdm](https://github.com/sapphonie/SOAP-TF2DM) and won't work properly if it's loaded.

https://github.com/user-attachments/assets/c4f7fb5f-11e5-462c-bfda-3497f4b0330c


## How It Works

### 1. Setup Phase
- Players use `!captain` or `!cap` to become (or drop as) a captain.  
- Once two captains are selected **and at least 12 players are present**, all others are moved to spectator.  
- Captains are randomly assigned to RED or BLU.  

### 2. Drafting Phase
- Captains pick players in order (XYXY XYXY XY).  
- Picked players are auto-moved to their captain’s team.  
- Each captain has **30s per turn**; if the timer expires, a random player is picked.  
- Captains may use `!remove` to drop a player (counts as a turn).  
- When both teams reach 6v6, a **10s countdown** begins before the game starts.  

### 3. Game Phase
- Players may change class, but **not teams**.  
- At the end of each round, players vote to either:  
  - Continue with same teams  
  - Start a new draft  
- Any vote requires **30% of players to initiate**, and passes with **⅔ majority**.  

> [!NOTE]
> Pre-game DM requires the provided [configs](https://github.com/vexx-sm/TF2-Mixes/tree/main/configs), otherwise random spawns won’t work.


## Commands

### Player Commands
- `!captain` / `!cap` — Become or drop as captain  
- `!draft` / `!pick` — Open draft menu (only current captain, during their turn)  
- `!draft <player>` / `!pick <player>` — Pick a player by name (partial names work)  
- `!remove` — Remove a player from your team (counts as a turn)  
- `!restart` / `!redraft` — Start a vote to restart the draft  
- `!helpmix` — Show help menu  

### Admin Commands
- `!setcaptain <player>` — Set/remove a captain  
- `!adminpick <player>` — Force pick a player for the current captain  
- `!autodraft` — Auto-draft remaining players  
- `!cancelmix` — Cancel the current mix  
- `!updatemix` — Check for and download plugin updates (auto install and reload)
- `!outline` — Toggle teammate outlines (to help coordination with no comms)

<img width="892" height="563" alt="Screenshot_1" src="https://github.com/user-attachments/assets/9a8b8a89-be9e-4b28-9567-3ac7e5d50912" />


## Installation 
1. Download the latest **SourceMod** version [here](https://www.sourcemod.net/downloads.php?branch=stable).
2. Download the latest **`mixes.smx`** from the [Releases](https://github.com/vexx-sm/TF2-Mixes/releases) page.
3. Place it in your `sourcemod/plugins` folder.
4. Reload the plugin or restart your server.


---

**Requests & Contributions are welcome!**

<details>
<summary>what next?</summary>
  
- Configurable team sizes (4v4, 6v6, Highlander)   
- Improved captain handling (auto-replacement)  
- Smarter auto-draft and configurable voting  
- New admin cmds: `sm_forcestart`, `sm_shuffle`  
- Better handling of spectators/late-joins  
- Match QoL: auto-pause and ready-up system  

</details>
