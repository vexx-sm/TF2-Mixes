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
    version = "0.3.0",
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
int g_iOriginalTeam[MAXPLAYERS + 1];
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

ConVar g_cvPickTimeout;
ConVar g_cvCommandCooldown;
ConVar g_cvGracePeriod;
ConVar g_cvTipsEnable;
ConVar g_cvTipsInterval;
int g_iTipIndex = 0;

bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

void KillTimerSafely(Handle &timer) {
    if (timer != INVALID_HANDLE) {
        // Use CloseHandle which is safer for plugin reload scenarios
        CloseHandle(timer);
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
}

// ========================================
// CVAR MANAGEMENT - State-specific settings
// ========================================

void ApplyIdleStateCvars() {
    // Disable tournament mode
    ServerCommand("mp_tournament 0");
    ServerCommand("mp_tournament_allow_non_admin_restart 1");
    
    // Clear whitelist
    ServerCommand("mp_tournament_whitelist \"\"");
    
    // Reset ALL win conditions
    ServerCommand("mp_winlimit 0");
    ServerCommand("mp_maxrounds 0");
    ServerCommand("mp_timelimit 0");
    ServerCommand("mp_windifference 0");
    
    // Normal team settings
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
    
    // Normal bot settings
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    
    // Restart game to clear tournament state
    ServerCommand("mp_restartgame 1");
}

void ApplyPreDraftStateCvars() {
    // Keep tournament mode disabled
    ServerCommand("mp_tournament 0");
    
    // No win conditions
    ServerCommand("mp_winlimit 0");
    ServerCommand("mp_maxrounds 0");
    ServerCommand("mp_timelimit 0");
    ServerCommand("mp_windifference 0");
    
    // No whitelist
    ServerCommand("mp_tournament_whitelist \"\"");
    
    // Normal team settings
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
}

void ApplyDraftStateCvars() {
    // Keep tournament mode disabled
    ServerCommand("mp_tournament 0");
    
    // No win conditions
    ServerCommand("mp_winlimit 0");
    ServerCommand("mp_maxrounds 0");
    ServerCommand("mp_timelimit 0");
    ServerCommand("mp_windifference 0");
    
    // No whitelist
    ServerCommand("mp_tournament_whitelist \"\"");
    
    // Prevent team balance during draft
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("mp_forceautoteam 0");
}

void ApplyLiveGameStateCvars() {
    // Enable tournament mode
    ServerCommand("mp_tournament 1");
    ServerCommand("mp_tournament_allow_non_admin_restart 1");
    
    // Apply whitelist
    SetCvarString("mp_tournament_whitelist", ETF2L_WHITELIST_PATH);
    
    // Competitive gameplay settings
    ServerCommand("tf_use_fixed_weaponspreads 1");
    ServerCommand("tf_weapon_criticals 0");
    ServerCommand("tf_damage_disablespread 1");
    
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
    ServerCommand("mp_teams_unbalance_limit 0");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("mp_forceautoteam 0");
}

void EnterIdleState() {
    // Reset all timers
    KillAllTimers();
    
    // Reset all state variables
    bool hadCaptains = (g_iCaptain1 != -1 || g_iCaptain2 != -1);
    
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
        g_iOriginalTeam[i] = 0;
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
    
    // Only show message if we had an active mix
    if (hadCaptains) {
        PrintToChatAll("\x01[Mix] \x03Mix has ended. Teams are now unlocked.");
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
    
    PrintToChatAll("\x01[Mix] \x03Draft has started! First captain's turn to pick.");
    
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
    
    // Restart tournament and force teams ready
    ServerCommand("mp_tournament_restart");
    CreateTimer(0.5, Timer_ForceTeamsReady);
    
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
        
        PrintToChatAll("\x01[Mix] \x03%N has reconnected and rejoined their team!", client);
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
    
    RegConsoleCmd("sm_captain", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_cap", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_draft", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_pick", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_remove", Command_Remove, "Remove a player from your team (counts as a turn)");
    RegConsoleCmd("sm_restart", Command_RestartDraft, "Vote to restart after game ends");
    RegConsoleCmd("sm_redraft", Command_RestartDraft, "Vote to restart after game ends");
    RegConsoleCmd("sm_cancelmix", Command_CancelMix, "Cancel current mix");
    RegConsoleCmd("sm_helpmix", Command_HelpMix, "Show help menu with all commands");
    RegConsoleCmd("sm_help", Command_HelpMix, "Show help menu with all commands");
    
    AddCommandListener(Command_JoinTeam, "jointeam");
    AddCommandListener(Command_JoinTeam, "spectate");
    
    RegAdminCmd("sm_setcaptain", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain");
    RegAdminCmd("sm_setcap", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain");
    RegAdminCmd("sm_adminpick", Command_AdminPick, ADMFLAG_GENERIC, "Force pick a player");
    RegAdminCmd("sm_autodraft", Command_AutoDraft, ADMFLAG_GENERIC, "Automatically draft teams");
    RegAdminCmd("sm_outline", Command_ToggleOutlines, ADMFLAG_GENERIC, "Toggle teammate outlines for all players");
    RegAdminCmd("sm_rup", Command_ForceReadyUp, ADMFLAG_GENERIC, "Force both teams ready (testing)");
    RegAdminCmd("sm_updatemix", Command_UpdateMix, ADMFLAG_ROOT, "Download and install plugin updates");
    RegAdminCmd("sm_mixupdate", Command_UpdateMix, ADMFLAG_ROOT, "Download and install plugin updates");
    RegConsoleCmd("sm_mixversion", Command_MixVersion, "Show current plugin version and update status");
    
    // Public version ConVar for server tracking (FCVAR_NOTIFY | FCVAR_DONTRECORD)
    CreateConVar("sm_mixes_version", "0.3.0", "TF2-Mixes plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    
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

public void OnMapStart() {
    // Reset to idle state
    SetMixState(STATE_IDLE);
    
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
        if (g_eCurrentState == STATE_LIVE_GAME) {
            // Check if this player was disconnected and restore their state
            if (g_bPlayerDisconnected[client]) {
                RestorePlayerState(client);
                return;
            }
        }
        else if (g_eCurrentState == STATE_IDLE || g_eCurrentState == STATE_PRE_DRAFT) {
            // Normal player joining
        g_bPlayerLocked[client] = false;
        }
        else if (g_eCurrentState == STATE_DRAFT) {
            // Player joining during draft - put them in spectator
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
    if (!IsValidClient(client))
        return;
        
    // Handle captain disconnection
    if (client == g_iCaptain1 || client == g_iCaptain2) {
        SetClientName(client, g_sOriginalNames[client]);
    
    if (client == g_iCaptain1) {
        g_iCaptain1 = -1;
            if (g_eCurrentState == STATE_DRAFT) {
                if (!IsFakeClient(client)) {
                    StartGracePeriod(0);
                }
            } else if (g_eCurrentState == STATE_PRE_DRAFT) {
                PrintToChatAll("\x01[Mix] \x03First captain has left! Need a new captain to continue.");
                // Check if both captains are now gone
                if (g_iCaptain2 == -1) {
                    SetMixState(STATE_IDLE);
            }
        } else {
            PrintToChatAll("\x01[Mix] \x03First captain has left the game!");
        }
    } else if (client == g_iCaptain2) {
        g_iCaptain2 = -1;
            if (g_eCurrentState == STATE_DRAFT) {
                if (!IsFakeClient(client)) {
                    StartGracePeriod(1);
                }
            } else if (g_eCurrentState == STATE_PRE_DRAFT) {
                PrintToChatAll("\x01[Mix] \x03Second captain has left! Need a new captain to continue.");
                // Check if both captains are now gone
                if (g_iCaptain1 == -1) {
                    SetMixState(STATE_IDLE);
            }
        } else {
            PrintToChatAll("\x01[Mix] \x03Second captain has left the game!");
        }
    }
    } else {
        // Handle regular player disconnection based on state
        if (g_eCurrentState == STATE_LIVE_GAME) {
            // Preserve player state for reconnection
            if (g_bPlayerPicked[client]) {
                PreservePlayerState(client);
                PrintToChatAll("\x01[Mix] \x03%N has left the game! They can rejoin when they return.", client);
            }
        }
        else if (g_eCurrentState == STATE_DRAFT) {
            // Handle drafted player disconnection during draft
            if (g_bPlayerPicked[client]) {
                PrintToChatAll("\x01[Mix] \x03%N has left the game! They can rejoin when they return.", client);
                
                // Check if teams are still balanced after disconnection
                int redCount, bluCount;
                GetTeamSizes(redCount, bluCount);
                
                // If teams are unbalanced, allow more picks
                if (redCount < TEAM_SIZE || bluCount < TEAM_SIZE) {
                    if (g_iPicksRemaining <= 0) {
                        g_iPicksRemaining = 1; // Allow one more pick to balance teams
                        PrintToChatAll("\x01[Mix] \x03Teams are unbalanced! Draft continues to balance teams.");
                    }
                }
            }
        }
    }
    
    // Reset player state (except for live game preservation)
    if (g_eCurrentState != STATE_LIVE_GAME) {
    g_bPlayerLocked[client] = false;
        g_bPlayerPicked[client] = false;
    }
}

public Action Command_Captain(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    // Allow captain selection during IDLE and PRE_DRAFT (in case a captain drops)
    if (g_eCurrentState != STATE_IDLE && g_eCurrentState != STATE_PRE_DRAFT) {
        ReplyToCommand(client, "\x01[Mix] \x03Captain selection is only available before the draft starts!");
        return Plugin_Handled;
    }
        
    float currentTime = GetGameTime();
    float timeSinceLastCommand = currentTime - g_fLastCommandTime[client];
    float cooldownTime = g_cvCommandCooldown.FloatValue;
    
    if (timeSinceLastCommand < cooldownTime) {
        ReplyToCommand(client, "\x01[Mix] \x03Please wait %.1f seconds before using this command again.", cooldownTime - timeSinceLastCommand);
        return Plugin_Handled;
    }
    
    g_fLastCommandTime[client] = currentTime;
        
    if (client == g_iCaptain1 || client == g_iCaptain2) {
        if (client == g_iCaptain1) {
            g_iCaptain1 = -1;
            SetClientName(client, g_sOriginalNames[client]);
            PrintToChat(client, "\x01[Mix] \x03You are no longer the first captain.");
            if (g_eCurrentState == STATE_DRAFT) {
                KillTimerSafely(g_hPickTimer);
                StartGracePeriod(0);
                Timer_UpdateHUD(g_hHudTimer);
            } else {
                PrintToChatAll("\x01[Mix] \x03%N\x01 is no longer a captain!", client);
            }
        } else {
            g_iCaptain2 = -1;
            SetClientName(client, g_sOriginalNames[client]);
            PrintToChat(client, "\x01[Mix] \x03You are no longer the second captain.");
            if (g_eCurrentState == STATE_DRAFT) {
                KillTimerSafely(g_hPickTimer);
                StartGracePeriod(1);
                Timer_UpdateHUD(g_hHudTimer);
            } else {
                PrintToChatAll("\x01[Mix] \x03%N\x01 is no longer a captain!", client);
            }
        }
        return Plugin_Handled;
    }
    
    if (g_eCurrentState == STATE_DRAFT && g_iMissingCaptain != -1) {
        if (g_iMissingCaptain == 0) {
            g_iCaptain1 = client;
        } else {
            g_iCaptain2 = client;
        }
        
            if (strlen(g_sOriginalNames[client]) == 0) {
                GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
            }
            char newName[MAX_NAME_LENGTH];
            Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
            SetClientName(client, newName);
        
        PrintToChatAll("\x01[Mix] \x03%N\x01 has become the replacement captain!", client);
            ResumeDraft();
            return Plugin_Handled;
    }
    
    if (g_iCaptain1 == -1) {
        g_iCaptain1 = client;
        if (strlen(g_sOriginalNames[client]) == 0) {
            GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
        SetClientName(client, newName);
        PrintToChatAll("\x01[Mix] \x03%N\x01 is now the first team captain!", client);
    } else if (g_iCaptain2 == -1) {
        g_iCaptain2 = client;
        if (strlen(g_sOriginalNames[client]) == 0) {
            GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
        SetClientName(client, newName);
        PrintToChatAll("\x01[Mix] \x03%N\x01 is now the second team captain!", client);
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
        if (g_iCaptain1 == -1 && g_iCaptain2 == -1) {
            PrintToChatAll("\x01[Mix] \x03Need two captains to start drafting. Type !captain to become a captain.");
        } else if (g_iCaptain1 == -1) {
            PrintToChatAll("\x01[Mix] \x03Need one more captain to start drafting. Type !captain to become a captain.");
        } else {
            PrintToChatAll("\x01[Mix] \x03Need one more captain to start drafting. Type !captain to become a captain.");
        }
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
    } else {
        PrintToChatAll("\x01[Mix] \x03Need at least 12 players to start drafting. Current players: %d", totalPlayers);
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
        PrintToChat(client, "\x01[Mix] \x03Teams are managed by the plugin during the draft! Use !draft to pick players.");
        return Plugin_Handled;
    }
    else if (g_eCurrentState == STATE_LIVE_GAME) {
        PrintToChat(client, "\x01[Mix] \x03Teams are locked during the live game!");
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
        
        int targetClient = -1;
        char targetName[MAX_NAME_LENGTH];
        
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
                GetClientName(i, targetName, sizeof(targetName));
                if (StrEqual(targetName, target, false)) {
                    targetClient = i;
                    break;
                }
            }
        }
        
        if (targetClient == -1) {
            for (int i = 1; i <= MaxClients; i++) {
                if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
                    GetClientName(i, targetName, sizeof(targetName));
                    if (StrContains(targetName, target, false) != -1) {
                        targetClient = i;
                        break;
                    }
                }
            }
        }
        
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
        
        int targetClient = -1;
        char targetName[MAX_NAME_LENGTH];
        
        // Find player on captain's team
        int captainTeam = GetClientTeam(client);
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && GetClientTeam(i) == captainTeam && i != client) {
                GetClientName(i, targetName, sizeof(targetName));
                if (StrEqual(targetName, target, false)) {
                    targetClient = i;
                    break;
                }
            }
        }
        
        if (targetClient == -1) {
            for (int i = 1; i <= MaxClients; i++) {
                if (IsValidClient(i) && GetClientTeam(i) == captainTeam && i != client) {
                    GetClientName(i, targetName, sizeof(targetName));
                    if (StrContains(targetName, target, false) != -1) {
                        targetClient = i;
                        break;
                    }
                }
            }
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
    
    PrintToChatAll("\x01[Mix] \x03%N's turn to pick! (%d picks remaining)", nextCaptain, g_iPicksRemaining);
    
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
    
    PrintToChatAll("\x01[Mix] \x03%N has been drafted to the %s team!", target, (view_as<TFTeam>(team) == TFTeam_Red) ? "RED" : "BLU");
    
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
    
    PrintToChatAll("\x01[Mix] \x03%N's turn to pick! (%d picks remaining)", nextCaptain, g_iPicksRemaining);
    
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
        PrintToChat(client, "\x01[Mix] \x03You are locked to your team! Teams are managed by the plugin.");
        CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        return Plugin_Handled;
    }
        if (client != g_iCaptain1 && client != g_iCaptain2) {
        PrintToChat(client, "\x01[Mix] \x03You must wait to be drafted by a captain! Teams are managed by the plugin.");
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
            if (currentTeam == 0) { // If they're still on spectator
                // Find which team they should be on
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
            PrintToChat(client, "\x01[Mix] \x03You are locked to your team!");
        return Plugin_Stop;
    }
    
    if (g_iPicksRemaining > 0 && client != g_iCaptain1 && client != g_iCaptain2) {
        if (view_as<TFTeam>(currentTeam) != TFTeam_Spectator) {
            TF2_ChangeClientTeam(client, TFTeam_Spectator);
            PrintToChat(client, "\x01[Mix] \x03You must wait to be drafted by a captain!");
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
            PrintToChat(client, "\x01[Mix] \x03Teams are locked during the game! You must spectate.");
        }
    }
    
    return Plugin_Stop;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    if ((client == g_iCaptain1 || client == g_iCaptain2) && !StrContains(g_sOriginalNames[client], "[CAP]")) {
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
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
        PrintToChatAll("\x01[Mix] \x03Draft complete! Mix has started (ETF2L 6v6, KOTH - First to 4).");
    } else {
        PrintToChatAll("\x01[Mix] \x03Draft complete! Mix has started (ETF2L 6v6, 5CP - First to 5).");
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
    char buffer[256];
    
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
            
            Format(buffer, sizeof(buffer), "DRAFT PAUSED\n%s disconnected!\nReplacement needed: %.0fs", captainName, timeLeft);
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
            
            Format(buffer, sizeof(buffer), "DRAFT IN PROGRESS\n%s's turn to pick\nTime: %.0fs\nRED: %d/%d | BLU: %d/%d", 
                   captainName, timeLeft, redTeamSize, TEAM_SIZE, bluTeamSize, TEAM_SIZE);
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
        const int TIP_COUNT = 4;
        char tip[192];
        switch (g_iTipIndex % TIP_COUNT) {
            case 0: strcopy(tip, sizeof(tip), "\x07FFFFFFUse \x0700FF00!captain \x07FFFFFFto volunteer or drop yourself as captain.");
            case 1: strcopy(tip, sizeof(tip), "\x07FFFFFFUse \x0700FF00!pick \x07FFFFFFto open the draft menu or use \x0700FF00!pick playername\x07FFFFFF.");
            case 2: strcopy(tip, sizeof(tip), "\x07FFFFFFUse \x0700FF00!remove \x07FFFFFFto open the remove menu or use \x0700FF00!remove playername\x07FFFFFF.");
            case 3: strcopy(tip, sizeof(tip), "\x07FFFFFFUse \x0700FF00!helpmix \x07FFFFFFor \x0700FF00!help \x07FFFFFFto see all available commands.");
        }
        g_iTipIndex++;
        
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && !IsFakeClient(i)) {
                PrintToChat(i, "\x01[Mix] \x03%s", tip);
            }
        }
    }
    
        return Plugin_Continue;
    }
    

public Action Timer_GracePeriod(Handle timer) {
    if (g_eCurrentState != STATE_DRAFT || g_iMissingCaptain == -1) {
        return Plugin_Stop;
    }
    
    float currentTime = GetGameTime();
    float timeLeft = g_cvGracePeriod.FloatValue - (currentTime - g_fPickTimerStartTime);
    
    if (timeLeft <= 0.0) {
        PrintToChatAll("\x01[Mix] \x03Grace period expired. Cancelling mix.");
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
        PrintToChatAll("\x01[Mix] \x03Both captains have left! Cancelling mix.");
        SetMixState(STATE_IDLE);
        return;
    }
    
    // If already in grace period for the same captain, don't restart
        if (g_iMissingCaptain == missingCaptain) return;
    
    // If already in grace period for different captain, both are now gone
    if (g_iMissingCaptain != -1) {
        PrintToChatAll("\x01[Mix] \x03Both captains have left! Cancelling mix.");
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
    
    PrintToChatAll("\x01[Mix] \x03A captain has left! You have %.0f seconds to type !captain to replace them.", g_cvGracePeriod.FloatValue);
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
        PrintToChatAll("\x01[Mix] \x03Draft resumed! Countdown continues from %d seconds.", g_iCountdownSeconds);
    } else {
        // Resume pick timer
        KillTimerSafely(g_hPickTimer);
        g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
        
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        if (IsValidClient(currentCaptain)) {
            PrintToChatAll("\x01[Mix] \x03Draft resumed! %N's turn to pick (%d picks remaining).", currentCaptain, g_iPicksRemaining);
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
    
    // Calculate 2/3 (66.67%) requirement (minimum 1 for solo testing)
    int requiredVotes = RoundToCeil(float(totalPlayers) * 0.6667);
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
    
    int targetClient = -1;
    char targetName[MAX_NAME_LENGTH];
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            GetClientName(i, targetName, sizeof(targetName));
            if (StrEqual(targetName, target, false)) {
                targetClient = i;
                break;
            }
        }
    }
    
    if (targetClient == -1) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i)) {
                GetClientName(i, targetName, sizeof(targetName));
                if (StrContains(targetName, target, false) != -1) {
                    targetClient = i;
                    break;
                }
            }
        }
    }
    
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
            ReplyToCommand(client, "\x01[Mix] \x03Removed %N's first captain status.", targetClient);
            PrintToChat(targetClient, "\x01[Mix] \x03Your first captain status has been removed by an admin.");
        } else {
            g_iCaptain2 = -1;
            SetClientName(targetClient, g_sOriginalNames[targetClient]);
            if (g_eCurrentState == STATE_DRAFT) {
                StartGracePeriod(1);
            }
            ReplyToCommand(client, "\x01[Mix] \x03Removed %N's second captain status.", targetClient);
            PrintToChat(targetClient, "\x01[Mix] \x03Your second captain status has been removed by an admin.");
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
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[targetClient]);
        SetClientName(targetClient, newName);
        PrintToChatAll("\x01[Mix] \x03%N\x01 is now the first team captain!", targetClient);
        ReplyToCommand(client, "\x01[Mix] \x03Set %N as the first captain.", targetClient);
        PrintToChat(targetClient, "\x01[Mix] \x03You have been set as the first captain by an admin!");
    } else {
        g_iCaptain2 = targetClient;
        if (strlen(g_sOriginalNames[targetClient]) == 0) {
            GetClientName(targetClient, g_sOriginalNames[targetClient], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[targetClient]);
        SetClientName(targetClient, newName);
        PrintToChatAll("\x01[Mix] \x03%N\x01 is now the second team captain!", targetClient);
        ReplyToCommand(client, "\x01[Mix] \x03Set %N as the second captain.", targetClient);
        PrintToChat(targetClient, "\x01[Mix] \x03You have been set as the second captain by an admin!");
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
    
    int targetClient = -1;
    char targetName[MAX_NAME_LENGTH];
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
            GetClientName(i, targetName, sizeof(targetName));
            if (StrEqual(targetName, target, false)) {
                targetClient = i;
                break;
            }
        }
    }
    
    if (targetClient == -1) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
                GetClientName(i, targetName, sizeof(targetName));
                if (StrContains(targetName, target, false) != -1) {
                    targetClient = i;
                    break;
                }
            }
        }
    }
        
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
    
    PrintToChatAll("\x01[Mix] \x03Admin %N has picked %N for the %s team!", client, targetClient, (view_as<TFTeam>(team) == TFTeam_Red) ? "RED" : "BLU");
    
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
        KillTimerSafely(g_hPickTimer);
            g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
            g_fPickTimerStartTime = GetGameTime();
        } else {
            EndDraft();
        }
        return Plugin_Stop;
    }
    
    // Auto-pick random player
    int randomPlayer = FindNextAvailablePlayer();
    if (randomPlayer != -1) {
        PrintToChatAll("\x01[Mix] \x03Pick timed out! Auto-picking %N.", randomPlayer);
        PickPlayer(currentCaptain, randomPlayer);
    } else {
        PrintToChatAll("\x01[Mix] \x03Pick timed out! No players available. Ending draft.");
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
    CloseHandle(file);
}

