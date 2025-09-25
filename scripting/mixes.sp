#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <clientprefs>
#include <sdktools>
#include <sdkhooks>
#include <float>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
    name = "TF2-Mixes",
    author = "vexx-sm",
    description = "A TF2 SourceMod plugin that sets up a 6s mix",
    version = "0.2.0",
    url = "https://github.com/vexx-sm/TF2-Mixes"
};
int g_iCaptain1 = -1;
int g_iCaptain2 = -1;
bool g_bMixInProgress = false;
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
Handle g_hVoteTimer = INVALID_HANDLE;
int g_iVoteCount[3] = {0, 0, 0};
bool g_bPlayerVoted[MAXPLAYERS + 1];
bool g_bVoteInProgress = false;
float g_fPickTimerStartTime = 0.0;
int g_iOriginalTeam[MAXPLAYERS + 1] = {0};
bool g_bPlayerPicked[MAXPLAYERS + 1];

// Countdown system
bool g_bCountdownActive = false;
int g_iCountdownSeconds = 10;
Handle g_hCountdownTimer = INVALID_HANDLE;

// Movement detection for spawn system
bool g_bPlayerMoved[MAXPLAYERS + 1];

// Outline system
bool g_bOutlinesEnabled = false;

char ETF2L_WHITELIST_PATH[] = "cfg/etf2l_whitelist_6v6.txt";

bool g_bPreGameDMActive = false;
ConVar g_cvPreGameEnable;
ConVar g_cvPreGameSpawnProtect;

// SOAP TF2DM spawn system
bool g_bSpawnRandom;
bool g_bTeamSpawnRandom;
Handle g_hTeamSpawnRandom;
Handle g_hSpawnRandom;
ArrayList g_hRedSpawns;
ArrayList g_hBluSpawns;
Handle g_hKv;


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
        KillTimer(timer);
        timer = INVALID_HANDLE;
    }
}

public void OnPluginStart() {
    LoadTranslations("common.phrases");
    LoadTranslations("mixes.phrases");
    
    RegConsoleCmd("sm_captain", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_cap", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_draft", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_pick", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_remove", Command_Remove, "Remove a player from your team (counts as a turn)");
    RegConsoleCmd("sm_restart", Command_RestartDraft, "Vote to restart the current draft");
    RegConsoleCmd("sm_redraft", Command_RestartDraft, "Vote to restart the current draft");
    RegConsoleCmd("sm_cancelmix", Command_CancelMix, "Cancel current mix");
    RegConsoleCmd("sm_helpmix", Command_HelpMix, "Show help menu with all commands");
    RegConsoleCmd("sm_help", Command_HelpMix, "Show help menu with all commands");
    
    AddCommandListener(Command_JoinTeam, "jointeam");
    AddCommandListener(Command_JoinTeam, "spectate");
    
    RegAdminCmd("sm_setcaptain", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain");
    RegAdminCmd("sm_adminpick", Command_AdminPick, ADMFLAG_GENERIC, "Force pick a player");
    RegAdminCmd("sm_autodraft", Command_AutoDraft, ADMFLAG_GENERIC, "Automatically draft teams");
    RegAdminCmd("sm_outline", Command_ToggleOutlines, ADMFLAG_GENERIC, "Toggle teammate outlines for all players");
    
    g_cvPickTimeout = CreateConVar("sm_mix_pick_timeout", "30.0", "Time limit for picks in seconds");
    g_cvCommandCooldown = CreateConVar("sm_mix_command_cooldown", "5.0", "Cooldown time for commands in seconds");
    g_cvGracePeriod = CreateConVar("sm_mix_grace_period", "60.0", "Time to wait for disconnected captain");
    g_cvTipsEnable = CreateConVar("sm_mix_tips_enable", "1", "Enable rotating mix tips in chat (1/0)");
    g_cvTipsInterval = CreateConVar("sm_mix_tips_interval", "90.0", "Interval in seconds between mix tips");
    
    g_cvPreGameEnable = CreateConVar("sm_mix_pregame_enable", "1", "Enable pre-game DM during lobby and draft");
    g_cvPreGameSpawnProtect = CreateConVar("sm_mix_pregame_spawnprotect", "1.0", "Pre-game DM spawn protection seconds");
    
    // SOAP TF2DM spawn convars
    g_hSpawnRandom = CreateConVar("sm_mix_spawnrandom", "1", "Enable random spawns.", FCVAR_NOTIFY);
    g_hTeamSpawnRandom = CreateConVar("sm_mix_teamspawnrandom", "0", "Enable random spawns independent of team", FCVAR_NOTIFY);
    
    HookEvent("teamplay_round_start", Event_RoundStart);
    HookEvent("teamplay_round_win", Event_RoundEnd);
    HookEvent("player_team", Event_PlayerTeam);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    g_hTipsTimer = CreateTimer(g_cvTipsInterval.FloatValue, Timer_Tips, _, TIMER_REPEAT);
    
    EnsureETF2LWhitelist();
}

public void OnMapStart() {
    g_iCaptain1 = -1;
    g_iCaptain2 = -1;
    g_bMixInProgress = false;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_iPicksRemaining = 0;
    g_bVoteInProgress = false;
    g_fPickTimerStartTime = 0.0;
    
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerLocked[i] = false;
        g_bPlayerVoted[i] = false;
    }
    
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hHudTimer);
    KillTimerSafely(g_hGraceTimer);
    KillTimerSafely(g_hVoteTimer);
    
    if (g_hRedSpawns != null) {
        delete g_hRedSpawns;
        g_hRedSpawns = null;
    }
    if (g_hBluSpawns != null) {
        delete g_hBluSpawns;
        g_hBluSpawns = null;
    }
    if (g_hKv != null) {
        delete g_hKv;
        g_hKv = null;
    }
    
    ServerCommand("mp_tournament 0");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
    ConVar cWait = FindConVar("mp_waitingforplayers_time");
    if (cWait != null) {
        SetConVarInt(cWait, 0);
    }

    g_bPreGameDMActive = GetConVarBool(g_cvPreGameEnable);
    
    if (g_bPreGameDMActive) {
        LoadSpawnPoints();
    }
    
    CreateTimer(2.0, Timer_ShowInfoCard);
}

