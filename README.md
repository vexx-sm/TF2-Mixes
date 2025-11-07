<h1 align="center">Team Fortress 2 Mixes</h1>



A SourceMod plugin that sets up a **6v6 competitive mix** where 2 captains pick players in an **XYXY** order. Includes random drafting, votes, and more.
> [!NOTE]
> A Discord bot is included to manage mixes in a [TF2Center-style](https://github.com/user-attachments/assets/d4937683-8185-4504-979d-f7c564fb59cf) setup. It’s under dev and requires version [0.3.3b](https://github.com/vexx-sm/TF2-Mixes/releases/tag/0.3.3b).



<p align="center">
  <a href="https://discord.com/oauth2/authorize?client_id=1429868144322936895&permissions=347136&scope=bot%20applications.commands">
    <img src="https://img.shields.io/badge/Add%20to%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white&labelColor=4f5bd5" alt="Invite Bot"/>
  </a>
</p>


https://github.com/user-attachments/assets/fb3d677a-5315-4551-b1b8-d51c46d8e3a1

## How It Works

### 1. Setup Phase
- Players use `!captain` or `!cap` to become (or drop as) a captain.  
- Once two captains are selected **and at least 12 players are present**, all others are moved to spectator.
- Captains are randomly assigned to RED or BLU.  

### 2. Drafting Phase


- Captains pick players in order (XYXY XYXY XY).  
- Picked players are auto-moved to their captain's team.
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
> Pre-game DM requires the provided [configs](https://github.com/vexx-sm/TF2-Mixes/releases/download/0.3.1/configs.zip), otherwise random spawns won't work.



## Commands

> Most commands support multiple aliases for convenience (e.g., `!restart`, `!redraft`, `!reset`)

### Player Commands
- `!captain` / `!cap` — Become or drop as captain  
- `!draft` / `!pick` — Open draft menu (only current captain, during their turn)  
- `!draft <player>` / `!pick <player>` — Pick a player by name (partial names work)  
- `!remove` — Remove a player from your team (counts as a turn)  
- `!restart` / `!redraft` — Start a vote to restart the draft (requires 2/3 of players to pass)
- `!helpmix` — Show help menu  

### Admin Commands

- `!setcaptain <player>` — Set/remove a captain  
- `!adminpick <player>` — Force pick a player for the current captain  
- `!autodraft` — Auto-draft remaining players  
- `!cancelmix` — Cancel the current mix  
- `!updatemix` — Check for and download plugin updates (auto install and reload)
- `!rup` — Force both teams ready
- `!outline` — Toggle teammate outlines for both teams
<p>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <img width="521" height="329" alt="Screenshot_1" src="https://github.com/user-attachments/assets/9d89a489-7251-4fe0-8874-38ab7ce853ef" />
</p>


## Installation 
1. Download the latest **SourceMod** version [here](https://www.sourcemod.net/downloads.php?branch=stable).
2. Download the latest **`mixes.smx`** from the [Releases](https://github.com/vexx-sm/TF2-Mixes/releases) page.
3. Place it in your `sourcemod/plugins` folder.
4. Reload the plugin or restart your server.
   
   **Optional:** 
     -	`mixes_dm.smx` provides DM features (health regen, random spawns). It's recommended for pre-game DM.
     -	Random spawns require these [configs](https://github.com/vexx-sm/TF2-Mixes/releases/download/0.3.1/configs.zip), extract in `tf2/tf/addons/sourcemod/configs`.

> [!WARNING]
> The plugin currently may conflict with SOAPdm, temporarily disable it for a proper experience.

---


**Requests & Contributions are welcome!**

<details>
<summary>what next?</summary>
  
- Configurable team sizes (4v4, 6v6, Highlander)   
- Configurable voting thresholds and options  
- New admin cmds: `sm_forcestart`, `sm_shuffle`  
- Better handling of spectators/late-joins  
- Match QoL: auto-pause and ready-up system  
- Full Discord bot integration.
</details>