void SetCvarInt(const char[] name, int value) {
    ConVar c = FindConVar(name);
    if (c != null) {
        SetConVarInt(c, value);
    } else {
        char cmd[64];
        Format(cmd, sizeof(cmd), "%s %d", name, value);
        ServerCommand(cmd);
    }
}

void SetCvarString(const char[] name, const char[] value) {
    ConVar c = FindConVar(name);
    if (c != null) {
        SetConVarString(c, value);
    } else {
        char cmd[512];
        Format(cmd, sizeof(cmd), "%s \"%s\"", name, value);
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
    
    // Kill any existing pick timer
    KillTimerSafely(g_hPickTimer);
    
    // Ensure HUD timer is running for countdown display
    if (g_hHudTimer == INVALID_HANDLE) {
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    }
    
    PrintToChatAll("\x01[Mix] \x03Teams are complete! Game starting in 10 seconds...");
    
    g_hCountdownTimer = CreateTimer(1.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    UpdateHUDForAll();
}

void StopCountdown() {
    if (g_eCurrentState != STATE_DRAFT) return;
    
    g_iCountdownSeconds = 0;
    KillTimerSafely(g_hCountdownTimer);
    
    PrintToChatAll("\x01[Mix] \x03Countdown cancelled - draft continues!");
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
        PrintToChatAll("\x01[Mix] \x03Teams became unbalanced! Countdown cancelled.");
    return Plugin_Stop;
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
    PrintToServer("|               TF2-Mixes v0.3.0               |");
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
        PrintToServer("   DM module detected - DM features available");
        // Enable DM for pre-draft phase immediately
        DM_SetPreGameActive(true);
    } else {
        PrintToServer("   DM module not found - DM features disabled");
    }
    
    return Plugin_Stop;
}

void ShowHelpMenu(int client) {
    PrintToChat(client, "\x01[Mix] \x07FFFFFFPlayer Commands:");
    PrintToChat(client, "\x01[Mix] \x0700FF00!captain / !cap \x07FFFFFF- Become or resign as captain");
    PrintToChat(client, "\x01[Mix] \x0700FF00!draft / !pick \x07FFFFFF- Draft a player (captains only)");
    PrintToChat(client, "\x01[Mix] \x0700FF00!remove \x07FFFFFF- Remove a player from your team (captains only)");
    PrintToChat(client, "\x01[Mix] \x0700FF00!restart / !redraft \x07FFFFFF- Vote to restart mix (2/3 required)");
    PrintToChat(client, "\x01[Mix] \x0700FF00!helpmix / !help \x07FFFFFF- Show this help menu");
    PrintToChat(client, "\x01[Mix] \x0700FF00!mixversion \x07FFFFFF- Show plugin version");
    
    // Only show admin commands to admins
    if (CheckCommandAccess(client, "sm_kick", ADMFLAG_KICK)) {
        PrintToChat(client, "\x01[Mix] \x07FFFFFFAdmin Commands:");
        PrintToChat(client, "\x01[Mix] \x07FF0000!setcaptain / !setcap \x07FFFFFF- Set a player as captain");
        PrintToChat(client, "\x01[Mix] \x07FF0000!adminpick \x07FFFFFF- Force pick a player");
        PrintToChat(client, "\x01[Mix] \x07FF0000!autodraft \x07FFFFFF- Auto-draft remaining players");
        PrintToChat(client, "\x01[Mix] \x07FF0000!outline \x07FFFFFF- Toggle teammate outlines");
        PrintToChat(client, "\x01[Mix] \x07FF0000!rup \x07FFFFFF- Force teams ready");
        PrintToChat(client, "\x01[Mix] \x07FF0000!cancelmix \x07FFFFFF- Cancel current mix");
        PrintToChat(client, "\x01[Mix] \x07FF0000!updatemix / !mixupdate \x07FFFFFF- Update plugin (root only)");
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
    
    PrintToChatAll("\x01[Mix] \x03%N has %s teammate outlines for all players!", client, g_bOutlinesEnabled ? "enabled" : "disabled");
    
    return Plugin_Handled;
}

public Action Command_ForceReadyUp(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!CheckCommandAccess(client, "sm_rup", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    PrintToChatAll("\x01[Mix] \x03%N is forcing both teams ready!", client);
    
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
char g_sCurrentVersion[32] = "0.3.0";
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
    int tagStart = StrContains(response, "\"tag_name\":\"");
    if (tagStart != -1) {
        tagStart += 12;
        int tagEnd = StrContains(response[tagStart], "\"");
        if (tagEnd != -1) {
            strcopy(tagName, sizeof(tagName), response[tagStart]);
            tagName[tagEnd] = '\0';
        }
    }
    
    int urlStart = StrContains(response, "\"browser_download_url\":\"");
    if (urlStart != -1) {
        urlStart += 25;
        int urlEnd = StrContains(response[urlStart], "\"");
        if (urlEnd != -1) {
            strcopy(downloadUrl, sizeof(downloadUrl), response[urlStart]);
            downloadUrl[urlEnd] = '\0';
        }
    }
    
    if (strlen(tagName) == 0) {
        LogError("[Mix] Could not find tag_name in response");
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
    
    if (strlen(downloadUrl) == 0) {
        LogError("[Mix] No download URL found in response");
        return;
    }
    
    strcopy(g_sUpdateURL, sizeof(g_sUpdateURL), downloadUrl);
    g_bUpdateAvailable = true;
    StartUpdateNotifications();
    LogMessage("[Mix] Update available: v%s -> v%s | Use 'sm_updatemix' to download and install", g_sCurrentVersion, g_sLatestVersion);
}

void StartUpdateNotifications() {
    if (g_hNotificationTimer != INVALID_HANDLE) {
        KillTimer(g_hNotificationTimer);
    }
    
    g_hNotificationTimer = CreateTimer(160.0, Timer_NotifyAdmins, _, TIMER_REPEAT);
    NotifyAdminsOfUpdate();
}

void NotifyAdminsOfUpdate() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && CheckCommandAccess(i, "sm_updatemix", ADMFLAG_ROOT)) {
            PrintToChat(i, "\x01[Mix] \x03Update available: v%s -> v%s", g_sCurrentVersion, g_sLatestVersion);
            PrintToChat(i, "\x01[Mix] \x03Use \x0700FF00!updatemix \x03to download and install");
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
    
    ReplyToCommand(client, "\x01[Mix] \x03Current version: v%s", g_sCurrentVersion);
    
    // Check if SteamWorks is available
    if (!STEAMWORKS_AVAILABLE()) {
        ReplyToCommand(client, "\x01[Mix] \x03Auto-update disabled - SteamWorks not available");
        ReplyToCommand(client, "\x01[Mix] \x03SteamWorks should be installed by default with SourceMod");
    } else {
        ReplyToCommand(client, "\x01[Mix] \x03Auto-update system ready (SteamWorks available)");
    }
    
    return Plugin_Handled;
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

public void OnPluginEnd() {
    // Clean up all timers
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hHudTimer);
    KillTimerSafely(g_hTipsTimer);
    KillTimerSafely(g_hGraceTimer);
    KillTimerSafely(g_hVoteTimer);
    KillTimerSafely(g_hCountdownTimer);
    KillTimerSafely(g_hNotificationTimer);
    KillTimerSafely(g_hRestartVoteResetTimer);
}