public void OnClientPutInServer(int client) {
    if (IsValidClient(client)) {
        GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        g_bPlayerLocked[client] = false;
        
        // Check if we can start draft when new players join
        if (!g_bMixInProgress && g_iCaptain1 != -1 && g_iCaptain2 != -1) {
            CheckDraftStart();
        }
    }
}

public void OnClientDisconnect(int client) {
    if (!IsValidClient(client))
        return;
        
    if (client == g_iCaptain1 || client == g_iCaptain2) {
        SetClientName(client, g_sOriginalNames[client]);
    }
    
    if (client == g_iCaptain1) {
        g_iCaptain1 = -1;
        if (g_bMixInProgress) {
            if (!IsFakeClient(client) || g_iPicksRemaining <= 0) {
                StartGracePeriod(0);
            }
        } else {
            PrintToChatAll("\x01[Mix] \x03First captain has left the game!");
        }
    } else if (client == g_iCaptain2) {
        g_iCaptain2 = -1;
        if (g_bMixInProgress) {
            if (!IsFakeClient(client) || g_iPicksRemaining <= 0) {
                StartGracePeriod(1);
            }
        } else {
            PrintToChatAll("\x01[Mix] \x03Second captain has left the game!");
        }
    } else if (g_bMixInProgress && g_bPlayerPicked[client]) {
        // Handle drafted player disconnection - just let them leave
        PrintToChatAll("\x01[Mix] \x03%N has left the game! They can rejoin when they return.", client);
    }
    
    // Reset movement flag
    g_bPlayerMoved[client] = false;
    
    g_bPlayerLocked[client] = false;
    g_bPlayerPicked[client] = false;
}

public Action Command_Captain(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    if (g_bMixInProgress) {
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
            if (g_bMixInProgress) {
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
            if (g_bMixInProgress) {
                KillTimerSafely(g_hPickTimer);
                StartGracePeriod(1);
                Timer_UpdateHUD(g_hHudTimer);
            } else {
                PrintToChatAll("\x01[Mix] \x03%N\x01 is no longer a captain!", client);
            }
        }
        return Plugin_Handled;
    }
    
    if (g_bMixInProgress && g_iMissingCaptain != -1) {
        if (g_iMissingCaptain == 0) {
            g_iCaptain1 = client;
            if (strlen(g_sOriginalNames[client]) == 0) {
                GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
            }
            char newName[MAX_NAME_LENGTH];
            Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
            SetClientName(client, newName);
            PrintToChatAll("\x01[Mix] \x03%N\x01 has become the replacement first captain!", client);
            
            KillTimerSafely(g_hGraceTimer);
            g_iMissingCaptain = -1;
            
            ResumeDraft();
            Timer_UpdateHUD(g_hHudTimer);
            return Plugin_Handled;
        } else {
            g_iCaptain2 = client;
            if (strlen(g_sOriginalNames[client]) == 0) {
                GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
            }
            char newName[MAX_NAME_LENGTH];
            Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
            SetClientName(client, newName);
            PrintToChatAll("\x01[Mix] \x03%N\x01 has become the replacement second captain!", client);
            
            KillTimerSafely(g_hGraceTimer);
            g_iMissingCaptain = -1;
            
            ResumeDraft();
            Timer_UpdateHUD(g_hHudTimer);
            return Plugin_Handled;
        }
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
    if (g_bMixInProgress) return;
    TransitionToDraft();
    UpdateHUDForAll(); // Force immediate HUD update
}

void TransitionToDraft() {
    // Reset all timers and states
    ResetAllTimers();
    
    // Set draft state
    g_bMixInProgress = true;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_bVoteInProgress = false;
    g_iPicksRemaining = 10;
    
    // Set game state for draft - ENABLE TOURNAMENT MODE FIRST
    // Check if tournament mode is already enabled
    ConVar tournamentCvar = FindConVar("mp_tournament");
    if (tournamentCvar != null && !GetConVarBool(tournamentCvar)) {
        ServerCommand("mp_tournament 1");
    }
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("mp_forceautoteam 0");
    ServerCommand("tf_bot_quota_mode none");
    ServerCommand("tf_bot_quota 0");
    
    // Competitive rules are applied once at match start (EndDraft)
    
    // Wait a frame for tournament mode to take effect before moving players
    CreateTimer(0.1, Timer_StartDraftAfterTournament);

    // Enable pre-game DM during draft if allowed
    g_bPreGameDMActive = GetConVarBool(g_cvPreGameEnable);
    
    // Initialize spawn points for pre-game DM
    if (g_bPreGameDMActive) {
        LoadSpawnPoints();
    }
}


public Action Command_JoinTeam(int client, const char[] command, int argc) {
    if (!IsValidClient(client)) {
        return Plugin_Continue;
    }
    
    if (!g_bMixInProgress) {
        return Plugin_Continue;
    }
    
    PrintToChat(client, "\x01[Mix] \x03Teams are managed by the plugin during the mix! Use !draft to pick players.");
    return Plugin_Handled;
}

public Action Command_Draft(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;

    if (!g_bMixInProgress || g_iPicksRemaining <= 0) {
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

    if (!g_bMixInProgress || g_iPicksRemaining <= 0) {
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
    int validSpectators = 0;
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && IsClientInGame(i)) {
            int team = GetClientTeam(i);
            if (view_as<TFTeam>(team) == TFTeam_Spectator) {
                spectators.Push(i);
                validSpectators++;
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
    if (g_bCountdownActive) {
        StopCountdown();
    }
    
    // Check if teams are still complete
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    
    if (redCount == 6 && bluCount == 6) {
        StartCountdown();
        return;
    }
    
    if (g_iPicksRemaining <= 0) {
        PrintToChatAll("\x01[Mix] \x03Cannot end draft! Teams must have exactly 6 players each.");
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
        
    if (view_as<TFTeam>(GetClientTeam(target)) != TFTeam_Spectator) {
        ReplyToCommand(captain, "\x01[Mix] \x03That player is not in the spectator team!");
        return;
    }
    
    int team = view_as<TFTeam>(GetClientTeam(captain));
    
    // Check if captain's team is already full (6 players)
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    
    if ((team == 2 && redCount >= 6) || (team == 3 && bluCount >= 6)) {
        ReplyToCommand(captain, "\x01[Mix] \x03Your team is already full! Use !remove to make space first.");
        return;
    }
    
    TF2_ChangeClientTeam(target, view_as<TFTeam>(team));
    g_bPlayerLocked[target] = true;
    g_bPlayerPicked[target] = true;
    
    g_iPicksRemaining--;
    
    PrintToChatAll("\x01[Mix] \x03%N has been drafted to the %s team!", target, (view_as<TFTeam>(team) == TFTeam_Red) ? "RED" : "BLU");
    
    // Check if teams are now complete
    GetTeamSizes(redCount, bluCount);
    
    if (redCount == 6 && bluCount == 6) {
        StartCountdown();
        return;
    }
    
    if (g_iPicksRemaining <= 0) {
        PrintToChatAll("\x01[Mix] \x03Cannot end draft! Teams must have exactly 6 players each.");
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
    g_bMixInProgress = true;
    
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hVoteTimer);
    StopCountdown();
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            g_bPlayerLocked[i] = true;
        }
    }
    
    ServerCommand("mp_tournament 1");
    
    ApplyETF2LSharedSettings();
    ApplyETF2LMapSettingsForCurrentMap();
    
    if (IsKothMap()) {
        PrintToChatAll("\x01[Mix] \x03Draft complete! Mix has started (ETF2L 6v6, KOTH winlimit 3).");
    } else {
        PrintToChatAll("\x01[Mix] \x03Draft complete! Mix has started (ETF2L 6v6, 5CP winlimit 5).");
    }
    
    g_bPreGameDMActive = false;
    
    // Clear hint text for all players
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i)) {
            PrintHintText(i, "");
        }
    }
    
    ServerCommand("mp_restartgame 1");
}


