#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <sdktools>
#include <float>
#include <SteamWorks>

#pragma semicolon 1
#pragma newdecls required

#define TEAM_SIZE 6

// State machine for mix management
#define STATE_IDLE 0
#define STATE_PRE_DRAFT 1
#define STATE_DRAFT 2
#define STATE_LIVE_GAME 3
#define STATE_POST_GAME 4  // New state: waiting for players to decide next action

public Plugin myinfo = {
    name = "TF2-Mixes",
    author = "vexx-sm",
    description = "A TF2 SourceMod plugin that sets up a 6s mix",
    version = "0.3.1",
    url = "https://github.com/vexx-sm/TF2-Mixes"
};

// State machine variables
int g_eCurrentState = STATE_IDLE;

// Core mix variables
int g_iCaptain1 = -1;
int g_iCaptain2 = -1;
int g_iCurrentPicker = 0;
Handle g_hPickTimer = INVALID_HANDLE;
Handle g_hHudTimer = INVALID_HANDLE;
Handle g_hTipsTimer = INVALID_HANDLE;
float g_fLastCommandTime[MAXPLAYERS + 1];
char g_sOriginalNames[MAXPLAYERS + 1][MAX_NAME_LENGTH];
bool g_bPlayerLocked[MAXPLAYERS + 1];
Handle g_hGraceTimer = INVALID_HANDLE;
int g_iMissingCaptain = -1;
int g_iPicksRemaining = 0;

// Grace period state preservation
int g_iSavedCurrentPicker = 0;
int g_iSavedPicksRemaining = 0;
float g_fSavedPickTimerStartTime = 0.0;
int g_iSavedCountdownSeconds = 0;


// Player reconnection state preservation
int g_iDisconnectedPlayerTeam[MAXPLAYERS + 1];
bool g_bDisconnectedPlayerPicked[MAXPLAYERS + 1];
bool g_bPlayerDisconnected[MAXPLAYERS + 1];

// Vote system
Handle g_hVoteTimer = INVALID_HANDLE;
int g_iVoteCount[2] = {0, 0};
bool g_bPlayerVoted[MAXPLAYERS + 1];
float g_fPickTimerStartTime = 0.0;
bool g_bPlayerPicked[MAXPLAYERS + 1];
float g_fVoteStartTime = 0.0;

// Restart vote system
bool g_bRestartVote[MAXPLAYERS + 1];
Handle g_hRestartVoteResetTimer = INVALID_HANDLE;

// Countdown system
int g_iCountdownSeconds = 0;
Handle g_hCountdownTimer = INVALID_HANDLE;
Handle g_hNotificationTimer = INVALID_HANDLE;

// Outline system
bool g_bOutlinesEnabled = false;

char ETF2L_WHITELIST_PATH[] = "cfg/etf2l_whitelist_6v6.txt";

// DM module integration
bool g_bDMPluginLoaded = false;

// Tournament pre-start flag to align countdown with tournament ready-up
bool g_bPreStartedTournament = false;

// Chat color tag for consistent branding
static const char MIX_TAG[] = "\x07FFD700[Mix]\x01 ";
bool g_bDMAnnounced = false;

ConVar g_cvPickTimeout;
ConVar g_cvCommandCooldown;
ConVar g_cvGracePeriod;
ConVar g_cvTipsEnable;
ConVar g_cvTipsInterval;
int g_iTipIndex = 0;

bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

// Helper function to find player by name (exact or partial match)
int FindPlayerByName(const char[] target, int teamFilter = 0, bool spectatorOnly = false) {
    char targetName[MAX_NAME_LENGTH];
    
    // Exact match first
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClient(i)) continue;
        
        // Apply filters
        if (teamFilter > 0 && GetClientTeam(i) != teamFilter) continue;
        if (spectatorOnly && view_as<TFTeam>(GetClientTeam(i)) != TFTeam_Spectator) continue;
        
        GetClientName(i, targetName, sizeof(targetName));
        if (StrEqual(targetName, target, false)) {
            return i;
        }
    }
    
    // Partial match fallback
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClient(i)) continue;
        
        if (teamFilter > 0 && GetClientTeam(i) != teamFilter) continue;
        if (spectatorOnly && view_as<TFTeam>(GetClientTeam(i)) != TFTeam_Spectator) continue;
        
        GetClientName(i, targetName, sizeof(targetName));
        if (StrContains(targetName, target, false) != -1) {
            return i;
        }
    }
    
    return -1;
}

void KillTimerSafely(Handle &timer) {
    if (timer != INVALID_HANDLE) {
        delete timer;
        timer = INVALID_HANDLE;
    }
}

// ========================================
// STATE MACHINE FUNCTIONS
// ========================================

void SetMixState(int newState) {
    if (g_eCurrentState == newState) return;
    
    g_eCurrentState = newState;
    
    // Handle state-specific transitions
    switch(newState) {
        case STATE_IDLE: EnterIdleState();
        case STATE_PRE_DRAFT: EnterPreDraftState();
        case STATE_DRAFT: EnterDraftState();
        case STATE_LIVE_GAME: EnterLiveGameState();
        case STATE_POST_GAME: EnterPostGameState();
    }
    
    // Update crown effects based on new state
}

// ========================================
// CVAR MANAGEMENT - State-specific settings
// ========================================

void ApplyIdleStateCvars() {
    // Disable tournament mode
    ServerCommandSilent("mp_tournament 0");
    ServerCommandSilent("mp_tournament_allow_non_admin_restart 1");
    
    // Clear whitelist
    ServerCommandSilent("mp_tournament_whitelist \"\"");
    
    // Reset ALL win conditions
    ServerCommandSilent("mp_winlimit 0");
    ServerCommandSilent("mp_maxrounds 0");
    ServerCommandSilent("mp_timelimit 0");
    ServerCommandSilent("mp_windifference 0");
    
    // Ensure fixed weapon spread always enabled
    ServerCommandSilent("tf_use_fixed_weaponspreads 1");
    ServerCommandSilent("tf_damage_disablespread 1");
    
    // Truly unlocked teams - no limits, no autobalance, instant respawn
    ServerCommandSilent("mp_teams_unbalance_limit 0");
    ServerCommandSilent("mp_autoteambalance 0");
    ServerCommandSilent("mp_forceautoteam 0");
    ServerCommandSilent("mp_disable_respawn_times 1"); // Enable instant respawn
    
    // Remove class limits
    SetCvarInt("tf_tournament_classlimit_scout", 0);
    SetCvarInt("tf_tournament_classlimit_soldier", 0);
    SetCvarInt("tf_tournament_classlimit_pyro", 0);
    SetCvarInt("tf_tournament_classlimit_demoman", 0);
    SetCvarInt("tf_tournament_classlimit_heavy", 0);
    SetCvarInt("tf_tournament_classlimit_engineer", 0);
    SetCvarInt("tf_tournament_classlimit_medic", 0);
    SetCvarInt("tf_tournament_classlimit_sniper", 0);
    SetCvarInt("tf_tournament_classlimit_spy", 0);
    
    // Normal bot settings
    ServerCommandSilent("tf_bot_quota_mode normal");
    ServerCommandSilent("tf_bot_quota 0");
    
    // Restart game to clear tournament state
    ServerCommand("mp_restartgame 1"); // Keep visible for restart notification
}

void ApplyPreDraftStateCvars() {
    // Keep tournament mode disabled
    ServerCommandSilent("mp_tournament 0");
    
    // No win conditions
    ServerCommandSilent("mp_winlimit 0");
    ServerCommandSilent("mp_maxrounds 0");
    ServerCommandSilent("mp_timelimit 0");
    ServerCommandSilent("mp_windifference 0");
    
    // Ensure fixed weapon spread always enabled
    ServerCommandSilent("tf_use_fixed_weaponspreads 1");
    ServerCommandSilent("tf_damage_disablespread 1");
    
    // No whitelist
    ServerCommandSilent("mp_tournament_whitelist \"\"");
    
    // Truly unlocked teams - no limits, no autobalance, instant respawn
    ServerCommandSilent("mp_teams_unbalance_limit 0");
    ServerCommandSilent("mp_autoteambalance 0");
    ServerCommandSilent("mp_forceautoteam 0");
    ServerCommandSilent("mp_disable_respawn_times 1"); // Enable instant respawn
    
    // Remove class limits
    SetCvarInt("tf_tournament_classlimit_scout", 0);
    SetCvarInt("tf_tournament_classlimit_soldier", 0);
    SetCvarInt("tf_tournament_classlimit_pyro", 0);
    SetCvarInt("tf_tournament_classlimit_demoman", 0);
    SetCvarInt("tf_tournament_classlimit_heavy", 0);
    SetCvarInt("tf_tournament_classlimit_engineer", 0);
    SetCvarInt("tf_tournament_classlimit_medic", 0);
    SetCvarInt("tf_tournament_classlimit_sniper", 0);
    SetCvarInt("tf_tournament_classlimit_spy", 0);
}

void ApplyDraftStateCvars() {
    // Keep tournament mode disabled
    ServerCommandSilent("mp_tournament 0");
    
    // No win conditions
    ServerCommandSilent("mp_winlimit 0");
    ServerCommandSilent("mp_maxrounds 0");
    ServerCommandSilent("mp_timelimit 0");
    ServerCommandSilent("mp_windifference 0");
    
    // Ensure fixed weapon spread always enabled
    ServerCommandSilent("tf_use_fixed_weaponspreads 1");
    ServerCommandSilent("tf_damage_disablespread 1");
    
    // No whitelist
    ServerCommandSilent("mp_tournament_whitelist \"\"");
    
    // Enable instant respawn during draft for warmup
    ServerCommandSilent("mp_disable_respawn_times 1");
    
    // Prevent team balance during draft
    ServerCommandSilent("mp_teams_unbalance_limit 1");
    ServerCommandSilent("mp_autoteambalance 0");
    ServerCommandSilent("mp_forceautoteam 0");
}

void ApplyLiveGameStateCvars() {
    // Enable tournament mode
    ServerCommandSilent("mp_tournament 1");
    ServerCommandSilent("mp_tournament_allow_non_admin_restart 1");
    
    // Apply whitelist
    SetCvarString("mp_tournament_whitelist", ETF2L_WHITELIST_PATH);
    
    // Competitive gameplay settings
    ServerCommandSilent("tf_use_fixed_weaponspreads 1");
    ServerCommandSilent("tf_weapon_criticals 0");
    ServerCommandSilent("tf_damage_disablespread 1");
    
    // CRITICAL: Disable instant respawn and enable respawn waves
    ServerCommandSilent("mp_disable_respawn_times 1");
    ServerCommandSilent("mp_respawnwavetime 10");
    
    // Apply ETF2L class limits
    SetCvarInt("tf_tournament_classlimit_scout", 2);
    SetCvarInt("tf_tournament_classlimit_soldier", 2);
    SetCvarInt("tf_tournament_classlimit_pyro", 1);
    SetCvarInt("tf_tournament_classlimit_demoman", 1);
    SetCvarInt("tf_tournament_classlimit_heavy", 1);
    SetCvarInt("tf_tournament_classlimit_engineer", 1);
    SetCvarInt("tf_tournament_classlimit_medic", 1);
    SetCvarInt("tf_tournament_classlimit_sniper", 1);
    SetCvarInt("tf_tournament_classlimit_spy", 2);
    
    // Apply map-specific win conditions (ETF2L 6s)
    if (IsKothMap()) {
        SetCvarInt("mp_maxrounds", 0);
        SetCvarInt("mp_timelimit", 0);
        SetCvarInt("mp_windifference", 0);
        SetCvarInt("mp_winlimit", 4);  // ETF2L KOTH: First to 4 rounds
    } else {
        SetCvarInt("mp_maxrounds", 0);
        SetCvarInt("mp_timelimit", 30);
        SetCvarInt("mp_windifference", 5);
        SetCvarInt("mp_winlimit", 5);  // ETF2L 5CP: First to 5 rounds
    }
    
    // Strict team settings
    ServerCommandSilent("mp_teams_unbalance_limit 0");
    ServerCommandSilent("mp_autoteambalance 0");
    ServerCommandSilent("mp_forceautoteam 0");
}

void EnterIdleState() {
    // Reset all timers
    KillAllTimers();
    
    // Restore captain names before resetting
    if (g_iCaptain1 != -1 && IsValidClient(g_iCaptain1)) {
        SetClientName(g_iCaptain1, g_sOriginalNames[g_iCaptain1]);
    }
    if (g_iCaptain2 != -1 && IsValidClient(g_iCaptain2)) {
        SetClientName(g_iCaptain2, g_sOriginalNames[g_iCaptain2]);
    }
    
    g_iCaptain1 = -1;
    g_iCaptain2 = -1;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_iPicksRemaining = 0;
    g_fPickTimerStartTime = 0.0;
    g_iCountdownSeconds = 0;
    
    // Reset all player states
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerLocked[i] = false;
        g_bPlayerPicked[i] = false;
        g_bPlayerVoted[i] = false;
        g_fLastCommandTime[i] = 0.0;
        g_sOriginalNames[i][0] = '\0';
        g_bPlayerDisconnected[i] = false;
        g_iDisconnectedPlayerTeam[i] = 0;
        g_bDisconnectedPlayerPicked[i] = false;
    }
    
    // Apply IDLE state cvars (complete reset)
    ApplyIdleStateCvars();
    
    // Enable DM for idle state
    if (g_bDMPluginLoaded) {
        DM_StopAllFeatures();
        CreateTimer(0.1, Timer_ReenableDM);
    }
    
    // Start HUD timer
    if (g_hHudTimer == INVALID_HANDLE) {
        g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
}

