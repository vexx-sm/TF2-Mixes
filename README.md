<div align="center">
<h1>  ⚙️ TF2 PUGs Bot</h1>

[![Latest Release](https://img.shields.io/github/v/release/vexx-sm/TF2-PUGBot?label=Download&color=success&style=flat-square)](https://github.com/vexx-sm/TF2-PUGBot/releases)
![GitHub all releases](https://img.shields.io/github/downloads/vexx-sm/TF2-PUGBot/total?style=flat-square&color=orange)
![Players Tracked](https://img.shields.io/badge/Tracking-152%20Players-6f42c1?style=flat-square)

</div>



A SourceMod plugin that sets up **6s/hl PUGs** where 2 captains pick players in an **XYXY** order or slot based on Discord. Includes random drafting, votes, and more.


<div align="center">
  
https://github.com/user-attachments/assets/fb3d677a-5315-4551-b1b8-d51c46d8e3a1

</div>

> [!NOTE]
> An Optional discord bot is included to manage mixes in a [TF2Center-style](https://github.com/user-attachments/assets/9435c637-0174-4d7f-b3a2-2d9b3604e428) setup or the normal in game method with [Announcements](https://github.com/user-attachments/assets/eab70e8c-23f3-4764-b071-e4d4d917a2b2), [Elo and Leaderboards](https://github.com/user-attachments/assets/74d6fbf9-f86b-471a-8870-f9b8d8a1a394), [History](https://github.com/user-attachments/assets/3ebaa6eb-b1ec-4948-a2d0-2d8d3538383d), fully managed VC and more [integration](https://github.com/user-attachments/assets/1970b8f6-16bb-44b3-9110-58a87d0e728f).

<p align="center">
  <a href="https://discord.com/oauth2/authorize?client_id=1429868144322936895&permissions=272067664&scope=bot%20applications.commands">
    <img src="https://img.shields.io/badge/Add%20to%20Server-5865F2?style=for-the-badge&logo=discord&logoColor=white&labelColor=4f5bd5" alt="Invite Bot"/>
  </a>
</p>

</div>


&nbsp;
## 🕹️ How It Works
Essentially the plugin cycles a game through 3 phases: `Pre-Game` ➔ `Draft` ➔ `Live Game` 

### 🔴 1. Pre Game
* Players use `!captain` or `!cap` to become (or drop as) a captain.  
* Once two captains are selected **and at least 12 players are present**, all players are moved to spectator.  
* Captains are randomly assigned to RED or BLU.

### 🟡 2. Draft 
* Captains take turns picking players `!draft` (**XYXY XYXY XY**). 
* Use `!remove` to drop a yourself or a player / `!swap x y` (as a captain) to propose a trade.
* Followed by **RUP** where players are moved to their VCs.

### 🟢 3. Live Game
* Offclassing is restricted outside of last point holds (6s cp_ maps) by default.
* Players can `!rep x` or `!rep me` to request a replacement via Discord.
* Requires **30% to initiate** and passes with a **⅔ majority**.  
* Concludes with a vote to restart the game or reset teams.

&nbsp;

## ⌨️ Commands
**Prefix:** `!` or `/`  
*Most commands support 3+ aliases for convenience (e.g `!restart`, `!redraft`, `!reset`)*

<br>



<table>
  <tr>
    <th colspan="2" align="center">Player Commands</th>
  </tr>
  <tr>
    <td><code>!captain</code> / <code>!cap</code></td>
    <td>Become or drop as captain</td>
  </tr>
  <tr>
    <td><code>!draft</code> / <code>!pick</code></td>
    <td>Open menu of available picks (current captain only)</td>
  </tr>
  <tr>
    <td><code>!draft &lt;name&gt;</code> / <code>!pick &lt;name&gt;</code></td>
    <td>Pick a player by name (partial names work)</td>
  </tr>
  <tr>
    <td><code>!swap &lt;p1&gt; &lt;p2&gt;</code></td>
    <td>Propose a player swap between teams (<code>!swap</code> for menu)</td>
  </tr>
  <tr>
    <td><code>!remove</code></td>
    <td>Remove self or teammate (Draft/RUP phase only)</td>
  </tr>
  <tr>
    <td><code>!offclass</code></td>
    <td>Propose a vote to toggle offclassing on/off</td>
  </tr>
  <tr>
    <td><code>!rep x</code> / <code>!rep me</code></td>
    <td>Request a replacement (Live Game phase only)</td>
  </tr>
  <tr>
    <td><code>!restart</code> / <code>!redraft</code></td>
    <td>Vote to restart the draft (2/3 majority)</td>
  </tr>
  <tr>
    <td><code>!helpmix</code> / <code>!help</code></td>
    <td>Show all available commands</td>
  </tr>
</table>

<br>

<table>
  <tr>
    <th colspan="2" align="center">Admin Commands</th>
  </tr>
  <tr>
    <td><code>!setcaptain &lt;p&gt;</code></td>
    <td>Set or remove a captain</td>
  </tr>
  <tr>
    <td><code>!adminpick &lt;p&gt;</code></td>
    <td>Force pick a player for the current captain</td>
  </tr>
  <tr>
    <td><code>!autodraft</code></td>
    <td>Auto-draft all remaining players</td>
  </tr>
  <tr>
    <td><code>!randommix</code></td>
    <td>Selects random captains and random teams</td>
  </tr>
  <tr>
    <td><code>!cancelmix</code></td>
    <td>Cancel the current mix</td>
  </tr>
  <tr>
    <td><code>!updatemix</code></td>
    <td>Check, download, and auto-install plugin updates</td>
  </tr>
  <tr>
    <td><code>!rup</code></td>
    <td>Force both teams to ready up</td>
  </tr>
  <tr>
    <td><code>!cleanupstuck</code></td>
    <td>(Discord) Clears bot/game state if stuck</td>
  </tr>
  <tr>
    <td><code>!outline</code></td>
    <td>Toggle teammate outlines through walls
    <p align="center">
      <img width="521" height="329" alt="Screenshot_1" src="https://github.com/user-attachments/assets/9d89a489-7251-4fe0-8874-38ab7ce853ef" />
    </p></td>
  </tr>
</table>

</div>

&nbsp;

## 🛠️ Installation

1. Download the latest **`mixes.smx`**, **`mixes_dm.smx`**, and **`configs.zip`** from the [Releases](https://github.com/vexx-sm/TF2-Mixes/releases) page.  
2. Place **`mixes.smx`** / **`mixes_dm.smx`** in your `sourcemod/plugins` folder.
3. Unzip **`configs.zip`** into `tf2/tf/addons/sourcemod/`.
4. Reload the plugin or restart your server.  

> [!WARNING]
> The plugin currently may conflict with SOAPdm; temporarily disable it for a proper experience.

&nbsp;

## 📸 Discord Bot Examples

<br>

<div align="center">

| ELO & Leaderboards | Discord PUG |
| :---: | :---: |
| <img src="https://github.com/user-attachments/assets/74d6fbf9-f86b-471a-8870-f9b8d8a1a394" width="420" /> | <img src="https://github.com/user-attachments/assets/9b49a50f-980d-4538-a212-6d2768de81fc" width="420" /> 

| Match History | Announcements |
| :---: | :---: |
| <img src="https://github.com/user-attachments/assets/3ebaa6eb-b1ec-4948-a2d0-2d8d3538383d" width="420" /> | <img src="https://github.com/user-attachments/assets/dca571a2-061d-4d27-bfc9-47a2b49fb0a1" width="420" /> |

| Live PUG | `!rep`  |
| :---: | :---: |
| <img src="https://github.com/user-attachments/assets/5130f6d2-1e2a-452b-90bb-9163417c9c4e" width="420" /> | <img src="https://github.com/user-attachments/assets/4f354bae-feaf-4600-a4ec-b7bd114c57a3" width="420" /> |