public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    bool disconnect = event.GetBool("disconnect");
    
    if (!IsValidClient(client) || disconnect)
        return Plugin_Continue;
    
    if (!g_bMixInProgress) {
        return Plugin_Continue;
    }
    
    if (IsFakeClient(client) && g_iPicksRemaining > 0) {
        return Plugin_Continue;
    }
    
    if (g_bPlayerLocked[client]) {
        PrintToChat(client, "\x01[Mix] \x03You are locked to your team! Teams are managed by the plugin.");
        CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        return Plugin_Handled;
    }
    
    if (g_iPicksRemaining > 0 && client != g_iCaptain1 && client != g_iCaptain2) {
        PrintToChat(client, "\x01[Mix] \x03You must wait to be drafted by a captain! Teams are managed by the plugin.");
        CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        return Plugin_Handled;
    }
    
    if (g_iPicksRemaining <= 0) {
        PrintToChat(client, "\x01[Mix] \x03Teams are locked during the mix! Teams are managed by the plugin.");
        CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        return Plugin_Handled;
    }
    
    return Plugin_Continue;
}

public Action Timer_ForceTeam(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client) || !g_bMixInProgress) {
        return Plugin_Stop;
    }
    
    if (IsFakeClient(client) && g_iPicksRemaining > 0) {
        return Plugin_Stop;
    }
    
    int currentTeam = GetClientTeam(client);
    
    if (g_bPlayerLocked[client]) {
        int correctTeam = -1;
        
        if (client == g_iCaptain1) {
            correctTeam = GetClientTeam(g_iCaptain1);
        } else if (client == g_iCaptain2) {
            correctTeam = GetClientTeam(g_iCaptain2);
        } else {
            if (IsValidClient(g_iCaptain1) && GetClientTeam(g_iCaptain1) == currentTeam) {
                correctTeam = currentTeam;
            } else if (IsValidClient(g_iCaptain2) && GetClientTeam(g_iCaptain2) == currentTeam) {
                correctTeam = currentTeam;
            } else {
                g_bPlayerLocked[client] = false;
                PrintToChat(client, "\x01[Mix] \x03Could not determine your team, unlocking.");
                return Plugin_Stop;
            }
        }
        
        if (correctTeam != -1 && correctTeam != currentTeam) {
            TF2_ChangeClientTeam(client, view_as<TFTeam>(correctTeam));
            PrintToChat(client, "\x01[Mix] \x03You are locked to your team!");
        }
        return Plugin_Stop;
    }
    
    if (g_iPicksRemaining > 0 && client != g_iCaptain1 && client != g_iCaptain2) {
        if (view_as<TFTeam>(currentTeam) != TFTeam_Spectator) {
            TF2_ChangeClientTeam(client, TFTeam_Spectator);
            PrintToChat(client, "\x01[Mix] \x03You must wait to be drafted by a captain!");
        }
        return Plugin_Stop;
    }
    
    if (g_iPicksRemaining <= 0) {
        PrintToChat(client, "\x01[Mix] \x03Teams are locked during the mix!");
        return Plugin_Stop;
    }
    
    return Plugin_Stop;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    if (g_bPreGameDMActive && GetConVarBool(g_cvPreGameEnable)) {
        // Reset movement flag - player will teleport on first movement
        g_bPlayerMoved[client] = false;
        float prot = GetConVarFloat(g_cvPreGameSpawnProtect);
        if (prot > 0.0) {
            TF2_AddCondition(client, TFCond_UberchargedHidden, prot);
        }
    }
        
    if ((client == g_iCaptain1 || client == g_iCaptain2) && !StrContains(g_sOriginalNames[client], "[CAP]")) {
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
        SetClientName(client, newName);
    }
    
    if (g_bMixInProgress && g_bPlayerLocked[client]) {
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
        
    if (g_bMixInProgress && g_bPlayerLocked[client]) {
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
        
    if (g_bPreGameDMActive && GetConVarBool(g_cvPreGameEnable)) {
        int attacker = GetClientOfUserId(event.GetInt("attacker"));
        if (IsValidClient(attacker) && attacker != client) {
            TF2_RegeneratePlayer(attacker);
        }
        
        // Reset movement flag for respawn
        g_bPlayerMoved[client] = false;
    }
        
    if (g_bMixInProgress && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        }
    }
    
    return Plugin_Continue;
}