void EnterPreDraftState() {
    // Apply PRE_DRAFT state cvars
    ApplyPreDraftStateCvars();
    
    // Enable DM for pre-draft
    if (g_bDMPluginLoaded) {
        DM_SetPreGameActive(true);
        DM_SetDraftInProgress(false);
    }
    
    // Start HUD timer
    if (g_hHudTimer == INVALID_HANDLE) {
        g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
}

void EnterDraftState() {
    // Safety: Validate captains exist
    if (!IsValidClient(g_iCaptain1) || !IsValidClient(g_iCaptain2)) {
        PrintToChatAll("\x01[Mix] \x03Error: Invalid captains! Cancelling draft.");
        SetMixState(STATE_IDLE);
        return;
    }
    
    // Apply DRAFT state cvars
    ApplyDraftStateCvars();
    
    // Initialize draft state
    g_iCurrentPicker = 0;
    g_iPicksRemaining = 10; // 12 total players - 2 captains = 10 picks
    
    // Move everyone to spectator first
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            TF2_ChangeClientTeam(i, TFTeam_Spectator);
            g_bPlayerLocked[i] = false;
            
            // Force bots to spectator with a delayed check
            if (IsFakeClient(i)) {
                CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(i));
            }
        }
    }
    
    // Move captains to teams
    TF2_ChangeClientTeam(g_iCaptain1, TFTeam_Red);
    TF2_ChangeClientTeam(g_iCaptain2, TFTeam_Blue);
    g_bPlayerLocked[g_iCaptain1] = true;
    g_bPlayerLocked[g_iCaptain2] = true;
    g_bPlayerPicked[g_iCaptain1] = true;
    g_bPlayerPicked[g_iCaptain2] = true;
    
    // Enable DM for draft
    if (g_bDMPluginLoaded) {
        DM_SetPreGameActive(true);
        DM_SetDraftInProgress(true);
    }
    
    // Start pick timer
    g_fPickTimerStartTime = GetGameTime();
    KillTimerSafely(g_hPickTimer);
    g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
    
// Start HUD timer
    if (g_hHudTimer == INVALID_HANDLE) {
        g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
    
    PrintToChatAll("%s\x03Draft has started! First captain's turn to pick.", MIX_TAG);
    
    // Open draft menu for first captain
    if (IsValidClient(g_iCaptain1)) {
        CreateTimer(0.5, Timer_OpenDraftMenu, GetClientUserId(g_iCaptain1));
    }
}

void EnterLiveGameState() {
    // Lock all players to their teams
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            g_bPlayerLocked[i] = true;
        }
    }
    
    // Apply LIVE_GAME state cvars (includes tournament mode, whitelist, class limits, win conditions)
    ApplyLiveGameStateCvars();
    
    // Disable DM for live game
    if (g_bDMPluginLoaded) {
        DM_SetPreGameActive(false);
        DM_SetDraftInProgress(false);
        DM_StopAllFeatures();
    }
    
    // Clear hint text
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i)) {
            PrintHintText(i, "");
        }
    }
    
    // Restart tournament and force teams ready (unless already pre-started)
    if (!g_bPreStartedTournament) {
        ServerCommand("mp_tournament_restart");
        CreateTimer(0.5, Timer_ForceTeamsReady);
    } else {
        g_bPreStartedTournament = false;
    }
    
    // Show completion message
    CreateTimer(3.0, Timer_ShowDraftCompleteMessage);
}

void EnterPostGameState() {
    // Show vote menu to all players after a brief delay
    CreateTimer(2.0, Timer_ShowPostGameVote);
    
    // Start HUD timer for post-game display
    if (g_hHudTimer == INVALID_HANDLE) {
        g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
}

// Player state preservation functions
void PreservePlayerState(int client) {
    if (!IsValidClient(client)) return;
    
    g_bPlayerDisconnected[client] = true;
    g_iDisconnectedPlayerTeam[client] = GetClientTeam(client);
    g_bDisconnectedPlayerPicked[client] = g_bPlayerPicked[client];
}

void RestorePlayerState(int client) {
    if (!IsValidClient(client)) return;
    
    // Restore team assignment
    if (g_iDisconnectedPlayerTeam[client] > 0) {
        TF2_ChangeClientTeam(client, view_as<TFTeam>(g_iDisconnectedPlayerTeam[client]));
        g_bPlayerLocked[client] = true;
        g_bPlayerPicked[client] = g_bDisconnectedPlayerPicked[client];
    }
    
    // Clear disconnection state
    g_bPlayerDisconnected[client] = false;
    g_iDisconnectedPlayerTeam[client] = 0;
    g_bDisconnectedPlayerPicked[client] = false;
}

public void OnPluginStart() {
    LoadTranslations("common.phrases");
    // LoadTranslations("mixes.phrases");
    
    // Disable hint text sound to prevent timer noise
    ServerCommand("sv_hudhint_sound 0");
    
    // Captain commands
    RegConsoleCmd("sm_captain", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_cap", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_capitan", Command_Captain, "Become a captain"); // Common typo
    RegConsoleCmd("sm_capt", Command_Captain, "Become a captain"); // Short version
    
    // Draft/pick commands
    RegConsoleCmd("sm_draft", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_pick", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_drft", Command_Draft, "Draft a player or show draft menu"); // Fast typer
    RegConsoleCmd("sm_pik", Command_Draft, "Draft a player or show draft menu"); // Fast typer
    RegConsoleCmd("sm_p", Command_Draft, "Draft a player or show draft menu"); // Ultra short
    
    // Remove commands
    RegConsoleCmd("sm_remove", Command_Remove, "Remove a player from your team (counts as a turn)");
    RegConsoleCmd("sm_rmv", Command_Remove, "Remove a player from your team (counts as a turn)"); // Fast typer
    RegConsoleCmd("sm_rm", Command_Remove, "Remove a player from your team (counts as a turn)"); // Short version
    RegConsoleCmd("sm_kick", Command_Remove, "Remove a player from your team (counts as a turn)"); // Intuitive alias
    
    // Restart commands
    RegConsoleCmd("sm_restart", Command_RestartDraft, "Vote to restart after game ends");
    RegConsoleCmd("sm_redraft", Command_RestartDraft, "Vote to restart after game ends");
    RegConsoleCmd("sm_reset", Command_RestartDraft, "Vote to restart after game ends"); // Common alternative
    RegConsoleCmd("sm_mixrestart", Command_RestartDraft, "Vote to restart after game ends"); // Noun-first
    RegConsoleCmd("sm_restartmix", Command_RestartDraft, "Vote to restart after game ends"); // Verb-first
    
    // Cancel commands
    RegConsoleCmd("sm_cancelmix", Command_CancelMix, "Cancel current mix");
    RegConsoleCmd("sm_mixcancel", Command_CancelMix, "Cancel current mix"); // Noun-first
    RegConsoleCmd("sm_cancel", Command_CancelMix, "Cancel current mix"); // Short version
    RegConsoleCmd("sm_cancle", Command_CancelMix, "Cancel current mix"); // Common typo
    RegConsoleCmd("sm_stop", Command_CancelMix, "Cancel current mix"); // Intuitive alias
    RegConsoleCmd("sm_abort", Command_CancelMix, "Cancel current mix"); // Alternative
    
    // Help commands
    RegConsoleCmd("sm_helpmix", Command_HelpMix, "Show help menu with all commands");
    RegConsoleCmd("sm_help", Command_HelpMix, "Show help menu with all commands");
    RegConsoleCmd("sm_mixhelp", Command_HelpMix, "Show help menu with all commands"); // Noun-first
    RegConsoleCmd("sm_commands", Command_HelpMix, "Show help menu with all commands"); // Alternative
    RegConsoleCmd("sm_cmds", Command_HelpMix, "Show help menu with all commands"); // Short version
    
    AddCommandListener(Command_JoinTeam, "jointeam");
    AddCommandListener(Command_JoinTeam, "spectate");
    
    // Admin captain commands
    RegAdminCmd("sm_setcaptain", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain");
    RegAdminCmd("sm_setcap", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain");
    RegAdminCmd("sm_forcecaptain", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain"); // Alternative
    RegAdminCmd("sm_makecaptain", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain"); // Intuitive
    
    // Admin pick commands
    RegAdminCmd("sm_adminpick", Command_AdminPick, ADMFLAG_GENERIC, "Force pick a player");
    RegAdminCmd("sm_forcepick", Command_AdminPick, ADMFLAG_GENERIC, "Force pick a player"); // Alternative
    RegAdminCmd("sm_apick", Command_AdminPick, ADMFLAG_GENERIC, "Force pick a player"); // Short version
    
    // Admin draft commands
    RegAdminCmd("sm_autodraft", Command_AutoDraft, ADMFLAG_GENERIC, "Automatically draft teams");
    RegAdminCmd("sm_autofill", Command_AutoDraft, ADMFLAG_GENERIC, "Automatically draft teams"); // Alternative
    RegAdminCmd("sm_quickdraft", Command_AutoDraft, ADMFLAG_GENERIC, "Automatically draft teams"); // Alternative
    
    // Admin misc commands
    RegAdminCmd("sm_outline", Command_ToggleOutlines, ADMFLAG_GENERIC, "Toggle teammate outlines for all players");
    RegAdminCmd("sm_outlines", Command_ToggleOutlines, ADMFLAG_GENERIC, "Toggle teammate outlines for all players"); // Plural
    RegAdminCmd("sm_rup", Command_ForceReadyUp, ADMFLAG_GENERIC, "Force both teams ready (testing)");
    RegAdminCmd("sm_ready", Command_ForceReadyUp, ADMFLAG_GENERIC, "Force both teams ready (testing)"); // Intuitive
    RegAdminCmd("sm_forceready", Command_ForceReadyUp, ADMFLAG_GENERIC, "Force both teams ready (testing)"); // Explicit
    
    // Update commands
    RegAdminCmd("sm_updatemix", Command_UpdateMix, ADMFLAG_ROOT, "Download and install plugin updates");
    RegAdminCmd("sm_mixupdate", Command_UpdateMix, ADMFLAG_ROOT, "Download and install plugin updates");
    RegAdminCmd("sm_update", Command_UpdateMix, ADMFLAG_ROOT, "Download and install plugin updates"); // Short version
    
    // Version commands
    RegConsoleCmd("sm_mixversion", Command_MixVersion, "Show current plugin version and update status");
    RegConsoleCmd("sm_version", Command_MixVersion, "Show current plugin version and update status"); // Short version
    RegConsoleCmd("sm_mixver", Command_MixVersion, "Show current plugin version and update status"); // Short version
    RegConsoleCmd("sm_ver", Command_MixVersion, "Show current plugin version and update status"); // Ultra short
    
    // Testing/Development commands
    RegAdminCmd("sm_mixtest", Command_MixTest, ADMFLAG_GENERIC, "Quick test setup: enable cheats, add 11 bots, set you as captain");
    RegAdminCmd("sm_testmix", Command_MixTest, ADMFLAG_GENERIC, "Quick test setup: enable cheats, add 11 bots, set you as captain");
    
    // Public version ConVar for server tracking (FCVAR_NOTIFY | FCVAR_DONTRECORD)
    CreateConVar("sm_mixes_version", "0.3.1", "TF2-Mixes plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    
    g_cvPickTimeout = CreateConVar("sm_mix_pick_timeout", "30.0", "Time limit for picks in seconds");
    g_cvCommandCooldown = CreateConVar("sm_mix_command_cooldown", "5.0", "Cooldown time for commands in seconds");
    g_cvGracePeriod = CreateConVar("sm_mix_grace_period", "60.0", "Time to wait for disconnected captain");
    g_cvTipsEnable = CreateConVar("sm_mix_tips_enable", "1", "Enable rotating mix tips in chat (1/0)");
    g_cvTipsInterval = CreateConVar("sm_mix_tips_interval", "90.0", "Interval in seconds between mix tips");
    
    HookEvent("teamplay_round_start", Event_RoundStart);
    HookEvent("teamplay_round_win", Event_RoundEnd);
    HookEvent("teamplay_game_over", Event_GameOver);
    HookEvent("tf_game_over", Event_GameOver);
    HookEvent("player_team", Event_PlayerTeam);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_PlayerHurt);
    HookEvent("player_changeclass", Event_PlayerChangeClass);
    
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    g_hTipsTimer = CreateTimer(g_cvTipsInterval.FloatValue, Timer_Tips, _, TIMER_REPEAT);
    
    // Hook name change messages to suppress captain name change notifications
    HookUserMessage(GetUserMessageId("SayText2"), OnSayText2, true);
    
    EnsureETF2LWhitelist();
    
    // Check for updates on plugin start
    CreateTimer(5.0, Timer_CheckUpdates);
}

public void OnAllPluginsLoaded() {
    // Check if DM module is loaded
    g_bDMPluginLoaded = LibraryExists("mixes_dm");
    g_bDMAnnounced = false;
}

public void OnLibraryAdded(const char[] name) {
    if (StrEqual(name, "mixes_dm")) {
        if (!g_bDMPluginLoaded) {
            g_bDMPluginLoaded = true;
        }
    }
}

public void OnLibraryRemoved(const char[] name) {
    if (StrEqual(name, "mixes_dm")) {
        g_bDMPluginLoaded = false;
        PrintToServer("[Mix] DM module unloaded - DM features disabled");
    }
}

public void OnPluginEnd() {
    // Kill all timers to prevent leaks
    KillAllTimers();
    
    // Reset to idle state (restores cvars)
    SetMixState(STATE_IDLE);
    
    // Restore all captain names
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && strlen(g_sOriginalNames[i]) > 0) {
            SetClientName(i, g_sOriginalNames[i]);
        }
    }
}

public void OnMapStart() {
    // Reset to idle state
    SetMixState(STATE_IDLE);
    
    // Reset DM announcement each map
    g_bDMAnnounced = false;
    
    // Set waiting for players time
    ConVar cWait = FindConVar("mp_waitingforplayers_time");
    if (cWait != null) {
        SetConVarInt(cWait, 0);
    }


    CreateTimer(2.0, Timer_ShowInfoCard);
}

public void OnClientPutInServer(int client) {
    if (IsValidClient(client)) {
        GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        
        // Handle player reconnection based on current state
        if (g_eCurrentState == STATE_LIVE_GAME || g_eCurrentState == STATE_DRAFT) {
            // Check if this player was disconnected and restore their state
            if (g_bPlayerDisconnected[client]) {
                RestorePlayerState(client);
                return;
            }
        }
        
        if (g_eCurrentState == STATE_IDLE || g_eCurrentState == STATE_PRE_DRAFT) {
            // Normal player joining
            g_bPlayerLocked[client] = false;
        }
        else if (g_eCurrentState == STATE_DRAFT) {
            // New player joining during draft - put them in spectator
            g_bPlayerLocked[client] = false;
            TF2_ChangeClientTeam(client, TFTeam_Spectator);
        }
        
        // Check if we can start draft when new players join
        if ((g_eCurrentState == STATE_IDLE || g_eCurrentState == STATE_PRE_DRAFT) && g_iCaptain1 != -1 && g_iCaptain2 != -1) {
            CheckDraftStart();
        }
    }
}

public void OnClientDisconnect(int client) {
    // Don't use IsValidClient - client is disconnecting so IsClientInGame returns false
    if (client <= 0 || client > MaxClients)
        return;
    
    // Determine which captain (if any) disconnected
    int captainIndex = -1;
    if (client == g_iCaptain1) {
        captainIndex = 0;
        g_iCaptain1 = -1;
    } else if (client == g_iCaptain2) {
        captainIndex = 1;
        g_iCaptain2 = -1;
    }
    
    // Handle captain or regular player disconnection
    if (captainIndex != -1) {
        HandleCaptainDisconnect(client, captainIndex);
    } else {
        HandlePlayerDisconnect(client);
    }
    
    // Reset player state (except for live game and draft preservation)
    if (g_eCurrentState != STATE_LIVE_GAME && g_eCurrentState != STATE_DRAFT) {
        g_bPlayerLocked[client] = false;
        g_bPlayerPicked[client] = false;
    }
}

void HandleCaptainDisconnect(int client, int captainIndex) {
    if (g_eCurrentState == STATE_DRAFT && !IsFakeClient(client)) {
        StartGracePeriod(captainIndex);
    } else if (g_eCurrentState == STATE_PRE_DRAFT) {
        // Check if both captains are now gone
        if (g_iCaptain1 == -1 && g_iCaptain2 == -1) {
            SetMixState(STATE_IDLE);
        }
    }
}

void HandlePlayerDisconnect(int client) {
    if (g_eCurrentState == STATE_LIVE_GAME || g_eCurrentState == STATE_DRAFT) {
        // Preserve player state for reconnection during draft and live game
        if (g_bPlayerPicked[client]) {
            PreservePlayerState(client);
            
            // During draft, check if teams are still balanced
            if (g_eCurrentState == STATE_DRAFT) {
                int redCount, bluCount;
                GetTeamSizes(redCount, bluCount);
                
                // If teams are unbalanced, allow more picks
                if (redCount < TEAM_SIZE || bluCount < TEAM_SIZE) {
                    if (g_iPicksRemaining <= 0) {
                        g_iPicksRemaining = 1;
                    }
                }
            }
        }
    }
}

public Action Command_Captain(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    // Check for replacement captain FIRST (during grace period in draft)
    if (g_eCurrentState == STATE_DRAFT && g_iMissingCaptain != -1) {
        // Assign to the fixed slot (0=RED, 1=BLU) and force correct team
        int slot = g_iMissingCaptain;
        TFTeam slotTeam = (slot == 0) ? TFTeam_Red : TFTeam_Blue;
        TF2_ChangeClientTeam(client, slotTeam);
        g_bPlayerLocked[client] = true;
        g_bPlayerPicked[client] = true;
        
        if (slot == 0) {
            g_iCaptain1 = client;
        } else {
            g_iCaptain2 = client;
        }
        
        if (strlen(g_sOriginalNames[client]) == 0) {
            GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "[CAP] %s", g_sOriginalNames[client]);
        SetClientName(client, newName);
        
        PrintToChatAll("%s\x03%N\x01 is the replacement captain for %s!", MIX_TAG, client, (slot == 0) ? "\x07FF4444RED\x01" : "\x0744A3FFBLU\x01");
        ResumeDraft(); // This will clear g_iMissingCaptain and stop grace timer
        return Plugin_Handled;
    }
    
    float currentTime = GetGameTime();
    float cooldownTime = g_cvCommandCooldown.FloatValue;
    
    if (currentTime - g_fLastCommandTime[client] < cooldownTime) {
        return Plugin_Handled;
    }
    
    g_fLastCommandTime[client] = currentTime;
    
    // Allow captains to drop themselves (except during LIVE_GAME)
    if (client == g_iCaptain1 || client == g_iCaptain2) {
        // Block captain drop during LIVE_GAME
        if (g_eCurrentState == STATE_LIVE_GAME) {
            ReplyToCommand(client, "\x01[Mix] \x03You cannot drop captain status during a live game!");
            return Plugin_Handled;
        }
        
        if (client == g_iCaptain1) {
            g_iCaptain1 = -1;
            SetClientName(client, g_sOriginalNames[client]);
            if (g_eCurrentState == STATE_DRAFT) {
                KillTimerSafely(g_hPickTimer);
                StartGracePeriod(0);
                UpdateHUDForAll();
            }
        } else {
            g_iCaptain2 = -1;
            SetClientName(client, g_sOriginalNames[client]);
            if (g_eCurrentState == STATE_DRAFT) {
                KillTimerSafely(g_hPickTimer);
                StartGracePeriod(1);
                UpdateHUDForAll();
            }
        }
        return Plugin_Handled;
    }
    
    // Block NEW captain selection during DRAFT and LIVE_GAME
    if (g_eCurrentState == STATE_DRAFT || g_eCurrentState == STATE_LIVE_GAME) {
        ReplyToCommand(client, "\x01[Mix] \x03Captain selection is only available before the draft starts!");
        return Plugin_Handled;
    }
    
    if (g_iCaptain1 == -1) {
        g_iCaptain1 = client;
        if (strlen(g_sOriginalNames[client]) == 0) {
            GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "[CAP] %s", g_sOriginalNames[client]);
        SetClientName(client, newName);
        PrintToChatAll("%s\x03%N\x01 is now a captain.", MIX_TAG, client);
    } else if (g_iCaptain2 == -1) {
        g_iCaptain2 = client;
        if (strlen(g_sOriginalNames[client]) == 0) {
            GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "[CAP] %s", g_sOriginalNames[client]);
        SetClientName(client, newName);
        PrintToChatAll("%s\x03%N\x01 is now a captain.", MIX_TAG, client);
    } else {
        ReplyToCommand(client, "\x01[Mix] \x03There are already two captains!");
        return Plugin_Handled;
    }
    
    CheckDraftStart();
    
    return Plugin_Handled;
}

void CheckDraftStart() {
    // Only check during IDLE or PRE_DRAFT states
    if (g_eCurrentState != STATE_IDLE && g_eCurrentState != STATE_PRE_DRAFT) return;
    
    if (g_iCaptain1 == -1 || g_iCaptain2 == -1) {
        return;
    }
    
    // Transition to pre-draft state when captains are selected (if not already there)
    if (g_eCurrentState == STATE_IDLE) {
        SetMixState(STATE_PRE_DRAFT);
    }
    
    // Count total players (including bots)
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i))
            totalPlayers++;
    }
    
    // Check if we have enough players
    if (totalPlayers >= 12) {
        StartDraft();
    }
}

