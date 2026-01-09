<h1 align="center">Team Fortress 2 Mixes</h1>

A SourceMod plugin that sets up a **6s/hl PUGs** where 2 captains pick players in an **XYXY** order or slot based on discord. Includes random drafting, votes, and more.

> [!NOTE]
> A Discord bot is included to manage mixes in a [TF2Center-style](https://github.com/user-attachments/assets/9435c637-0174-4d7f-b3a2-2d9b3604e428) setup or the normal in game method with [Announcements](https://github.com/user-attachments/assets/eab70e8c-23f3-4764-b071-e4d4d917a2b2), [History](https://github.com/user-attachments/assets/3ebaa6eb-b1ec-4948-a2d0-2d8d3538383d), fully managed VC and more [integration](https://github.com/user-attachments/assets/1970b8f6-16bb-44b3-9110-58a87d0e728f).

>  Now with 4 hosts (NA, EU, ASIA, AUS)
 <p align="center">
  <a href="https://discord.com/oauth2/authorize?client_id=1429868144322936895&permissions=272067664&scope=bot%20applications.commands">
    <img src="https://img.shields.io/badge/Add%20to%20Server-5865F2?style=for-the-badge&logo=discord&logoColor=white&labelColor=4f5bd5" alt="Invite Bot"/>
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
- Captains may use `!swap x y` to request a player for player swap between teams (counts as a turn).

### 3. Game Phase
- Players may change class, but **not teams**. 
- Offclassing is punished outside of last point holds.
- Players can `!rep x` or `!rep me` to report and request a replacement of a player.
- At the end of each round, players vote to either:  
  - Continue with same teams  
  - Start a new draft 
- Any vote requires **30% of players to initiate**, and passes with **⅔ majority**.  

> [!NOTE]
> Pre-game DM requires the provided [configs](https://github.com/vexx-sm/TF2-Mixes/releases/download/0.3.1/configs.zip), otherwise random spawns won't work.

## Commands

> Most commands support 3+ aliases for convenience (e.g `!restart`, `!redraft`, `!reset`)

### Player Commands
- `!captain` / `!cap` — Become or drop as captain  
- `!draft` / `!pick` — Open draft menu (only current captain during their turn)  
- `!draft <player>` / `!pick <player>` — Pick a player by name (partial names work)  
- `!swap <player1> <player2>` / `!swap` For a menu instead - Propose a player for player swap between teams.
- `!remove` — Remove a player from your team (counts as a turn)  
- `!restart` / `!redraft` — Start a vote to restart the draft (requires 2/3 of players to pass)  
- `!helpmix` — Show help menu  

### Admin Commands
- `!setcaptain <player>` — Set/remove a captain  
- `!adminpick <player>` — Force pick a player for the current captain  
- `!autodraft` — Auto-draft remaining players  
- `!randommix` — Selects random captains and random teams  
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
   - `mixes_dm.smx` provides DM features (health regen, random spawns). It's recommended for pre-game DM.  
   - Random spawns require these [configs](https://github.com/vexx-sm/TF2-Mixes/releases/download/0.3.1/configs.zip), extract in `tf2/tf/addons/sourcemod/configs`.

> [!WARNING]
> The plugin currently may conflict with SOAPdm, temporarily disable it for a proper experience.

---

**Requests & Contributions are welcome!**

<details>
<summary>Current discord bot:</summary>
<img width="576" height="698" alt="mix discord" src="https://github.com/user-attachments/assets/9b49a50f-980d-4538-a212-6d2768de81fc" />
<img width="587" height="446" alt="image33" src="https://github.com/user-attachments/assets/f79367e9-04c3-401d-98b0-8e161ca475db" />
<img width="471" height="215" alt="rep" src="https://github.com/user-attachments/assets/4f354bae-feaf-4600-a4ec-b7bd114c57a3" />
<img width="570" height="373" alt="statsandtacking" src="https://github.com/user-attachments/assets/8e05a221-e47f-47f0-805e-422cde6b9a5e" />
</details>