public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    if (!IsValidClient(client) || !IsPlayerAlive(client)) {
        return Plugin_Continue;
    }
    
    // Check if player is in DM and hasn't moved yet
    if (g_bPreGameDMActive && !g_bPlayerMoved[client]) {
        // Check for movement (WASD keys) - only trigger once
        if (buttons & (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT)) {
            g_bPlayerMoved[client] = true;
            
            // Teleport to random spawn
            float origin[3];
            if (GetSpawnPoint(client, origin)) {
                // Find ground level to prevent spawning underground
                float groundOrigin[3];
                if (FindGroundLevel(origin, groundOrigin)) {
                    origin = groundOrigin;
                }
                
                float spawnAngles[3] = {0.0, 0.0, 0.0};
                float zeroVel[3] = {0.0, 0.0, 0.0};
                TeleportEntity(client, origin, spawnAngles, zeroVel);
            }
        }
    }
    
    return Plugin_Continue;
}


public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    if (!g_bMixInProgress) {
        g_iCaptain1 = -1;
        g_iCaptain2 = -1;
        g_iCurrentPicker = 0;
    }
    
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hGraceTimer);
    KillTimerSafely(g_hVoteTimer);
    
    // Restart HUD timer
    KillTimerSafely(g_hHudTimer);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    if (!g_bMixInProgress) {
        for (int i = 1; i <= MaxClients; i++) {
            g_bPlayerLocked[i] = false;
        }
    }
    
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    return Plugin_Continue;
}




void ShowRestartVoteMenu(int client) {
    if (!IsValidClient(client))
        return;
        
    Menu menu = new Menu(RestartVoteMenuHandler, MENU_ACTIONS_ALL);
    menu.SetTitle("Restart Draft Vote - What would you like to do?");
    
    menu.AddItem("continue", "Continue with current draft");
    menu.AddItem("restart", "Restart draft from beginning");
    
    menu.ExitButton = false;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int RestartVoteMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    switch (action) {
        case MenuAction_End: {
            delete menu;
        }
        case MenuAction_Select: {
            if (!IsValidClient(param1) || g_bPlayerVoted[param1])
                return 0;
                
            g_bPlayerVoted[param1] = true;
            
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            
            if (StrEqual(info, "continue")) {
                g_iVoteCount[0]++;
                PrintToChatAll("\x01[Mix] \x03%N\x01 voted to continue with current draft", param1);
            } else if (StrEqual(info, "restart")) {
                g_iVoteCount[1]++;
                PrintToChatAll("\x01[Mix] \x03%N\x01 voted to restart the draft", param1);
            }
        }
        case MenuAction_Cancel: {
            if (param2 == MenuCancel_Exit) {
                if (IsValidClient(param1)) {
                    PrintToChat(param1, "\x01[Mix] \x03You must vote to continue!");
                    ShowRestartVoteMenu(param1);
                }
            }
        }
    }
    return 0;
}

public Action Timer_EndRestartVote(Handle timer) {
    g_hVoteTimer = INVALID_HANDLE;
    
    int totalVotes = g_iVoteCount[0] + g_iVoteCount[1];
    if (totalVotes == 0) {
        PrintToChatAll("\x01[Mix] \x03No votes cast. Continuing with current draft.");
        return Plugin_Stop;
    }
    
    if (g_iVoteCount[1] > g_iVoteCount[0]) {
        PrintToChatAll("\x01[Mix] \x03Vote passed: Restarting draft from beginning.");
        EndMix(true);
    } else {
        PrintToChatAll("\x01[Mix] \x03Vote failed: Continuing with current draft.");
    }
    
    return Plugin_Stop;
}


public void EndMix(bool startNewDraft) {
    if (startNewDraft) {
        TransitionToDraft();
    } else {
        TransitionToNormal();
    }
    UpdateHUDForAll(); // Force immediate HUD update
}

void TransitionToNormal() {
    ResetAllTimers();
    
    g_bMixInProgress = false;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_bVoteInProgress = false;
    
    if (g_iCaptain1 != -1) {
        SetClientName(g_iCaptain1, g_sOriginalNames[g_iCaptain1]);
        g_iCaptain1 = -1;
    }
    if (g_iCaptain2 != -1) {
        SetClientName(g_iCaptain2, g_sOriginalNames[g_iCaptain2]);
        g_iCaptain2 = -1;
    }
    
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerPicked[i] = false;
        g_sOriginalNames[i][0] = '\0';
        g_iOriginalTeam[i] = 0;
    }
    
    ServerCommand("mp_tournament 0");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    
    ResetAllPlayerTeams();
    
    PrintToChatAll("\x01[Mix] \x03Mix has ended. Teams are now unlocked.");

    g_bPreGameDMActive = GetConVarBool(g_cvPreGameEnable);
    
    if (g_bPreGameDMActive) {
        LoadSpawnPoints();
    }
}