void StartDraft() {
    if (g_eCurrentState != STATE_PRE_DRAFT) return;
    SetMixState(STATE_DRAFT);
    UpdateHUDForAll(); // Force immediate HUD update
}


public Action Command_JoinTeam(int client, const char[] command, int argc) {
    if (!IsValidClient(client)) {
        return Plugin_Continue;
    }
    
    // Allow admins to change teams even during mix
    if (CheckCommandAccess(client, "sm_kick", ADMFLAG_KICK)) {
        return Plugin_Continue;
    }
    
    // State-specific team switching rules
    if (g_eCurrentState == STATE_IDLE || g_eCurrentState == STATE_PRE_DRAFT) {
        return Plugin_Continue; // Allow free team switching
    }
    else if (g_eCurrentState == STATE_DRAFT) {
        return Plugin_Handled;
    }
    else if (g_eCurrentState == STATE_LIVE_GAME) {
        return Plugin_Handled;
    }
    
    return Plugin_Continue;
}

public Action Command_Draft(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (g_eCurrentState != STATE_DRAFT) {
        ReplyToCommand(client, "\x01[Mix] \x03Draft commands are only available during the active draft phase!");
        return Plugin_Handled;
    }
    
    int expectedCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    if (client != expectedCaptain) {
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        if (IsValidClient(currentCaptain)) {
             ReplyToCommand(client, "\x01[Mix] \x03It is %N's turn to pick!", currentCaptain);
        } else {
             ReplyToCommand(client, "\x01[Mix] \x03It is not your turn to pick!");
        }
        return Plugin_Handled;
    }
    
    if (args > 0) {
        char target[32];
        GetCmdArg(1, target, sizeof(target));
        
        int targetClient = FindPlayerByName(target, 0, true);
        
        if (targetClient == -1) {
            ReplyToCommand(client, "\x01[Mix] \x03No matching players found in spectator team.");
            ShowDraftMenu(client);
            return Plugin_Handled;
        }
        
        PickPlayer(client, targetClient);
    } else {
        ShowDraftMenu(client);
    }
    
    return Plugin_Handled;
}

public Action Command_Remove(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;

    if (g_eCurrentState != STATE_DRAFT) {
        ReplyToCommand(client, "\x01[Mix] \x03Remove commands are only available during the active draft phase!");
        return Plugin_Handled;
    }
    
    int expectedCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    if (client != expectedCaptain) {
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        if (IsValidClient(currentCaptain)) {
             ReplyToCommand(client, "\x01[Mix] \x03It is %N's turn to pick!", currentCaptain);
        } else {
             ReplyToCommand(client, "\x01[Mix] \x03It is not your turn to pick!");
        }
        return Plugin_Handled;
    }
    
    if (args > 0) {
        char target[32];
        GetCmdArg(1, target, sizeof(target));
        
        // Find player on captain's team (excluding self)
        int captainTeam = GetClientTeam(client);
        int targetClient = FindPlayerByName(target, captainTeam, false);
        
        // Ensure we didn't find the captain themselves
        if (targetClient == client) {
            targetClient = -1;
        }
        
        if (targetClient == -1) {
            ReplyToCommand(client, "\x01[Mix] \x03No matching players found on your team.");
            ShowRemoveMenu(client);
            return Plugin_Handled;
        }
        
        RemovePlayer(client, targetClient);
    } else {
        ShowRemoveMenu(client);
    }
    
    return Plugin_Handled;
}

void ShowDraftMenu(int client) {
    if (!IsValidClient(client) || !IsClientInGame(client))
        return;
        
    Menu menu = new Menu(DraftMenuHandler, MENU_ACTIONS_ALL);
    menu.SetTitle("Select a player to draft:");
    
    menu.AddItem("random", "Pick Random Player");
    
    ArrayList spectators = new ArrayList();
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && IsClientInGame(i)) {
            int team = GetClientTeam(i);
            if (view_as<TFTeam>(team) == TFTeam_Spectator) {
                spectators.Push(i);
            }
        }
    }
    
    spectators.SortCustom(SortSpectators);
    
    char name[MAX_NAME_LENGTH], info[8], display[MAX_NAME_LENGTH];
    for (int i = 0; i < spectators.Length; i++) {
        int target = spectators.Get(i);
        GetClientName(target, name, sizeof(name));
        IntToString(GetClientUserId(target), info, sizeof(info));
        strcopy(display, sizeof(display), name);
        menu.AddItem(info, display);
    }
    
    delete spectators;
    
    if (menu.ItemCount == 0) {
        menu.AddItem("", "No players available", ITEMDRAW_DISABLED);
    } else {
        menu.ExitButton = true;
    }
    
    menu.Display(client, MENU_TIME_FOREVER);
}

void ShowRemoveMenu(int client) {
    if (!IsValidClient(client) || !IsClientInGame(client))
        return;
        
    Menu menu = new Menu(RemoveMenuHandler, MENU_ACTIONS_ALL);
    menu.SetTitle("Select a player to remove from your team:");
    
    int captainTeam = GetClientTeam(client);
    ArrayList teamPlayers = new ArrayList();
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && GetClientTeam(i) == captainTeam && i != client) {
            teamPlayers.Push(i);
        }
    }
    
    teamPlayers.SortCustom(SortPlayers);
    
    char name[MAX_NAME_LENGTH], info[8], display[MAX_NAME_LENGTH];
    for (int i = 0; i < teamPlayers.Length; i++) {
        int target = teamPlayers.Get(i);
        GetClientName(target, name, sizeof(name));
        IntToString(GetClientUserId(target), info, sizeof(info));
        strcopy(display, sizeof(display), name);
        menu.AddItem(info, display);
    }
    
    delete teamPlayers;
    
    if (menu.ItemCount == 0) {
        menu.AddItem("", "No players on your team to remove", ITEMDRAW_DISABLED);
    } else {
        menu.ExitButton = true;
    }
    
    menu.Display(client, MENU_TIME_FOREVER);
}

public int SortPlayers(int index1, int index2, ArrayList array, Handle hndl) {
    int client1 = array.Get(index1);
    int client2 = array.Get(index2);
    
    char name1[MAX_NAME_LENGTH], name2[MAX_NAME_LENGTH];
    GetClientName(client1, name1, sizeof(name1));
    GetClientName(client2, name2, sizeof(name2));
    
    return strcmp(name1, name2);
}

public int RemoveMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_End: {
            delete menu;
        }
        case MenuAction_Select: {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            
            int target = GetClientOfUserId(StringToInt(info));
            
            if (IsValidClient(target)) {
                RemovePlayer(param1, target);
            } else {
                ReplyToCommand(param1, "\x01[Mix] \x03That player is no longer available!");
                ShowRemoveMenu(param1);
            }
        }
        case MenuAction_Cancel: {
            if (param2 == MenuCancel_Exit) {
            }
        }
    }
    return 0;
}

void RemovePlayer(int captain, int target) {
    if (!IsValidClient(captain) || !IsValidClient(target))
        return;
        
    int captainTeam = GetClientTeam(captain);
    if (GetClientTeam(target) != captainTeam) {
        ReplyToCommand(captain, "\x01[Mix] \x03That player is not on your team!");
        return;
    }
    
    if (target == captain) {
        ReplyToCommand(captain, "\x01[Mix] \x03You cannot remove yourself!");
        return;
    }
    
    // Move player back to spectator
    TF2_ChangeClientTeam(target, TFTeam_Spectator);
    g_bPlayerLocked[target] = false;
    g_bPlayerPicked[target] = false;
    
    g_iPicksRemaining++; // +1 when removing a player
    
    PrintToChatAll("\x01[Mix] \x03%N has been removed from the %s team by %N!", target, (view_as<TFTeam>(captainTeam) == TFTeam_Red) ? "RED" : "BLU", captain);
    
    // Stop countdown if active
    if (g_eCurrentState == STATE_DRAFT) {
        StopCountdown();
    }
    
    // Check if teams are still complete
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    
    if (redCount == TEAM_SIZE && bluCount == TEAM_SIZE) {
        StartCountdown();
        return;
    }
    
    // Ensure we can continue drafting
    if (g_iPicksRemaining <= 0) {
        g_iPicksRemaining = 1;
    }
    
    g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
    int nextCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    
    if (IsValidClient(nextCaptain)) {
        CreateTimer(0.5, Timer_OpenDraftMenu, GetClientUserId(nextCaptain));
    }
    
    KillTimerSafely(g_hPickTimer);
    g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
    g_fPickTimerStartTime = GetGameTime();
    
    UpdateHUDForAll();
}

public int SortSpectators(int index1, int index2, ArrayList array, Handle hndl) {
    int client1 = array.Get(index1);
    int client2 = array.Get(index2);
    
    char name1[MAX_NAME_LENGTH], name2[MAX_NAME_LENGTH];
    GetClientName(client1, name1, sizeof(name1));
    GetClientName(client2, name2, sizeof(name2));
    
    return strcmp(name1, name2);
}

public int DraftMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_End: {
            delete menu;
        }
        case MenuAction_Select: {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            
            if (StrEqual(info, "random")) {
                int randomTarget = -1;
                ArrayList spectators = new ArrayList();
                for (int i = 1; i <= MaxClients; i++) {
                    if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
                        spectators.Push(i);
                    }
                }
                
                if (spectators.Length > 0) {
                    int randomIndex = GetRandomInt(0, spectators.Length - 1);
                    randomTarget = spectators.Get(randomIndex);
                }
                delete spectators;
                
                if (randomTarget != -1) {
                    PickPlayer(param1, randomTarget);
                } else {
                    ReplyToCommand(param1, "\x01[Mix] \x03No players available to pick!");
                    ShowDraftMenu(param1);
                }
                return 0;
            }
            
            int target = GetClientOfUserId(StringToInt(info));
            
            if (IsValidClient(target) && view_as<TFTeam>(GetClientTeam(target)) == TFTeam_Spectator) {
                PickPlayer(param1, target);
            } else {
                ReplyToCommand(param1, "\x01[Mix] \x03That player is no longer available or not in spectator!");
                ShowDraftMenu(param1);
            }
        }
        case MenuAction_Cancel: {
            if (param2 == MenuCancel_Exit) {
            }
        }
    }
    return 0;
}

public void PickPlayer(int captain, int target) {
    if (!IsValidClient(captain) || !IsValidClient(target))
        return;
    
    // Safety: Only allow picks during draft
    if (g_eCurrentState != STATE_DRAFT) {
        return;
    }
        
    if (view_as<TFTeam>(GetClientTeam(target)) != TFTeam_Spectator) {
        ReplyToCommand(captain, "\x01[Mix] \x03That player is not in the spectator team!");
        return;
    }
    
    int team = GetClientTeam(captain);
    
    // Check if captain's team is already full (6 players)
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    
    if ((team == 2 && redCount >= TEAM_SIZE) || (team == 3 && bluCount >= TEAM_SIZE)) {
        ReplyToCommand(captain, "\x01[Mix] \x03Your team is already full! Use !remove to make space first.");
        return;
    }
    
    // Move player to team and ensure they're properly assigned
    TF2_ChangeClientTeam(target, view_as<TFTeam>(team));
    g_bPlayerLocked[target] = true;
    g_bPlayerPicked[target] = true;
    
    // Force team assignment to ensure it sticks
    CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(target));
    
    g_iPicksRemaining--;
    
    PrintToChatAll("%s\x03%N\x01 has been drafted to the %s team!", MIX_TAG, target, (view_as<TFTeam>(team) == TFTeam_Red) ? "\x07FF4444RED\x01" : "\x0744A3FFBLU\x01");
    
    // Check if teams are now complete
    GetTeamSizes(redCount, bluCount);
    
    if (redCount == TEAM_SIZE && bluCount == TEAM_SIZE) {
        StartCountdown();
        return;
    }
    
    if (g_iPicksRemaining <= 0) {
        PrintToChatAll("\x01[Mix] \x03Cannot end draft! Teams must have exactly %d players each.", TEAM_SIZE);
        g_iPicksRemaining = 1; // Keep draft going
        return;
    }
    
    g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
    int nextCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    
    if (IsValidClient(nextCaptain)) {
        CreateTimer(0.5, Timer_OpenDraftMenu, GetClientUserId(nextCaptain));
    }
    
    KillTimerSafely(g_hPickTimer);
    g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
    g_fPickTimerStartTime = GetGameTime();
    
    UpdateHUDForAll();
}

public void EndDraft() {
    // Transition to live game state
    SetMixState(STATE_LIVE_GAME);
}


public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    bool disconnect = event.GetBool("disconnect");
    
    if (!IsValidClient(client) || disconnect)
        return Plugin_Continue;
    
    // Allow admins to change teams even during mix
    if (CheckCommandAccess(client, "sm_kick", ADMFLAG_KICK)) {
        return Plugin_Continue;
    }
    
    // State-specific team switching rules
    if (g_eCurrentState == STATE_IDLE || g_eCurrentState == STATE_PRE_DRAFT) {
        return Plugin_Continue; // Allow free team switching
    }
    else if (g_eCurrentState == STATE_DRAFT) {
        if (IsFakeClient(client)) {
            return Plugin_Continue;
        }
        if (g_bPlayerLocked[client]) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
            return Plugin_Handled;
        }
        if (client != g_iCaptain1 && client != g_iCaptain2) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
            return Plugin_Handled;
        }
        return Plugin_Continue;
    }
    else if (g_eCurrentState == STATE_LIVE_GAME) {
        PrintToChat(client, "\x01[Mix] \x03Teams are locked during the live game!");
        CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        return Plugin_Handled;
    }
    
    return Plugin_Continue;
}


public Action Timer_ForceTeam(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client)) {
        return Plugin_Stop;
    }
    
    // Handle based on current state
    if (g_eCurrentState == STATE_DRAFT) {
        if (IsFakeClient(client) && g_iPicksRemaining > 0) {
            return Plugin_Stop;
        }
        
        int currentTeam = GetClientTeam(client);
        
        if (g_bPlayerLocked[client]) {
            // For locked players, ensure they're on the correct team
            // Priority: Use disconnection data if available (for reconnected players)
            if (g_iDisconnectedPlayerTeam[client] > 0) {
                if (currentTeam != g_iDisconnectedPlayerTeam[client]) {
                    TF2_ChangeClientTeam(client, view_as<TFTeam>(g_iDisconnectedPlayerTeam[client]));
                }
            }
            else if (currentTeam == 0 || currentTeam == 1) { // If they're on spectator/unassigned
                // Find which team they should be on based on captains
                int correctTeam = -1;
                if (IsValidClient(g_iCaptain1)) {
                    correctTeam = GetClientTeam(g_iCaptain1);
                } else if (IsValidClient(g_iCaptain2)) {
                    correctTeam = GetClientTeam(g_iCaptain2);
                }
                
                if (correctTeam != -1) {
                    TF2_ChangeClientTeam(client, view_as<TFTeam>(correctTeam));
                }
            }
            return Plugin_Stop;
        }
        
        if (g_iPicksRemaining > 0 && client != g_iCaptain1 && client != g_iCaptain2) {
            if (view_as<TFTeam>(currentTeam) != TFTeam_Spectator) {
                TF2_ChangeClientTeam(client, TFTeam_Spectator);
            }
            return Plugin_Stop;
        }
    }
    else if (g_eCurrentState == STATE_LIVE_GAME) {
        // Force locked players back to their assigned team
        if (g_bPlayerLocked[client]) {
            // Priority 1: Use disconnection data if available (for reconnected players)
            if (g_iDisconnectedPlayerTeam[client] > 0) {
                TF2_ChangeClientTeam(client, view_as<TFTeam>(g_iDisconnectedPlayerTeam[client]));
            }
            // Priority 2: Keep them on their current team (they're locked there)
            // No action needed - they're already on the right team
        } else {
            // Force non-picked players to spectator
            TF2_ChangeClientTeam(client, TFTeam_Spectator);
        }
    }
    
    return Plugin_Stop;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    if (client == g_iCaptain1 || client == g_iCaptain2) {
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "[CAP] %s", g_sOriginalNames[client]);
        SetClientName(client, newName);
    }
    
    if (g_eCurrentState == STATE_DRAFT && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        }
    }
    
    // Apply outlines if enabled
    if (g_bOutlinesEnabled) {
        TF2_AddCondition(client, view_as<TFCond>(114), 999.0);
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerChangeClass(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    if (g_eCurrentState == STATE_DRAFT && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        }
    }
    
    // Apply outlines if enabled
    if (g_bOutlinesEnabled) {
        TF2_AddCondition(client, view_as<TFCond>(114), 999.0);
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    if (g_eCurrentState == STATE_DRAFT && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        }
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast) {
    return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    return Plugin_Continue;
}


public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // Don't interfere with state machine - EnterIdleState already handles everything
    return Plugin_Continue;
}

public Action Event_GameOver(Event event, const char[] name, bool dontBroadcast) {
    // Event doesn't fire reliably on all servers - using Event_RoundEnd instead
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    // Only handle if we're in a live game
    if (g_eCurrentState == STATE_LIVE_GAME) {
        // Check if this is a win condition (game over)
        int winner = event.GetInt("team");
        
        if (winner == 2 || winner == 3) { // Red or Blue won
            // Read scores from GameRules (not from event!)
            int redScore = GetTeamScore(2);
            int bluScore = GetTeamScore(3);
            int winLimit = IsKothMap() ? 4 : 5;
            
            if ((winner == 2 && redScore >= winLimit) || (winner == 3 && bluScore >= winLimit)) {
                // GAME IS OVER! Transition to POST_GAME state
                CreateTimer(2.0, Timer_TransitionToPostGame);
            }
            // No need to restart - tournament mode handles it automatically
        }
    }
    
    return Plugin_Continue;
}


public Action Timer_ForceTeamsReady(Handle timer) {
    // Force both teams to ready state using GameRules
    GameRules_SetProp("m_bTeamReady", 1, .element=2);  // RED team ready
    GameRules_SetProp("m_bTeamReady", 1, .element=3);  // BLU team ready
    return Plugin_Stop;
}

public Action Timer_TransitionToPostGame(Handle timer) {
    if (g_eCurrentState == STATE_LIVE_GAME) {
        SetMixState(STATE_POST_GAME);
    }
    return Plugin_Stop;
}

public Action Timer_ShowPostGameVote(Handle timer) {
    // Only show vote if still in post-game state
    if (g_eCurrentState != STATE_POST_GAME) {
        return Plugin_Stop;
    }
    
    // Reset vote counts and start time
    g_iVoteCount[0] = 0;
    g_iVoteCount[1] = 0;
    g_fVoteStartTime = GetGameTime();
    
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerVoted[i] = false;
        if (IsValidClient(i) && !IsFakeClient(i)) {
            ShowPostGameVoteToClient(i);
        }
    }
    
    // Start 30-second vote timer
    KillTimerSafely(g_hVoteTimer);
    g_hVoteTimer = CreateTimer(30.0, Timer_EndPostGameVote);
    
    return Plugin_Stop;
}

void ShowPostGameVoteToClient(int client) {
    Menu menu = new Menu(PostGameVoteHandler);
    menu.SetTitle("Game Over - What next?");
    menu.AddItem("redraft", "New Draft (reset everything)");
    menu.AddItem("rematch", "Rematch (same teams)");
    menu.ExitButton = false;
    menu.Display(client, 30);
}