void UpdateHUDForAll() {
    char buffer[256];
    
    if (g_bMixInProgress) {
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
            
            Format(buffer, sizeof(buffer), "DRAFT IN PROGRESS\n%s's turn to pick\nTime: %.0fs\nRED: %d/6 | BLU: %d/6", 
                   captainName, timeLeft, redTeamSize, bluTeamSize);
        }
        else if (g_bCountdownActive) {
            Format(buffer, sizeof(buffer), "GAME STARTING IN %d SECONDS...", g_iCountdownSeconds);
        }
        else {
            // Don't show hint text when game is actually running
            buffer[0] = '\0';
        }
    } else {
        Format(buffer, sizeof(buffer), "Type !captain to become a captain");
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
    
    if (!g_bMixInProgress || g_iPicksRemaining > 0) {
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
    
    if (g_hTipsTimer != INVALID_HANDLE) {
        KillTimer(g_hTipsTimer);
    }
    g_hTipsTimer = CreateTimer(g_cvTipsInterval.FloatValue, Timer_Tips, _, TIMER_REPEAT);
    return Plugin_Stop;
}

public Action Timer_PickTime(Handle timer) {
    if (!g_bMixInProgress || g_iMissingCaptain != -1) {
        return Plugin_Continue;
    }
    
    float currentTime = GetGameTime();
    float timeLeft = g_cvPickTimeout.FloatValue - (currentTime - g_fPickTimerStartTime);
    
    if (timeLeft <= 0.0) {
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        int nextPlayer = FindNextAvailablePlayer();
        
        if (nextPlayer != -1) {
            PickPlayer(currentCaptain, nextPlayer);
        } else {
            EndDraft();
        }
    }
    
    return Plugin_Continue;
}

public Action Timer_GracePeriod(Handle timer) {
    if (!g_bMixInProgress || g_iMissingCaptain == -1) {
        return Plugin_Stop;
    }
    
    float currentTime = GetGameTime();
    float timeLeft = g_cvGracePeriod.FloatValue - (currentTime - g_fPickTimerStartTime);
    
    if (timeLeft <= 0.0) {
        PrintToChatAll("\x01[Mix] \x03Grace period expired. Cancelling mix.");
        EndMix(false);
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
    if (g_iMissingCaptain != -1 || !g_bMixInProgress) {
        if (g_iMissingCaptain == missingCaptain) return;
        if (!g_bMixInProgress) return;
    }
    
    g_iMissingCaptain = missingCaptain;
    
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hGraceTimer);
    
    g_fPickTimerStartTime = GetGameTime();
    g_hGraceTimer = CreateTimer(1.0, Timer_GracePeriod, _, TIMER_REPEAT);
    
    KillTimerSafely(g_hHudTimer);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    UpdateHUDForAll();
    
    PrintToChatAll("\x01[Mix] \x03A captain has left! You have %.0f seconds to type !captain to replace them.", g_cvGracePeriod.FloatValue);
}

void ResumeDraft() {
    if (!g_bMixInProgress || g_iMissingCaptain == -1) return;
    
    KillTimerSafely(g_hGraceTimer);
    
    g_iMissingCaptain = -1;
    
    g_fPickTimerStartTime = GetGameTime();
    g_hPickTimer = CreateTimer(1.0, Timer_PickTime, _, TIMER_REPEAT);
    
    KillTimerSafely(g_hHudTimer);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    UpdateHUDForAll();
    
    PrintToChatAll("\x01[Mix] \x03Draft has resumed! Current captain's turn to pick.");
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
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!g_bMixInProgress) {
        ReplyToCommand(client, "\x01[Mix] \x03No mix is currently in progress!");
        return Plugin_Handled;
    }
    
    if (g_bVoteInProgress) {
        ReplyToCommand(client, "\x01[Mix] \x03A vote is already in progress!");
        return Plugin_Handled;
    }
    
    // Count total players
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i)) {
            totalPlayers++;
        }
    }
    
    // Calculate 30% requirement
    int requiredPlayers = RoundToCeil(float(totalPlayers) * 0.3);
    if (requiredPlayers < 2) requiredPlayers = 2; // Minimum 2 players
    
    // Count how many players have used the command
    int commandUsers = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && g_bPlayerVoted[i]) {
            commandUsers++;
        }
    }
    
    // Mark this player as having used the command
    if (!g_bPlayerVoted[client]) {
        g_bPlayerVoted[client] = true;
        commandUsers++;
        PrintToChatAll("\x01[Mix] \x03%N wants to restart the draft! (%d/%d players required)", client, commandUsers, requiredPlayers);
    } else {
        ReplyToCommand(client, "\x01[Mix] \x03You have already voted to restart the draft!");
        return Plugin_Handled;
    }
    
    // Check if we have enough players
    if (commandUsers >= requiredPlayers) {
        // Start the actual vote
        StartRestartVote();
    } else {
        // Reset vote tracking after 30 seconds if not enough players
        CreateTimer(30.0, Timer_ResetRestartVote);
    }
    
    return Plugin_Handled;
}

void StartRestartVote() {
    g_bVoteInProgress = true;
    g_iVoteCount[0] = 0;
    g_iVoteCount[1] = 0;
    
    // Reset all player vote tracking
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerVoted[i] = false;
    }
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            ShowRestartVoteMenu(i);
        }
    }
    
    if (g_hVoteTimer != INVALID_HANDLE) {
        KillTimer(g_hVoteTimer);
    }
    g_hVoteTimer = CreateTimer(30.0, Timer_EndRestartVote);
    
    PrintToChatAll("\x01[Mix] \x03Restart draft vote started! You have 30 seconds to vote.");
}

public Action Timer_ResetRestartVote(Handle timer) {
    // Reset all player vote tracking
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerVoted[i] = false;
    }
    return Plugin_Stop;
}


void CancelMix(int admin) {
    g_bMixInProgress = false;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_iPicksRemaining = 0;
    g_bVoteInProgress = false;
    g_fPickTimerStartTime = 0.0;
    
    KillAllTimers();
    
    if (g_iCaptain1 != -1 && IsValidClient(g_iCaptain1)) {
        SetClientName(g_iCaptain1, g_sOriginalNames[g_iCaptain1]);
        g_iCaptain1 = -1;
    }
    if (g_iCaptain2 != -1 && IsValidClient(g_iCaptain2)) {
        SetClientName(g_iCaptain2, g_sOriginalNames[g_iCaptain2]);
        g_iCaptain2 = -1;
    }
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            g_bPlayerLocked[i] = false;
            g_bPlayerPicked[i] = false;
            g_iOriginalTeam[i] = 0;
        }
    }
    
    ServerCommand("mp_tournament 0");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    
    ServerCommand("mp_restartgame 1");
    
    if (admin == -1) {
        PrintToChatAll("\x01[Mix] \x03Mix has been cancelled by vote! Teams are now unlocked.");
    } else {
        PrintToChatAll("\x01[Mix] \x03Mix has been cancelled by admin %N! Teams are now unlocked.", admin);
    }
    
    CreateTimer(1.0, Timer_VerifyTeamUnlock);

    g_bPreGameDMActive = GetConVarBool(g_cvPreGameEnable);
    
    if (g_bPreGameDMActive) {
        LoadSpawnPoints();
    }
}