public int PostGameVoteHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        if (g_bPlayerVoted[param1]) return 0;
                
            g_bPlayerVoted[param1] = true;
            
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            
        if (StrEqual(info, "redraft")) {
                g_iVoteCount[0]++;
        } else if (StrEqual(info, "rematch")) {
                g_iVoteCount[1]++;
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

public Action Timer_EndPostGameVote(Handle timer) {
    g_hVoteTimer = INVALID_HANDLE;
    g_fVoteStartTime = 0.0;
    
    int totalVotes = g_iVoteCount[0] + g_iVoteCount[1];
    
    if (totalVotes == 0 || g_iVoteCount[0] >= g_iVoteCount[1]) {
        // New draft wins (or tie/no votes)
        PrintToChatAll("\x01[Mix] \x03Vote result: Starting new draft!");
        SetMixState(STATE_IDLE);
    } else {
        // Rematch wins
        PrintToChatAll("\x01[Mix] \x03Vote result: Rematch with same teams!");
        
        // Reset team scores for fresh rematch
        SetTeamScore(2, 0);
        SetTeamScore(3, 0);
        
        // Transition back to LIVE_GAME state for the rematch
        SetMixState(STATE_LIVE_GAME);
        
        // Let players ready up manually (F4) - gives them a break
        PrintToChatAll("\x01[Mix] \x03Press F4 when ready to start the rematch!");
    }
    
    return Plugin_Stop;
}

public Action Timer_ShowDraftCompleteMessage(Handle timer) {
    if (IsKothMap()) {
        PrintToChatAll("%s\x03Draft complete!\x01 Mix has started (ETF2L 6v6, KOTH - First to 4).", MIX_TAG);
    } else {
        PrintToChatAll("%s\x03Draft complete!\x01 Mix has started (ETF2L 6v6, 5CP - First to 5).", MIX_TAG);
    }
    return Plugin_Stop;
}


public Action Timer_ReenableDM(Handle timer) {
    if (g_bDMPluginLoaded) {
        DM_SetDraftInProgress(false);
        DM_SetPreGameActive(true);
    }
    return Plugin_Stop;
}



void UpdateHUDForAll() {
    char buffer[512];
    
    if (g_eCurrentState == STATE_IDLE) {
        Format(buffer, sizeof(buffer), "Type !captain to become a captain");
    }
    else if (g_eCurrentState == STATE_PRE_DRAFT) {
        // Count total players
        int totalPlayers = 0;
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i)) totalPlayers++;
        }
        Format(buffer, sizeof(buffer), "Need at least 12 players to start drafting\nCurrent players: %d", totalPlayers);
    }
    else if (g_eCurrentState == STATE_POST_GAME) {
        // Show vote status if vote is active
        if (g_hVoteTimer != INVALID_HANDLE && g_fVoteStartTime > 0.0) {
            float timeLeft = 30.0 - (GetGameTime() - g_fVoteStartTime);
            if (timeLeft < 0.0) timeLeft = 0.0;
            
            Format(buffer, sizeof(buffer), "GAME OVER - VOTE IN PROGRESS\nNew Draft: %d | Rematch: %d\nTime: %.0fs", 
                   g_iVoteCount[0], g_iVoteCount[1], timeLeft);
        } else {
            buffer[0] = '\0'; // Clear HUD when vote is done
        }
    }
    else if (g_eCurrentState == STATE_DRAFT) {
        if (g_iMissingCaptain != -1) {
            float timeLeft = g_cvGracePeriod.FloatValue - (GetGameTime() - g_fPickTimerStartTime);
            if (timeLeft < 0.0) timeLeft = 0.0;
            
            char captainName[MAX_NAME_LENGTH];
            if (g_iMissingCaptain == 0) {
                strcopy(captainName, sizeof(captainName), "First Captain");
            } else {
                strcopy(captainName, sizeof(captainName), "Second Captain");
            }
            
            Format(buffer, sizeof(buffer), "DRAFT PAUSED\n%s dropped!\nReplacement needed: %.0fs", captainName, timeLeft);
        }
        else if (g_iPicksRemaining > 0) {
            int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
            char captainName[MAX_NAME_LENGTH];
            
            if (IsValidClient(currentCaptain)) {
                GetClientName(currentCaptain, captainName, sizeof(captainName));
            } else {
                strcopy(captainName, sizeof(captainName), "Unknown Captain");
            }
            
            float timeLeft = g_cvPickTimeout.FloatValue - (GetGameTime() - g_fPickTimerStartTime);
            if (timeLeft < 0.0) timeLeft = 0.0;
            
            // Count actual team sizes
            int redTeamSize, bluTeamSize;
            GetTeamSizes(redTeamSize, bluTeamSize);
            
            // Highlight the team whose turn it is to pick
            int captainTeam = GetClientTeam(currentCaptain);
            char redStr[32], bluStr[32];
            if (captainTeam == 2) { // RED team picking
                Format(redStr, sizeof(redStr), "[RED %d/%d]", redTeamSize, TEAM_SIZE);
                Format(bluStr, sizeof(bluStr), "BLU %d/%d", bluTeamSize, TEAM_SIZE);
            } else { // BLU team picking
                Format(redStr, sizeof(redStr), "RED %d/%d", redTeamSize, TEAM_SIZE);
                Format(bluStr, sizeof(bluStr), "[BLU %d/%d]", bluTeamSize, TEAM_SIZE);
            }
            
            Format(buffer, sizeof(buffer), "DRAFT IN PROGRESS\n%s's pick\nTime: %.0fs\n%s - %s", 
                   captainName, timeLeft, redStr, bluStr);
        }
        else if (g_iCountdownSeconds > 0) {
            Format(buffer, sizeof(buffer), "GAME STARTING IN %d SECONDS...", g_iCountdownSeconds);
        }
        else {
            buffer[0] = '\0';
        }
    }
    else if (g_eCurrentState == STATE_LIVE_GAME) {
        // Don't show hint text during live game
        buffer[0] = '\0';
    }
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i)) {
            PrintHintText(i, "%s", buffer);
        }
    }
}

public Action Timer_UpdateHUD(Handle timer) {
    UpdateHUDForAll();
    return Plugin_Continue;
}

public Action Timer_Tips(Handle timer) {
    if (!GetConVarBool(g_cvTipsEnable)) {
        return Plugin_Continue;
    }
    
    // Only show tips during idle and pre-draft states
    if (g_eCurrentState == STATE_IDLE || g_eCurrentState == STATE_PRE_DRAFT) {
        const int TIP_COUNT = 3;
        char tip[128];
        switch (g_iTipIndex % TIP_COUNT) {
            case 0: strcopy(tip, sizeof(tip), "\x03!captain \x01- Volunteer/drop as captain");
            case 1: strcopy(tip, sizeof(tip), "\x03!pick <name> \x01- Draft a player");
            case 2: strcopy(tip, sizeof(tip), "\x03!help \x01- Show commands");
        }
        g_iTipIndex++;
        
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && !IsFakeClient(i)) {
                PrintToChat(i, "%s%s", MIX_TAG, tip);
            }
        }
    }
    
    return Plugin_Continue;
}
    

public Action Timer_GracePeriod(Handle timer) {
    if (g_eCurrentState != STATE_DRAFT) {
        return Plugin_Stop;
    }
    
    // If grace timer is still running but no missing captain, it means replacement was found
    if (g_iMissingCaptain == -1) {
        return Plugin_Stop;
    }
    
    float currentTime = GetGameTime();
    float timeLeft = g_cvGracePeriod.FloatValue - (currentTime - g_fPickTimerStartTime);
    
    if (timeLeft <= 0.0) {
        SetMixState(STATE_IDLE);
        return Plugin_Stop;
    }
    
    return Plugin_Continue;
}

// Helper function to find next available player
int FindNextAvailablePlayer() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator && i != g_iCaptain1 && i != g_iCaptain2) {
            return i;
        }
    }
    return -1;
}


void StartGracePeriod(int missingCaptain) {
    if (g_eCurrentState != STATE_DRAFT) return;
    
    // Check if both captains are now missing
    if (g_iCaptain1 == -1 && g_iCaptain2 == -1) {
        SetMixState(STATE_IDLE);
        return;
    }
    
    // If already in grace period for the same captain, don't restart
        if (g_iMissingCaptain == missingCaptain) return;
    
    // If already in grace period for different captain, both are now gone
    if (g_iMissingCaptain != -1) {
        SetMixState(STATE_IDLE);
        return;
    }
    
    // Save current draft state before entering grace period
    g_iSavedCurrentPicker = g_iCurrentPicker;
    g_iSavedPicksRemaining = g_iPicksRemaining;
    g_fSavedPickTimerStartTime = g_fPickTimerStartTime;
    
    // Save countdown state if active
    if (g_iCountdownSeconds > 0) {
        g_iSavedCountdownSeconds = g_iCountdownSeconds;
        g_iCountdownSeconds = 0;
        KillTimerSafely(g_hCountdownTimer);
    }
    
    g_iMissingCaptain = missingCaptain;
    
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hGraceTimer);
    
    g_fPickTimerStartTime = GetGameTime();
    g_hGraceTimer = CreateTimer(1.0, Timer_GracePeriod, _, TIMER_REPEAT);
    
    // Ensure HUD timer is running
    if (g_hHudTimer == INVALID_HANDLE) {
        g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
    
    UpdateHUDForAll();
    
    PrintToChatAll("%s\x07FF4444Captain left!\x01 Type !captain to replace (\x03%.0fs\x01).", MIX_TAG, g_cvGracePeriod.FloatValue);
}

void ResumeDraft() {
    if (g_eCurrentState != STATE_DRAFT) return;
    
    KillTimerSafely(g_hGraceTimer);
    
    // Restore saved draft state
    g_iCurrentPicker = g_iSavedCurrentPicker;
    g_iPicksRemaining = g_iSavedPicksRemaining;
    g_fPickTimerStartTime = g_fSavedPickTimerStartTime;
    g_iMissingCaptain = -1;
    
    // Restore countdown state if it was active
    if (g_iSavedCountdownSeconds > 0) {
        g_iCountdownSeconds = g_iSavedCountdownSeconds;
        g_iSavedCountdownSeconds = 0;
        g_hCountdownTimer = CreateTimer(1.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    } else {
        // Resume pick timer with fresh timeout
        KillTimerSafely(g_hPickTimer);
        g_fPickTimerStartTime = GetGameTime();
        g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
        
        // Open draft menu for current captain
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        if (IsValidClient(currentCaptain) && !IsFakeClient(currentCaptain)) {
            CreateTimer(0.5, Timer_OpenDraftMenu, GetClientUserId(currentCaptain));
        }
    }
    
    // Ensure HUD timer is running
    if (g_hHudTimer == INVALID_HANDLE) {
        g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
    
    UpdateHUDForAll();
}

public Action OnSayText2(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init) {
    char message[256];
    msg.ReadString(message, sizeof(message));
    
    if (StrContains(message, "changed name to") != -1) {
        return Plugin_Handled;
    }
    
    return Plugin_Continue;
}

public Action Command_RestartDraft(int client, int args) {
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Handled;
        
    // Don't allow during post-game vote (use the menu instead)
    if (g_eCurrentState == STATE_POST_GAME && g_hVoteTimer != INVALID_HANDLE) {
        ReplyToCommand(client, "\x01[Mix] \x03Please use the vote menu that's currently open!");
        return Plugin_Handled;
    }
    
    // Count total real players
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i)) {
            totalPlayers++;
        }
    }
    
    if (totalPlayers < 1) {
        ReplyToCommand(client, "\x01[Mix] \x03Not enough players to start a vote!");
        return Plugin_Handled;
    }
    
    // Calculate 2/3 requirement (minimum 1 for solo testing)
    int requiredVotes = RoundToCeil(float(totalPlayers) * (2.0 / 3.0));
    if (requiredVotes < 1) requiredVotes = 1;
    
    // Check if already voted
    if (g_bRestartVote[client]) {
        ReplyToCommand(client, "\x01[Mix] \x03You have already voted to restart!");
        return Plugin_Handled;
    }
    
    // Mark vote
    g_bRestartVote[client] = true;
    
    // Count current votes
    int currentVotes = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i) && g_bRestartVote[i]) {
            currentVotes++;
        }
    }
    
    // Show progress
    PrintToChatAll("\x01[Mix] \x03%N voted to restart the mix! (%d/%d votes)", client, currentVotes, requiredVotes);
    
    // Check if we have enough votes
    if (currentVotes >= requiredVotes) {
        PrintToChatAll("\x01[Mix] \x03Vote passed! Resetting mix...");
        
        // Reset votes
        for (int i = 1; i <= MaxClients; i++) {
            g_bRestartVote[i] = false;
        }
        KillTimerSafely(g_hRestartVoteResetTimer);
        
        // Reset to IDLE
        SetMixState(STATE_IDLE);
    } else {
        // Start/restart 60 second reset timer
        KillTimerSafely(g_hRestartVoteResetTimer);
        g_hRestartVoteResetTimer = CreateTimer(60.0, Timer_ResetRestartVotes);
    }
    
    return Plugin_Handled;
}

public Action Timer_ResetRestartVotes(Handle timer) {
    g_hRestartVoteResetTimer = INVALID_HANDLE;
    
    // Reset all votes
    for (int i = 1; i <= MaxClients; i++) {
        g_bRestartVote[i] = false;
    }
    
    return Plugin_Stop;
}


void CancelMix(int admin) {
    // Transition to idle state (applies all idle cvars)
    SetMixState(STATE_IDLE);
    
    if (admin == -1) {
        PrintToChatAll("\x01[Mix] \x03Mix has been cancelled by vote! Teams are now unlocked.");
    } else {
        PrintToChatAll("\x01[Mix] \x03Mix has been cancelled by admin %N! Teams are now unlocked.", admin);
    }
}


public Action Command_AutoDraft(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!CheckCommandAccess(client, "sm_autodraft", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    if (g_eCurrentState != STATE_DRAFT) {
        ReplyToCommand(client, "\x01[Mix] \x03No draft is currently in progress!");
        return Plugin_Handled;
    }
    
    if (!IsValidClient(g_iCaptain1) || !IsValidClient(g_iCaptain2)) {
         ReplyToCommand(client, "\x01[Mix] \x03Cannot auto-draft, captains are not set or invalid!");
         return Plugin_Handled;
    }
    
    int picksToMake = g_iPicksRemaining;
    if (picksToMake <= 0) {
         ReplyToCommand(client, "\x01[Mix] \x03Draft is already complete!");
         return Plugin_Handled;
    }
    
    ArrayList spectators = new ArrayList();
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
            spectators.Push(i);
        }
    }
    
    if (spectators.Length == 0) {
        ReplyToCommand(client, "\x01[Mix] \x03No players available to auto-draft from spectator!");
        delete spectators;
        return Plugin_Handled;
    }
    
    int draftedCount = 0;
    
    while (g_iPicksRemaining > 0 && spectators.Length > 0) {
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        int team = GetClientTeam(currentCaptain);
        
        // Check if current captain's team is full
        int redCount, bluCount;
        GetTeamSizes(redCount, bluCount);
        
        if ((team == 2 && redCount >= TEAM_SIZE) || (team == 3 && bluCount >= TEAM_SIZE)) {
            // Current captain's team is full, switch to next captain
            g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
            currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
            team = GetClientTeam(currentCaptain);
            
            // Re-check after switch
            GetTeamSizes(redCount, bluCount);
            if ((team == 2 && redCount >= TEAM_SIZE) || (team == 3 && bluCount >= TEAM_SIZE)) {
                break; // Both teams are full
            }
        }
        
        // Pick random player from spectators
        int randomIndex = GetRandomInt(0, spectators.Length - 1);
        int targetClient = spectators.Get(randomIndex);
        spectators.Erase(randomIndex);
        
        // Perform the pick (duplicate core PickPlayer logic for autodraft)
        TF2_ChangeClientTeam(targetClient, view_as<TFTeam>(team));
        g_bPlayerLocked[targetClient] = true;
        g_bPlayerPicked[targetClient] = true;
        g_iPicksRemaining--;
        
        // Switch picker for next iteration
        g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
        
        draftedCount++;
    }
    
    delete spectators;
    
    // Check if teams are now complete
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    
    if (redCount == TEAM_SIZE && bluCount == TEAM_SIZE) {
        StartCountdown();
    }
    
    UpdateHUDForAll();
    
    ReplyToCommand(client, "\x01[Mix] \x03Auto-drafted %d players.", draftedCount);
    
    return Plugin_Handled;
}

void KillAllTimers() {
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hGraceTimer);
    KillTimerSafely(g_hHudTimer);
    KillTimerSafely(g_hVoteTimer);
    KillTimerSafely(g_hCountdownTimer);
    KillTimerSafely(g_hTipsTimer);
    KillTimerSafely(g_hNotificationTimer);
    KillTimerSafely(g_hRestartVoteResetTimer);
}


// Add these functions at the end of the file
public Action Command_SetCaptain(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    // Block during live game only
    if (g_eCurrentState == STATE_LIVE_GAME) {
        ReplyToCommand(client, "\x01[Mix] \x03Cannot change captains during a live game!");
        return Plugin_Handled;
    }
        
    if (args < 1) {
        ReplyToCommand(client, "\x01[Mix] \x03Usage: sm_setcaptain <player>");
        return Plugin_Handled;
    }
    
    char target[32];
    GetCmdArg(1, target, sizeof(target));
    
    int targetClient = FindPlayerByName(target, 0, false);
    
    if (targetClient == -1) {
        ReplyToCommand(client, "\x01[Mix] \x03Could not find target player.");
        return Plugin_Handled;
    }
    
    if (targetClient == g_iCaptain1 || targetClient == g_iCaptain2) {
        if (targetClient == g_iCaptain1) {
            g_iCaptain1 = -1;
            SetClientName(targetClient, g_sOriginalNames[targetClient]);
            if (g_eCurrentState == STATE_DRAFT) {
                StartGracePeriod(0);
            }
        } else {
            g_iCaptain2 = -1;
            SetClientName(targetClient, g_sOriginalNames[targetClient]);
            if (g_eCurrentState == STATE_DRAFT) {
                StartGracePeriod(1);
            }
        }
        return Plugin_Handled;
    }
    
    if (g_iCaptain1 != -1 && g_iCaptain2 != -1) {
        ReplyToCommand(client, "\x01[Mix] \x03There are already two captains!");
        return Plugin_Handled;
    }
    
    if (g_iCaptain1 == -1) {
        g_iCaptain1 = targetClient;
        if (strlen(g_sOriginalNames[targetClient]) == 0) {
            GetClientName(targetClient, g_sOriginalNames[targetClient], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "[CAP] %s", g_sOriginalNames[targetClient]);
        SetClientName(targetClient, newName);
        // Force slot team during draft/pre-draft
        if (g_eCurrentState == STATE_DRAFT || g_eCurrentState == STATE_PRE_DRAFT) {
            TF2_ChangeClientTeam(targetClient, TFTeam_Red);
            g_bPlayerLocked[targetClient] = true;
            g_bPlayerPicked[targetClient] = true;
        }
        PrintToChatAll("%s\x03%N\x01 is now a captain.", MIX_TAG, targetClient);
    } else {
        g_iCaptain2 = targetClient;
        if (strlen(g_sOriginalNames[targetClient]) == 0) {
            GetClientName(targetClient, g_sOriginalNames[targetClient], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "[CAP] %s", g_sOriginalNames[targetClient]);
        SetClientName(targetClient, newName);
        if (g_eCurrentState == STATE_DRAFT || g_eCurrentState == STATE_PRE_DRAFT) {
            TF2_ChangeClientTeam(targetClient, TFTeam_Blue);
            g_bPlayerLocked[targetClient] = true;
            g_bPlayerPicked[targetClient] = true;
        }
        PrintToChatAll("%s\x03%N\x01 is now a captain.", MIX_TAG, targetClient);
    }
    
    CheckDraftStart();
    
    return Plugin_Handled;
}

public Action Command_AdminPick(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!CheckCommandAccess(client, "sm_adminpick", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
        
    if (g_eCurrentState != STATE_DRAFT) {
        ReplyToCommand(client, "\x01[Mix] \x03No draft is currently in progress!");
        return Plugin_Handled;
    }
    
    if (args < 1) {
        ReplyToCommand(client, "\x01[Mix] \x03Usage: sm_adminpick <player>");
        return Plugin_Handled;
    }
    
    char target[32];
    GetCmdArg(1, target, sizeof(target));
    
    int targetClient = FindPlayerByName(target, 0, true);
    
    if (targetClient == -1) {
        ReplyToCommand(client, "\x01[Mix] \x03No matching players found in spectator team.");
        return Plugin_Handled;
    }
    
    int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    if (!IsValidClient(currentCaptain)) {
        ReplyToCommand(client, "\x01[Mix] \x03Current captain is not valid!");
        return Plugin_Handled;
    }
    
    int team = GetClientTeam(currentCaptain);
    
    // Check if captain's team is full
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    if ((team == 2 && redCount >= TEAM_SIZE) || (team == 3 && bluCount >= TEAM_SIZE)) {
        ReplyToCommand(client, "\x01[Mix] \x03Captain's team is already full!");
        return Plugin_Handled;
    }
    
    TF2_ChangeClientTeam(targetClient, view_as<TFTeam>(team));
    g_bPlayerLocked[targetClient] = true;
    g_bPlayerPicked[targetClient] = true;
    
    g_iPicksRemaining--;
    
    PrintToChatAll("%s\x03Admin %N\x01 has picked \x03%N\x01 for the %s team!", MIX_TAG, client, targetClient, (view_as<TFTeam>(team) == TFTeam_Red) ? "\x07FF4444RED\x01" : "\x0744A3FFBLU\x01");
    
    // Check if teams are now complete
    GetTeamSizes(redCount, bluCount);
    
    if (redCount == TEAM_SIZE && bluCount == TEAM_SIZE) {
        StartCountdown();
        return Plugin_Handled;
    }
    
    if (g_iPicksRemaining <= 0) {
        PrintToChatAll("\x01[Mix] \x03Cannot end draft! Teams must have exactly %d players each.", TEAM_SIZE);
        g_iPicksRemaining = 1; // Keep draft going
        return Plugin_Handled;
    }
    
    g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
    
    KillTimerSafely(g_hPickTimer);
    g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
    g_fPickTimerStartTime = GetGameTime();
    
    UpdateHUDForAll();
    
    return Plugin_Handled;
}

public Action Command_CancelMix(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!CheckCommandAccess(client, "sm_cancelmix", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    if (g_eCurrentState == STATE_IDLE) {
        ReplyToCommand(client, "\x01[Mix] \x03No mix is currently in progress!");
        return Plugin_Handled;
    }
    
    CancelMix(client);
    return Plugin_Handled;
}

public Action Command_HelpMix(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    float currentTime = GetGameTime();
    if (currentTime - g_fLastCommandTime[client] < 5.0) {
        ReplyToCommand(client, "\x01[Mix] \x03Please wait before using this command again.");
        return Plugin_Handled;
    }
    g_fLastCommandTime[client] = currentTime;
    
    ShowHelpMenu(client);
    return Plugin_Handled;
}


public Action Timer_PickTimeout(Handle timer) {
    if (g_eCurrentState != STATE_DRAFT) {
        return Plugin_Stop;
    }
        
    int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    
    if (!IsValidClient(currentCaptain)) {
        PrintToChatAll("\x01[Mix] \x03Captain unavailable. Ending draft.");
        EndDraft();
        return Plugin_Stop;
    }
    
    // Check team sizes
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    
    // If both teams are full, end draft
    if (redCount >= TEAM_SIZE && bluCount >= TEAM_SIZE) {
        EndDraft();
        return Plugin_Stop;
    }
    
    // If current captain's team is full, skip to next captain
    int captainTeam = GetClientTeam(currentCaptain);
    if ((captainTeam == 2 && redCount >= TEAM_SIZE) || (captainTeam == 3 && bluCount >= TEAM_SIZE)) {
        g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
        int nextCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        
        if (IsValidClient(nextCaptain)) {
            PrintToChatAll("\x01[Mix] \x03%N's team is full! Skipping to %N's turn.", currentCaptain, nextCaptain);
            CreateTimer(0.5, Timer_OpenDraftMenu, GetClientUserId(nextCaptain));
            // Start new timer for next captain (current timer will be cleaned up by Plugin_Stop)
            g_hPickTimer = INVALID_HANDLE; // Mark as invalid before Plugin_Stop cleans it up
            CreateTimer(0.1, Timer_StartNewPickTimer); // Start new timer after this callback ends
            g_fPickTimerStartTime = GetGameTime();
        } else {
            EndDraft();
        }
        return Plugin_Stop;
    }
    
    // Auto-pick random player
    int randomPlayer = FindNextAvailablePlayer();
    if (randomPlayer != -1) {
        // Mark timer as invalid before calling PickPlayer to prevent double-free
        g_hPickTimer = INVALID_HANDLE;
        PickPlayer(currentCaptain, randomPlayer);
    } else {
        EndDraft();
    }
    
    return Plugin_Stop;
}


public Action Timer_OpenDraftMenu(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client) || g_eCurrentState != STATE_DRAFT || g_iPicksRemaining <= 0) {
        return Plugin_Stop;
    }
    
    int expectedCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    if (client != expectedCaptain) {
        return Plugin_Stop;
    }
    
    ShowDraftMenu(client);
    
    return Plugin_Stop;
}

public Action Timer_StartNewPickTimer(Handle timer) {
    // Start new pick timer (called after previous timer callback ends)
    if (g_eCurrentState == STATE_DRAFT && g_hPickTimer == INVALID_HANDLE) {
        g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
    }
    return Plugin_Stop;
}

void EnsureETF2LWhitelist() {
    if (FileExists(ETF2L_WHITELIST_PATH)) {
        return;
    }
    File file = OpenFile(ETF2L_WHITELIST_PATH, "w");
    if (file == null) {
        PrintToServer("[Mix] Failed to create ETF2L whitelist at %s", ETF2L_WHITELIST_PATH);
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && CheckCommandAccess(i, "sm_kick", ADMFLAG_KICK)) {
                PrintToChat(i, "\x01[Mix] \x03Warning: failed to create ETF2L whitelist at %s", ETF2L_WHITELIST_PATH);
            }
        }
        return;
    }
    file.WriteLine("// Whitelist generated by TF2-Mixes (ETF2L 6v6)");
    file.WriteLine("\"item_whitelist\"");
    file.WriteLine("{");
    file.WriteLine("\t\"unlisted_items_default_to\"\t\t\"1\"");
    static const char items[][] = {
        "The Reserve Shooter",
        "Bonk! Atomic Punch",
        "Crit-a-Cola",
        "Festive Bonk 2014",
        "Mad Milk",
        "Mutated Milk",
        "Pretty Boy's Pocket Pistol",
        "Promo Flying Guillotine",
        "The Flying Guillotine",
        "The Soda Popper",
        "The Wrap Assassin",
        "The Battalion's Backup",
        "The Cow Mangler 5000",
        "The Disciplinary Action",
        "The Market Gardener",
        "The Detonator",
        "The Gas Passer",
        "The Scorch Shot",
        "The Loch-n-Load",
        "The Quickiebomb Launcher",
        "Deflector",
        "Fists of Steel",
        "Natascha",
        "Festive Wrangler",
        "The Giger Counter",
        "The Rescue Ranger",
        "The Short Circuit",
        "The Wrangler",
        "The Quick-Fix",
        "The Vaccinator",
        "Festive Jarate",
        "Jarate",
        "Shooting Star",
        "The Machina",
        "The Self-Aware Beauty Mark",
        "The Sydney Sleeper",
        "The Diamondback",
        "Activated Campaign 3 Pass",
        "Nose Candy",
        "Yeti Park Cap",
        "The Corpse Carrier",
        "The Sprinting Cephalopod",
        "Charity Noise Maker - Bell",
        "Charity Noise Maker - Tingsha",
        "Halloween Noise Maker - Banshee",
        "Halloween Noise Maker - Black Cat",
        "Halloween Noise Maker - Crazy Laugh",
        "Halloween Noise Maker - Gremlin",
        "Halloween Noise Maker - Stabby",
        "Halloween Noise Maker - Werewolf",
        "Halloween Noise Maker - Witch",
        "Noise Maker - TF Birthday",
        "Noise Maker - Vuvuzela",
        "Noise Maker - Winter 2011",
        "Promotional Noise Maker - Fireworks",
        "Promotional Noise Maker - Koto",
        "Autogrant Pyrovision Goggles",
        "Pet Balloonicorn",
        "Pet Reindoonicorn",
        "Pyrovision Goggles",
        "The Burning Bongos",
        "The Infernal Orchestrina",
        "The Lollichop",
        "The Rainblower",
        "Elf-Made Bandanna",
        "Jolly Jingler",
        "Reindoonibeanie",
        "Seasonal Employee",
        "The Bootie Time",
        "Elf Defence",
        "Elf Ignition",
        "The Jingle Belt",
        "Elf Care Provider",
        "Conga Taunt",
        "Flippin' Awesome Taunt",
        "High Five Taunt",
        "RPS Taunt",
        "Skullcracker Taunt",
        "Square Dance Taunt",
        "Taunt: Kazotsky Kick",
        "Taunt: Mannrobics",
        "Taunt: The Fist Bump",
        "Taunt: The Scaredy-cat!",
        "Taunt: The Victory Lap",
        "Taunt: Zoomin' Broom",
        "Taunt: Runner's Rhythm",
        "Taunt: Spin-to-Win",
        "Taunt: The Boston Boarder",
        "Taunt: The Bunnyhopper",
        "Taunt: The Carlton",
        "Taunt: The Homerunner's Hobby",
        "Taunt: The Scooty Scoot",
        "Taunt: Neck Snap",
        "Taunt: Panzer Pants",
        "Taunt: Rocket Jockey",
        "Pool Party Taunt",
        "Taunt: Roasty Toasty",
        "Taunt: Scorcher's Solo",
        "Taunt: The Balloonibouncer",
        "Taunt: The Hot Wheeler",
        "Taunt: The Skating Scorcher",
        "Taunt: Drunk Mann's Cannon",
        "Taunt: Scotsmann's Stagger",
        "Taunt: Shanty Shipmate",
        "Taunt: The Drunken Sailor",
        "Taunt: The Pooped Deck",
        "Taunt: Bare Knuckle Beatdown",
        "Taunt: Russian Rubdown",
        "Taunt: The Boiling Point",
        "Taunt: The Road Rager",
        "Taunt: The Russian Arms Race",
        "Taunt: The Soviet Strongarm",
        "Taunt: The Table Tantrum",
        "Rancho Relaxo Taunt",
        "Taunt: Bucking Bronco",
        "Taunt: Texas Truckin",
        "Taunt: The Dueling Banjo",
        "Taunt: The Jumping Jack",
        "Taunt: Surgeon's Squeezebox",
        "Taunt: The Mannbulance!",
        "Taunt: Time Out Therapy",
        "Taunt: Didgeridrongo",
        "Taunt: Shooter's Stakeout",
        "Taunt: Luxury Lounge",
        "Taunt: Tailored Terminal",
        "Taunt: The Boxtrot",
        "Taunt: The Crypt Creeper",
        "Taunt: The Travel Agent",
        "Taunt: Tuefort Tango"
    };
    for (int i = 0; i < sizeof(items); i++) {
        char line[256];
        Format(line, sizeof(line), "\t\"%s\"\t\t\"0\"", items[i]);
        file.WriteLine(line);
    }
    file.WriteLine("}");
    delete file;
}