public Action Timer_VerifyTeamUnlock(Handle timer) {
    if (GetConVarBool(FindConVar("mp_tournament"))) {
        ServerCommand("mp_tournament 0");
    }
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            g_bPlayerLocked[i] = false;
            g_bPlayerPicked[i] = false;
        }
    }
    
    return Plugin_Stop;
}

public Action Command_AutoDraft(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    if (!CheckCommandAccess(client, "sm_autodraft", ADMFLAG_GENERIC)) {
        ReplyToCommand(client, "\x01[Mix] \x03You do not have permission to use this command!");
        return Plugin_Handled;
    }
    
    if (!g_bMixInProgress) {
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
    int totalPicksNeeded = 10;
    
    while (g_iPicksRemaining > 0 && spectators.Length > 0 && draftedCount < totalPicksNeeded) {
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        
        int randomIndex = GetRandomInt(0, spectators.Length - 1);
        int targetClient = spectators.Get(randomIndex);
        
        spectators.Erase(randomIndex);
        
        PickPlayer(currentCaptain, targetClient);
        draftedCount++;
    }
    
    delete spectators;
    
    ReplyToCommand(client, "\x01[Mix] \x03Auto-drafted %d players.", draftedCount);
    
    return Plugin_Handled;
}

void KillAllTimers() {
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hGraceTimer);
    KillTimerSafely(g_hHudTimer);
    KillTimerSafely(g_hVoteTimer);
}

void ResetAllTimers() {
    KillAllTimers();
    g_hPickTimer = INVALID_HANDLE;
    g_hGraceTimer = INVALID_HANDLE;
    g_hHudTimer = INVALID_HANDLE;
    g_hVoteTimer = INVALID_HANDLE;
}

// Team management functions
void MovePlayerToTeam(int client, TFTeam team) {
    if (!IsValidClient(client)) return;
    
    if (g_iOriginalTeam[client] == 0) {
        g_iOriginalTeam[client] = GetClientTeam(client);
    }
    
    TF2_ChangeClientTeam(client, team);
}

void ResetPlayerTeam(int client) {
    if (!IsValidClient(client)) return;
    
    if (g_iOriginalTeam[client] > 0) {
        TF2_ChangeClientTeam(client, view_as<TFTeam>(g_iOriginalTeam[client]));
    } else {
        TF2_ChangeClientTeam(client, TFTeam_Spectator);
    }
    
    g_iOriginalTeam[client] = 0;
}

void ResetAllPlayerTeams() {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            ResetPlayerTeam(i);
        }
    }
}