// Silent cvar setters to avoid chat spam
void SetCvarInt(const char[] name, int value) {
    ConVar c = FindConVar(name);
    if (c != null) {
        // Temporarily remove FCVAR_NOTIFY to suppress chat spam
        int flags = c.Flags;
        c.Flags &= ~FCVAR_NOTIFY;
        SetConVarInt(c, value);
        c.Flags = flags; // Restore original flags
    } else {
        char cmd[64];
        Format(cmd, sizeof(cmd), "%s %d", name, value);
        ServerCommand(cmd);
    }
}

void ServerCommandSilent(const char[] cmd) {
    // Parse command to extract cvar name
    char parts[2][64];
    int count = ExplodeString(cmd, " ", parts, 2, 64);
    
    if (count >= 1) {
        ConVar c = FindConVar(parts[0]);
        if (c != null) {
            int flags = c.Flags;
            c.Flags &= ~FCVAR_NOTIFY;
            ServerCommand(cmd);
            c.Flags = flags;
            return;
        }
    }
    
    // Fallback to normal command if cvar not found
    ServerCommand(cmd);
}

void SetCvarString(const char[] name, const char[] value) {
    ConVar c = FindConVar(name);
    if (c != null) {
        // Temporarily remove FCVAR_NOTIFY to suppress chat spam
        int flags = c.Flags;
        c.Flags &= ~FCVAR_NOTIFY;
        SetConVarString(c, value);
        c.Flags = flags; // Restore original flags
    } else {
        // Escape quotes to prevent command injection
        char escapedValue[512];
        int j = 0;
        for (int i = 0; i < strlen(value) && j < sizeof(escapedValue) - 2; i++) {
            if (value[i] == '"' || value[i] == '\\') {
                escapedValue[j++] = '\\';
            }
            escapedValue[j++] = value[i];
        }
        escapedValue[j] = '\0';
        
        char cmd[512];
        Format(cmd, sizeof(cmd), "%s \"%s\"", name, escapedValue);
        ServerCommand(cmd);
    }
}

bool IsKothMap() {
    char map[64];
    GetCurrentMap(map, sizeof(map));
    return StrContains(map, "koth_", false) == 0;
}

void GetTeamSizes(int &redCount, int &bluCount) {
    redCount = 0;
    bluCount = 0;
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            int team = GetClientTeam(i);
            if (team == 2) {
                redCount++;
            } else if (team == 3) {
                bluCount++;
            }
        }
    }
}

void StartCountdown() {
    if (g_eCurrentState != STATE_DRAFT) return;
    
    // Don't start if already counting down
    if (g_iCountdownSeconds > 0) return;
    
    g_iCountdownSeconds = 10;
    g_bPreStartedTournament = false;
    
    // Kill any existing pick timer
    KillTimerSafely(g_hPickTimer);
    
    // Ensure HUD timer is running for countdown display
    if (g_hHudTimer == INVALID_HANDLE) {
        g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
    
    g_hCountdownTimer = CreateTimer(1.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    UpdateHUDForAll();
}

void StopCountdown() {
    if (g_eCurrentState != STATE_DRAFT) return;
    
    g_iCountdownSeconds = 0;
    KillTimerSafely(g_hCountdownTimer);
    UpdateHUDForAll();
}

public Action Timer_Countdown(Handle timer) {
    // Check if teams are still balanced during countdown
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    
    if (redCount != TEAM_SIZE || bluCount != TEAM_SIZE) {
        // Teams became unbalanced, stop countdown
        g_hCountdownTimer = INVALID_HANDLE;
        g_iCountdownSeconds = 0;
        return Plugin_Stop;
    }

    // Kick off tournament restart at 6 seconds to sync with countdown
    if (g_iCountdownSeconds == 6 && !g_bPreStartedTournament) {
        // Apply live game cvars early and start tournament restart
        ApplyLiveGameStateCvars();
        ServerCommand("mp_tournament_restart");
        CreateTimer(0.5, Timer_ForceTeamsReady);
        g_bPreStartedTournament = true;
    }

    g_iCountdownSeconds--;
    
    if (g_iCountdownSeconds <= 0) {
        g_hCountdownTimer = INVALID_HANDLE;
        EndDraft();
        return Plugin_Stop;
    }
    
    UpdateHUDForAll();
    return Plugin_Continue;
}

public Action Timer_ShowInfoCard(Handle timer) {
    PrintToServer("+----------------------------------------------+");
    PrintToServer("|               TF2-Mixes v0.3.1               |");
    PrintToServer("|     vexx-sm | Type !helpmix for commands     |");
    PrintToServer("+----------------------------------------------+");

    // Check for DM module after info card is shown
    CreateTimer(1.5, Timer_CheckDMModule);
    
        return Plugin_Stop;
    }
    
public Action Timer_CheckDMModule(Handle timer) {
    Handle plugin = FindPluginByFile("mixes_dm.smx");
    
    if (plugin != null && GetPluginStatus(plugin) == Plugin_Running) {
        g_bDMPluginLoaded = true;
        if (!g_bDMAnnounced) {
            PrintToServer("   DM module detected - DM features available");
            g_bDMAnnounced = true;
        }
        // Enable DM for pre-draft phase immediately
        DM_SetPreGameActive(true);
    } else {
        if (!g_bDMAnnounced) {
            PrintToServer("   DM module not found - DM features disabled");
            g_bDMAnnounced = true;
        }
    }
    
    return Plugin_Stop;
}

void ShowHelpMenu(int client) {
    PrintToChat(client, "%s\x03=== Player Commands ===", MIX_TAG);
    PrintToChat(client, "%s\x03!captain\x01 (!cap) - Volunteer/drop as captain", MIX_TAG);
    PrintToChat(client, "%s\x03!pick <name>\x01 (!draft, !p) - Draft a player", MIX_TAG);
    PrintToChat(client, "%s\x03!remove <name>\x01 (!rm, !kick) - Remove from team", MIX_TAG);
    PrintToChat(client, "%s\x03!restart\x01 (!redraft) - Vote to restart mix", MIX_TAG);
    PrintToChat(client, "%s\x03!help\x01 - Show this menu", MIX_TAG);
    
    if (CheckCommandAccess(client, "sm_kick", ADMFLAG_KICK)) {
        PrintToChat(client, "%s\x07FF4444=== Admin Commands ===", MIX_TAG);
        PrintToChat(client, "%s\x07FF4444!setcaptain <name>\x01 - Set/remove captain", MIX_TAG);
        PrintToChat(client, "%s\x07FF4444!adminpick <name>\x01 - Force pick player", MIX_TAG);
        PrintToChat(client, "%s\x07FF4444!autodraft\x01 - Auto-draft remaining", MIX_TAG);
        PrintToChat(client, "%s\x07FF4444!cancelmix\x01 (!cancel) - Cancel mix", MIX_TAG);
        PrintToChat(client, "%s\x07FF4444!outline\x01 - Toggle teammate outlines", MIX_TAG);
        PrintToChat(client, "%s\x07FF4444!mixtest\x01 - Quick test setup", MIX_TAG);
    }
}

public Action Command_ToggleOutlines(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!CheckCommandAccess(client, "sm_outline", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    g_bOutlinesEnabled = !g_bOutlinesEnabled;
    ToggleTeamOutlines(g_bOutlinesEnabled);
    
    return Plugin_Handled;
}

public Action Command_ForceReadyUp(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!CheckCommandAccess(client, "sm_rup", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    // Force both teams to ready state
    GameRules_SetProp("m_bTeamReady", 1, .element=2);
    GameRules_SetProp("m_bTeamReady", 1, .element=3);
    
    return Plugin_Handled;
}

void ToggleTeamOutlines(bool enabled) {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && IsPlayerAlive(i)) {
            if (enabled) {
                TF2_AddCondition(i, view_as<TFCond>(114), 999.0); // Condition 114 for teammate outlines
            } else {
                TF2_RemoveCondition(i, view_as<TFCond>(114));
            }
        }
    }
}

// ========================================
// MIX UPDATE SYSTEM
// ========================================

// Update system variables
char g_sCurrentVersion[32] = "0.3.1";
char g_sLatestVersion[32];
char g_sUpdateURL[256];
bool g_bUpdateAvailable = false;

// Extension detection - SteamWorks is installed by default
#define STEAMWORKS_AVAILABLE() (GetFeatureStatus(FeatureType_Native, "SteamWorks_CreateHTTPRequest") == FeatureStatus_Available)

// Update system functions
public Action Timer_CheckUpdates(Handle timer) {
    CheckForUpdates();
        return Plugin_Stop;
    }
    
void CheckForUpdates() {
    if (!STEAMWORKS_AVAILABLE()) {
        LogMessage("[Mix] SteamWorks not available - update system disabled");
        return;
    }
    
    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, "https://api.github.com/repos/vexx-sm/TF2-Mixes/releases/latest");
    if (hRequest == INVALID_HANDLE) {
        LogError("[Mix] Failed to create HTTP request");
        return;
    }
    SteamWorks_SetHTTPRequestHeaderValue(hRequest, "User-Agent", "TF2-Mixes-Plugin");
    SteamWorks_SetHTTPRequestHeaderValue(hRequest, "Accept", "application/vnd.github.v3+json");
    SteamWorks_SetHTTPCallbacks(hRequest, OnUpdateCheck, INVALID_FUNCTION, INVALID_FUNCTION);
    if (!SteamWorks_SendHTTPRequest(hRequest)) {
        LogError("[Mix] Failed to send HTTP request");
        delete hRequest;
    }
}

public void OnUpdateCheck(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode) {
    if (bFailure || !bRequestSuccessful) {
        LogError("[Mix] HTTP request failed");
        delete hRequest;
        return;
    }
    
    if (eStatusCode != k_EHTTPStatusCode200OK) {
        LogError("[Mix] HTTP request failed with status: %d", eStatusCode);
        delete hRequest;
        return;
    }
    
    // Get response body size
    int bodySize;
    if (!SteamWorks_GetHTTPResponseBodySize(hRequest, bodySize)) {
        LogError("[Mix] Failed to get response body size");
        delete hRequest;
        return;
    }
    
    char responseBody[8192];
    int readSize = (bodySize > sizeof(responseBody) - 1) ? sizeof(responseBody) - 1 : bodySize;
    
    if (!SteamWorks_GetHTTPResponseBodyData(hRequest, responseBody, readSize)) {
        LogError("[Mix] Failed to get response body");
        delete hRequest;
        return;
    }
    
    responseBody[readSize] = '\0';
    delete hRequest;
    ParseGitHubResponse(responseBody);
}

void ParseGitHubResponse(const char[] response) {
    char tagName[64];
    char downloadUrl[256];
    
    // Parse tag_name with bounds checking
    if (!ExtractJSONString(response, "tag_name", tagName, sizeof(tagName))) {
        LogError("[Mix] Failed to parse tag_name from GitHub response");
        return;
    }
    
    // Find the first browser_download_url that ends with .smx
    if (!FindAssetUrlWithSuffix(response, ".smx", downloadUrl, sizeof(downloadUrl))) {
        LogMessage("[Mix] No .smx asset found in latest release - skipping auto-update");
        return;
    }
    
    // Remove 'v' prefix if present
    if (tagName[0] == 'v') {
        strcopy(g_sLatestVersion, sizeof(g_sLatestVersion), tagName[1]);
    } else {
        strcopy(g_sLatestVersion, sizeof(g_sLatestVersion), tagName);
    }
    
    if (CompareVersions(g_sCurrentVersion, g_sLatestVersion) >= 0) {
        return;
    }
    
    strcopy(g_sUpdateURL, sizeof(g_sUpdateURL), downloadUrl);
    g_bUpdateAvailable = true;
    StartUpdateNotifications();
    LogMessage("[Mix] Update available: v%s -> v%s | Use 'sm_updatemix' to download and install", g_sCurrentVersion, g_sLatestVersion);
}

bool FindAssetUrlWithSuffix(const char[] response, const char[] suffix, char[] output, int maxlen) {
    char pattern[32] = "\"browser_download_url\":\"";
    int pos = 0;
    int totalLen = strlen(response);
    
    while (pos >= 0 && pos < totalLen) {
        int relStart = StrContains(response[pos], pattern);
        if (relStart == -1) {
            return false;
        }
        int start = pos + relStart + strlen(pattern);
        if (start >= totalLen) {
            return false;
        }
        int end = StrContains(response[start], "\"");
        if (end == -1) {
            return false;
        }
        
        int copyLen = (end < maxlen - 1) ? end : maxlen - 1;
        for (int i = 0; i < copyLen; i++) {
            output[i] = response[start + i];
        }
        output[copyLen] = '\0';
        
        if (StrContains(output, suffix, false) != -1) {
            return true;
        }
        
        // Continue searching after this URL
        pos = start + end + 1;
    }

    return false;
}

bool ExtractJSONString(const char[] json, const char[] key, char[] output, int maxlen) {
    char searchPattern[128];
    // Look for pattern like: "key":"
    Format(searchPattern, sizeof(searchPattern), "\"%s\":\"", key);
    
    int start = StrContains(json, searchPattern);
    if (start == -1) return false;
    
    start += strlen(searchPattern);
    int end = StrContains(json[start], "\"");
    
    // Bounds checking to prevent buffer overflow
    if (end == -1 || end >= maxlen - 1) return false;
    
    // Safe copy with bounds check
    int copyLen = (end < maxlen - 1) ? end : maxlen - 1;
    for (int i = 0; i < copyLen; i++) {
        output[i] = json[start + i];
    }
    output[copyLen] = '\0';
    
    return true;
}

void StartUpdateNotifications() {
    if (g_hNotificationTimer != INVALID_HANDLE) {
        KillTimerSafely(g_hNotificationTimer);
    }
    
    g_hNotificationTimer = CreateTimer(160.0, Timer_NotifyAdmins, _, TIMER_REPEAT);
    NotifyAdminsOfUpdate();
}

void NotifyAdminsOfUpdate() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && CheckCommandAccess(i, "sm_updatemix", ADMFLAG_ROOT)) {
            PrintToChat(i, "%s\x03Update v%s available - use !updatemix", MIX_TAG, g_sLatestVersion);
        }
    }
}

public Action Timer_NotifyAdmins(Handle timer) {
    if (!g_bUpdateAvailable) {
        g_hNotificationTimer = INVALID_HANDLE;
        return Plugin_Stop;
    }
    
    NotifyAdminsOfUpdate();
    return Plugin_Continue;
}

public Action Command_UpdateMix(int client, int args) {
    if (!CheckCommandAccess(client, "sm_updatemix", ADMFLAG_ROOT)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    // Check if SteamWorks is available
    if (!STEAMWORKS_AVAILABLE()) {
        ReplyToCommand(client, "\x01[Mix] \x03SteamWorks not available - update system disabled");
        ReplyToCommand(client, "\x01[Mix] \x03SteamWorks should be installed by default with SourceMod");
        return Plugin_Handled;
    }
    
    if (!g_bUpdateAvailable) {
        ReplyToCommand(client, "\x01[Mix] \x03No updates available. Current version: v%s", g_sCurrentVersion);
        return Plugin_Handled;
    }
    
    PrintToChat(client, "\x01[Mix] \x03Downloading update...");
    LogMessage("[Mix] Update initiated by admin %N", client);
    
    // Create HTTP request to download the update
    Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, g_sUpdateURL);
    if (hRequest == INVALID_HANDLE) {
        LogError("[Mix] Failed to create download request");
        ReplyToCommand(client, "\x01[Mix] \x03Failed to create download request");
        return Plugin_Handled;
    }
    
    // Set headers
    SteamWorks_SetHTTPRequestHeaderValue(hRequest, "User-Agent", "TF2-Mixes-Plugin");
    
    // Set callbacks
    SteamWorks_SetHTTPCallbacks(hRequest, OnUpdateDownload, INVALID_FUNCTION, INVALID_FUNCTION);
    
    // Send request
    if (!SteamWorks_SendHTTPRequest(hRequest)) {
        LogError("[Mix] Failed to send download request");
        ReplyToCommand(client, "\x01[Mix] \x03Failed to send download request");
        delete hRequest;
    }
    
    return Plugin_Handled;
}

public void OnUpdateDownload(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode) {
    if (bFailure || !bRequestSuccessful) {
        LogError("[Mix] Download request failed");
        NotifyAdminsOfError("Download request failed");
        delete hRequest;
        return;
    }
    
    if (eStatusCode != k_EHTTPStatusCode200OK) {
        LogError("[Mix] Download failed with status: %d", eStatusCode);
        NotifyAdminsOfError("Download failed - invalid status code");
        delete hRequest;
        return;
    }
    
    // Get response body size
    int bodySize;
    if (!SteamWorks_GetHTTPResponseBodySize(hRequest, bodySize)) {
        LogError("[Mix] Failed to get download body size");
        NotifyAdminsOfError("Failed to get download size");
        delete hRequest;
        return;
    }
    
    char filepath[256] = "addons/sourcemod/plugins/mixes_update.smx";
    if (!SteamWorks_WriteHTTPResponseBodyToFile(hRequest, filepath)) {
        LogError("[Mix] Failed to write download to file");
        NotifyAdminsOfError("Failed to write download to file");
        delete hRequest;
        return;
    }
    
    delete hRequest;
    if (ValidateUpdateFile(filepath)) {
        ApplyUpdate();
    } else {
        LogError("[Mix] Downloaded file validation failed");
        NotifyAdminsOfError("File validation failed");
        DeleteFile(filepath);
    }
}

bool ValidateUpdateFile(const char[] filepath) {
    if (!FileExists(filepath)) {
        LogError("[Mix] Update file does not exist: %s", filepath);
        return false;
    }
    
    File file = OpenFile(filepath, "rb");
    if (file == null) {
        LogError("[Mix] Cannot open update file: %s", filepath);
        return false;
    }
    
    delete file;
    LogMessage("[Mix] Update file validated: %s", filepath);
    return true;
}

void ApplyUpdate() {
    char currentFile[256] = "addons/sourcemod/plugins/mixes.smx";
    char updateFile[256] = "addons/sourcemod/plugins/mixes_update.smx";
    
    if (File_Copy(updateFile, currentFile)) {
        DeleteFile(updateFile);
        
        PrintToChatAll("\x01[Mix] \x03Update downloaded and applied successfully! Reloading plugin...");
        LogMessage("[Mix] Update applied successfully, reloading plugin");
        
        g_bUpdateAvailable = false;
        KillTimerSafely(g_hNotificationTimer);
        CreateTimer(1.0, Timer_ReloadPlugin);
    } else {
        PrintToChatAll("\x01[Mix] \x03Failed to apply update! Check server logs.");
        LogError("[Mix] Failed to replace current plugin with update");
    }
}

bool File_Copy(const char[] source, const char[] destination) {
    File src = OpenFile(source, "rb");
    if (src == null) return false;
    
    File dst = OpenFile(destination, "wb");
    if (dst == null) {
        delete src;
        return false;
    }
    
    int buffer[1024];
    int bytesRead;
    
    while ((bytesRead = src.Read(buffer, sizeof(buffer), 1)) > 0) {
        dst.Write(buffer, bytesRead, 1);
    }
    
    delete src;
    delete dst;
    return true;
}

public Action Timer_ReloadPlugin(Handle timer) {
    ServerCommand("sm plugins reload mixes");
    return Plugin_Stop;
}

void NotifyAdminsOfError(const char[] error) {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && CheckCommandAccess(i, "sm_updatemix", ADMFLAG_ROOT)) {
            PrintToChat(i, "\x01[Mix] \x03Update error: %s", error);
        }
    }
}

int CompareVersions(const char[] version1, const char[] version2) {
    int v1[4], v2[4];
    char parts1[4][16];
    int count1 = ExplodeString(version1, ".", parts1, sizeof(parts1), sizeof(parts1[]));
    for (int i = 0; i < 4; i++) {
        v1[i] = (i < count1) ? StringToInt(parts1[i]) : 0;
    }
    
    char parts2[4][16];
    int count2 = ExplodeString(version2, ".", parts2, sizeof(parts2), sizeof(parts2[]));
    for (int i = 0; i < 4; i++) {
        v2[i] = (i < count2) ? StringToInt(parts2[i]) : 0;
    }
    for (int i = 0; i < 4; i++) {
        if (v1[i] > v2[i]) return 1;
        if (v1[i] < v2[i]) return -1;
    }
    
    return 0;
}

public Action Command_MixVersion(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;
    
    ReplyToCommand(client, "\\x01[Mix] \\x03Current version: v%s", g_sCurrentVersion);
    
    // Check if SteamWorks is available
    if (!STEAMWORKS_AVAILABLE()) {
        ReplyToCommand(client, "\\x01[Mix] \\x03Auto-update disabled - SteamWorks not available");
        ReplyToCommand(client, "\\x01[Mix] \\x03SteamWorks should be installed by default with SourceMod");
    } else {
        ReplyToCommand(client, "\\x03Auto-update system ready (SteamWorks available)");
    }
    
    return Plugin_Handled;
}

public Action Command_MixTest(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;
    
    if (!CheckCommandAccess(client, "sm_mixtest", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\\x01[Mix] \\x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    PrintToChat(client, "\\x01[Mix] \\x03Setting up test environment...");
    
    // Step 1: Enable cheats
    ServerCommand("sv_cheats 1");
    PrintToChat(client, "\\x01[Mix] \\x03✓ Cheats enabled");
    
    // Step 2: Add 11 numbered bots via 'bot' command (works best for testing)
    for (int i = 0; i < 11; i++) {
        ServerCommand("bot");
    }
    PrintToChat(client, "\\x01[Mix] \\x03✓ Added 11 bots (via 'bot')");
    
    // Step 3: Set you as captain (with delay to allow bots to connect)
    CreateTimer(2.0, Timer_SetTestCaptain, GetClientUserId(client));
    PrintToChat(client, "\\x01[Mix] \\x03✓ You will be set as first captain in 2 seconds...");
    
    return Plugin_Handled;
}

public Action Timer_SetTestCaptain(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client)) {
        return Plugin_Stop;
    }
    
    // Reset to idle first to clear any existing state
    SetMixState(STATE_IDLE);
    
    // Set as first captain
    g_iCaptain1 = client;
    if (strlen(g_sOriginalNames[client]) == 0) {
        GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
    }
    
    char newName[MAX_NAME_LENGTH];
    Format(newName, sizeof(newName), "[CAP] %s", g_sOriginalNames[client]);
    SetClientName(client, newName);
    
    PrintToChatAll("\\x01[Mix] \\x03%N is now the first team captain!", client);
    PrintToChat(client, "\\x01[Mix] \\x03Test setup complete! Need 1 more captain to start draft.");
    
    // Transition to PRE_DRAFT state
    SetMixState(STATE_PRE_DRAFT);
    
    return Plugin_Stop;
}


// ========================================
// DM MODULE INTEGRATION
// ========================================

// DM module control functions
void DM_SetPreGameActive(bool active) {
    if (g_bDMPluginLoaded) {
        ServerCommand("sm_mix_dm_pregame_active %d", active ? 1 : 0);
    }
}

void DM_SetDraftInProgress(bool inProgress) {
    if (g_bDMPluginLoaded) {
        ServerCommand("sm_mix_dm_draft_in_progress %d", inProgress ? 1 : 0);
    }
}

void DM_StopAllFeatures() {
    if (g_bDMPluginLoaded) {
        ServerCommand("sm_mix_dm_stop_all 1");
    }
}

// ========================================
// END MIX UPDATE SYSTEM
// ========================================