// Add these functions at the end of the file
public Action Command_SetCaptain(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
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
            if (g_bMixInProgress) {
                StartGracePeriod(0);
            }
            ReplyToCommand(client, "\x01[Mix] \x03Removed %N's first captain status.", targetClient);
            PrintToChat(targetClient, "\x01[Mix] \x03Your first captain status has been removed by an admin.");
        } else {
            g_iCaptain2 = -1;
            SetClientName(targetClient, g_sOriginalNames[targetClient]);
            if (g_bMixInProgress) {
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
        
    if (!g_bMixInProgress) {
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
    
    int team = view_as<TFTeam>(GetClientTeam(currentCaptain));
    TF2_ChangeClientTeam(targetClient, view_as<TFTeam>(team));
    g_bPlayerLocked[targetClient] = true;
    
    g_iPicksRemaining--;
    
    PrintToChatAll("\x01[Mix] \x03Admin %N has picked %N for the %s team!", client, targetClient, (view_as<TFTeam>(team) == TFTeam_Red) ? "RED" : "BLU");
    
    if (g_iPicksRemaining <= 0) {
        EndDraft();
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
    
    if (!g_bMixInProgress) {
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
    if (!g_bMixInProgress)
        return Plugin_Stop;
        
    int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    
    if (!IsValidClient(currentCaptain)) {
        PrintToChatAll("\x01[Mix] \x03Current captain is unavailable. Draft may need to be cancelled.");
        KillTimerSafely(g_hPickTimer);
        g_fPickTimerStartTime = 0.0;
        UpdateHUDForAll();
        return Plugin_Stop;
    }
    
    // Check if current captain's team is full
    int redCount, bluCount;
    GetTeamSizes(redCount, bluCount);
    int captainTeam = GetClientTeam(currentCaptain);
    
    if ((captainTeam == 2 && redCount >= 6) || (captainTeam == 3 && bluCount >= 6)) {
        // Captain's team is full, skip to next captain
        g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
        int nextCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        
        if (IsValidClient(nextCaptain)) {
            PrintToChatAll("\x01[Mix] \x03%N's team is full! Skipping to %N's turn.", currentCaptain, nextCaptain);
            CreateTimer(0.5, Timer_OpenDraftMenu, GetClientUserId(nextCaptain));
            
            KillTimerSafely(g_hPickTimer);
            g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
            g_fPickTimerStartTime = GetGameTime();
        } else {
            PrintToChatAll("\x01[Mix] \x03Both teams are full! Ending draft.");
            EndDraft();
        }
        return Plugin_Stop;
    }
    
    int randomPlayer = FindNextAvailablePlayer();
    
    if (randomPlayer != -1) {
        PrintToChatAll("\x01[Mix] \x03Pick timed out! Auto-picking random player.");
        PickPlayer(currentCaptain, randomPlayer);
    } else {
        PrintToChatAll("\x01[Mix] \x03Pick timed out! No players available. Ending draft.");
        EndDraft();
    }
    
    return Plugin_Stop;
}


public Action Timer_StartDraftAfterTournament(Handle timer) {
    if (!g_bMixInProgress) {
        return Plugin_Stop;
    }
    
    int team1 = GetRandomInt(TFTeam_Red, TFTeam_Blue);
    int team2 = (view_as<TFTeam>(team1) == TFTeam_Red) ? TFTeam_Blue : TFTeam_Red;
    
    MovePlayerToTeam(g_iCaptain1, view_as<TFTeam>(team1));
    MovePlayerToTeam(g_iCaptain2, view_as<TFTeam>(team2));
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && i != g_iCaptain1 && i != g_iCaptain2) {
            MovePlayerToTeam(i, TFTeam_Spectator);
        }
    }
    
    g_fPickTimerStartTime = GetGameTime();
    g_hPickTimer = CreateTimer(1.0, Timer_PickTime, _, TIMER_REPEAT);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    PrintToChatAll("\x01[Mix] \x03Draft has started! First captain's turn to pick.");
    
    int firstCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    if (IsValidClient(firstCaptain)) {
        CreateTimer(0.5, Timer_OpenDraftMenu, GetClientUserId(firstCaptain));
    }
    
    return Plugin_Stop;
}

public Action Timer_OpenDraftMenu(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client) || !g_bMixInProgress || g_iPicksRemaining <= 0) {
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
    PrintToServer("[Mix] Created ETF2L whitelist at %s", ETF2L_WHITELIST_PATH);
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

void ApplyETF2LSharedSettings() {
    SetCvarString("mp_tournament_whitelist", ETF2L_WHITELIST_PATH);
    
    SetCvarInt("tf_tournament_classlimit_scout", 2);
    SetCvarInt("tf_tournament_classlimit_soldier", 2);
    SetCvarInt("tf_tournament_classlimit_pyro", 1);
    SetCvarInt("tf_tournament_classlimit_demoman", 1);
    SetCvarInt("tf_tournament_classlimit_heavy", 1);
    SetCvarInt("tf_tournament_classlimit_engineer", 1);
    SetCvarInt("tf_tournament_classlimit_medic", 1);
    SetCvarInt("tf_tournament_classlimit_sniper", 1);
    SetCvarInt("tf_tournament_classlimit_spy", 2);
}

bool IsKothMap() {
    char map[64];
    GetCurrentMap(map, sizeof(map));
    return StrContains(map, "koth_", false) == 0;
}

void ApplyETF2LMapSettingsForCurrentMap() {
    if (IsKothMap()) {
        SetCvarInt("mp_maxrounds", 0);
        SetCvarInt("mp_timelimit", 0);
        SetCvarInt("mp_windifference", 0);
        SetCvarInt("mp_winlimit", 3);
    } else {
        SetCvarInt("mp_maxrounds", 0);
        SetCvarInt("mp_timelimit", 30);
        SetCvarInt("mp_windifference", 5);
        SetCvarInt("mp_winlimit", 5);
    }
}


void LoadSpawnPoints() {
    // SOAP TF2DM spawn system - exact copy
    g_bSpawnRandom = GetConVarBool(g_hSpawnRandom);
    g_bTeamSpawnRandom = GetConVarBool(g_hTeamSpawnRandom);
    
    if (g_hRedSpawns != null) {
        delete g_hRedSpawns;
    }
    if (g_hBluSpawns != null) {
        delete g_hBluSpawns;
    }
    if (g_hKv != null) {
        delete g_hKv;
    }
    
    g_hRedSpawns = new ArrayList(3);
    g_hBluSpawns = new ArrayList(3);
    g_hKv = new KeyValues("Spawns");
    
    char map[64];
    GetCurrentMapLowercase(map, sizeof(map));
    
    char path[256];
    BuildPath(Path_SM, path, sizeof(path), "configs/mixes/%s.cfg", map);
    
    LoadMapConfig(map, path);
}

void LoadMapConfig(const char[] map, const char[] path) {
    if (FileExists(path)) {
        if (FileToKeyValues(g_hKv, path)) {
            LoadSpawnsFromConfig();
            PrintToServer("[Mix] Loaded spawns from %s", path);
        } else {
            LoadDefaultSpawns();
            PrintToServer("[Mix] Failed to load config for %s, using default spawns", map);
        }
    } else {
        LoadDefaultSpawns();
        PrintToServer("[Mix] No config found for %s, using default spawns", map);
    }
}

void LoadSpawnsFromConfig() {
    // Load spawns from config with correct format (origin + angles)
    if (KvJumpToKey(g_hKv, "red", false)) {
        if (KvGotoFirstSubKey(g_hKv, false)) {
            do {
                char originStr[64];
                KvGetString(g_hKv, "origin", originStr, sizeof(originStr));
                
                if (strlen(originStr) > 0) {
                    float origin[3];
                    if (StringToVector(originStr, origin)) {
                        g_hRedSpawns.PushArray(origin);
                    }
                }
            } while (KvGotoNextKey(g_hKv, false));
            KvGoBack(g_hKv);
        }
        KvGoBack(g_hKv);
    }
    
    if (KvJumpToKey(g_hKv, "blue", false)) {
        if (KvGotoFirstSubKey(g_hKv, false)) {
            do {
                char originStr[64];
                KvGetString(g_hKv, "origin", originStr, sizeof(originStr));
                
                if (strlen(originStr) > 0) {
                    float origin[3];
                    if (StringToVector(originStr, origin)) {
                        g_hBluSpawns.PushArray(origin);
                    }
                }
            } while (KvGotoNextKey(g_hKv, false));
            KvGoBack(g_hKv);
        }
        KvGoBack(g_hKv);
    }
}

void LoadDefaultSpawns() {
    // SOAP TF2DM default spawn loading - exact copy
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "info_player_teamspawn")) > 0) {
        if (!IsValidEntity(ent)) continue;
        
        float origin[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
        
        int team = GetEntProp(ent, Prop_Send, "m_iTeamNum");
        
        if (team == 2) {
            g_hRedSpawns.PushArray(origin);
        } else if (team == 3) {
            g_hBluSpawns.PushArray(origin);
        }
    }
}




public bool TraceFilter_NoPlayers(int entity, int contentsMask) {
    return entity == 0;
}

void GetCurrentMapLowercase(char[] map, int sizeofMap) {
    GetCurrentMap(map, sizeofMap);
    // TF2 is case-insensitive when dealing with map names
    for (int i = 0; i < sizeofMap; ++i) {
        map[i] = CharToLower(map[i]);
    }
}

bool StringToVector(const char[] str, float vec[3]) {
    char parts[3][32];
    int count = ExplodeString(str, " ", parts, sizeof(parts), sizeof(parts[]));
    
    if (count != 3) {
        return false;
    }
    
    vec[0] = StringToFloat(parts[0]);
    vec[1] = StringToFloat(parts[1]);
    vec[2] = StringToFloat(parts[2]);
    
    return true;
}

bool GetSpawnPoint(int client, float origin[3]) {
    // SOAP TF2DM spawn point selection - exact copy
    if (!g_bSpawnRandom) {
        return false;
    }
    
    int team = GetClientTeam(client);
    ArrayList spawns = null;
    
    if (g_bTeamSpawnRandom) {
        // Use all spawns regardless of team
        spawns = new ArrayList(3);
        for (int i = 0; i < g_hRedSpawns.Length; i++) {
            float spawn[3];
            g_hRedSpawns.GetArray(i, spawn);
            spawns.PushArray(spawn);
        }
        for (int i = 0; i < g_hBluSpawns.Length; i++) {
            float spawn[3];
            g_hBluSpawns.GetArray(i, spawn);
            spawns.PushArray(spawn);
        }
    } else {
        // Use team-specific spawns
        if (team == 2) {
            spawns = g_hRedSpawns;
        } else if (team == 3) {
            spawns = g_hBluSpawns;
        }
    }
    
    if (spawns == null || spawns.Length == 0) {
        if (g_bTeamSpawnRandom && spawns != null) {
            delete spawns;
        }
        return false;
    }
    
    int randomIndex = GetRandomInt(0, spawns.Length - 1);
    spawns.GetArray(randomIndex, origin);
    
    if (g_bTeamSpawnRandom && spawns != null) {
        delete spawns;
    }
    
    return true;
}

bool FindGroundLevel(const float origin[3], float groundOrigin[3]) {
    groundOrigin = origin;
    
    // Trace down to find ground
    float traceStart[3], traceEnd[3];
    traceStart = origin;
    traceEnd = origin;
    traceEnd[2] -= 1000.0; // Trace down 1000 units
    
    TR_TraceRayFilter(traceStart, traceEnd, MASK_SOLID, RayType_EndPoint, TraceFilter_NoPlayers);
    
    if (TR_DidHit()) {
        TR_GetEndPosition(groundOrigin);
        groundOrigin[2] += 5.0; // Well above ground to avoid fringe cases
        return true;
    }
    
    return false;
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
    if (g_bCountdownActive) return;
    
    g_bCountdownActive = true;
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
    if (!g_bCountdownActive) return;
    
    g_bCountdownActive = false;
    KillTimerSafely(g_hCountdownTimer);
    
    PrintToChatAll("\x01[Mix] \x03Countdown cancelled - draft continues!");
    UpdateHUDForAll();
}

public Action Timer_Countdown(Handle timer) {
    g_iCountdownSeconds--;
    
    if (g_iCountdownSeconds <= 0) {
        g_bCountdownActive = false;
        KillTimerSafely(g_hCountdownTimer);
        EndDraft();
    return Plugin_Stop;
    }
    
    UpdateHUDForAll();
    return Plugin_Continue;
}

public Action Timer_ShowInfoCard(Handle timer) {
PrintToServer("+----------------------------------------------+");
PrintToServer("|               TF2-Mixes v0.2.0               |");
PrintToServer("|     vexx-sm | Type !helpmix for commands     |");
PrintToServer("+----------------------------------------------+");
    return Plugin_Stop;
}
    
void ShowHelpMenu(int client) {
    PrintToChat(client, "\x01[Mix] \x07FFFFFFPlayer Commands:");
    PrintToChat(client, "\x01[Mix] \x0700FF00!captain \x07FFFFFF- Become a captain");
    PrintToChat(client, "\x01[Mix] \x0700FF00!draft/pick \x07FFFFFF- Draft a player (captains only)");
    PrintToChat(client, "\x01[Mix] \x0700FF00!remove \x07FFFFFF- Remove a player from your team (captains only)");
    PrintToChat(client, "\x01[Mix] \x0700FF00!restart/redraft \x07FFFFFF- Vote to restart draft (30% of players required)");
    PrintToChat(client, "\x01[Mix] \x0700FF00!helpmix/help \x07FFFFFF- Show this help menu");
    PrintToChat(client, "\x01[Mix] \x07FFFFFFAdmin Commands:");
    PrintToChat(client, "\x01[Mix] \x07FF0000!setcaptain \x07FFFFFF- Set a player as captain");
    PrintToChat(client, "\x01[Mix] \x07FF0000!adminpick \x07FFFFFF- Force pick a player");
    PrintToChat(client, "\x01[Mix] \x07FF0000!autodraft \x07FFFFFF- Auto-draft remaining players");
    PrintToChat(client, "\x01[Mix] \x07FF0000!outline \x07FFFFFF- Toggle teammate outlines for all players");
    PrintToChat(client, "\x01[Mix] \x07FF0000!cancelmix \x07FFFFFF- Cancel current mix");
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



public void OnPluginEnd() {
    // Clean up spawn point arrays
    if (g_hRedSpawns != null) {
        delete g_hRedSpawns;
    }
    if (g_hBluSpawns != null) {
        delete g_hBluSpawns;
    }
}