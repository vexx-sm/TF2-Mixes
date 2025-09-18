#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <clientprefs>
#include <sdktools>
#include <sdkhooks>
#include <float>

#pragma semicolon 1
#pragma newdecls required

// Plugin information
public Plugin myinfo = {
    name = "TF2-Mixes",
    author = "vexx-sm",
    description = "A TF2 SourceMod plugin that sets up a 6s mix",
    version = "0.1.1",
    url = "https://github.com/vexx-sm/TF2-Mixes"
};

// Global variables
int g_iCaptain1 = -1;
int g_iCaptain2 = -1;
bool g_bMixInProgress = false;
int g_iCurrentPicker = 0;
Handle g_hPickTimer = INVALID_HANDLE;
Handle g_hHudTimer = INVALID_HANDLE;
float g_fLastCommandTime[MAXPLAYERS + 1];
char g_sOriginalNames[MAXPLAYERS + 1][MAX_NAME_LENGTH];
bool g_bPlayerLocked[MAXPLAYERS + 1];
Handle g_hGraceTimer = INVALID_HANDLE;
int g_iMissingCaptain = -1;
int g_iPicksRemaining = 0;
Handle g_hVoteTimer = INVALID_HANDLE;
int g_iVoteCount[3] = {0, 0, 0};
bool g_bPlayerVoted[MAXPLAYERS + 1];
float g_fLastVoteTime = 0.0;
bool g_bVoteInProgress = false;
float g_fPickTimerStartTime = 0.0;
int g_iOriginalTeam[MAXPLAYERS + 1] = {0};
bool g_bPlayerPicked[MAXPLAYERS + 1];

// ConVars
ConVar g_cvPickTimeout;
ConVar g_cvCommandCooldown;
ConVar g_cvGracePeriod;
ConVar g_cvVoteDuration;

// Forward declarations
public Action Command_SetCaptain(int client, int args);
public Action Command_AdminPick(int client, int args);
public Action Command_Mix(int client, int args);
public Action Timer_PickTimeout(Handle timer);
public void PickPlayer(int captain, int target);
public void EndMix(bool startNewDraft);

// Helper functions
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
    // Load translations
    LoadTranslations("common.phrases");
    LoadTranslations("mixes.phrases");
    
    // Register commands
    RegConsoleCmd("sm_captain", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_cap", Command_Captain, "Become a captain");
    RegConsoleCmd("sm_mix", Command_Mix, "Start a new mix");
    RegConsoleCmd("sm_draft", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_pick", Command_Draft, "Draft a player or show draft menu");
    RegConsoleCmd("sm_votemix", Command_VoteMix, "Vote to restart the current mix");
    RegConsoleCmd("sm_cancel", Command_VoteMix, "Vote to restart the current mix");
    RegConsoleCmd("sm_cancelmix", Command_CancelMix, "Cancel current mix");
    
    // Admin commands
    RegAdminCmd("sm_setcaptain", Command_SetCaptain, ADMFLAG_GENERIC, "Set a player as captain");
    RegAdminCmd("sm_adminpick", Command_AdminPick, ADMFLAG_GENERIC, "Force pick a player");
    RegAdminCmd("sm_autodraft", Command_AutoDraft, ADMFLAG_GENERIC, "Automatically draft teams");
    
    // Create CVars
    g_cvPickTimeout = CreateConVar("sm_mix_pick_timeout", "30.0", "Time limit for picks in seconds");
    g_cvCommandCooldown = CreateConVar("sm_mix_command_cooldown", "5.0", "Cooldown time for commands in seconds");
    g_cvGracePeriod = CreateConVar("sm_mix_grace_period", "60.0", "Time to wait for disconnected captain");
    g_cvVoteDuration = CreateConVar("sm_mix_vote_duration", "30.0", "Duration of the mix vote in seconds");
    
    // Hook events
    HookEvent("teamplay_round_start", Event_RoundStart);
    HookEvent("teamplay_round_win", Event_RoundEnd);
    HookEvent("player_team", Event_PlayerTeam);
    
    // Create HUD timer
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    // Print signature
    PrintToServer("================================================================");
    PrintToServer("  TF2-Mixes v0.1.1 | 6s Competitive Mix System");
    PrintToServer("  Author: vexx-sm | Type !help for commands");
    PrintToServer("================================================================");
}

public void OnMapStart() {
    // Reset all state variables
    g_iCaptain1 = -1;
    g_iCaptain2 = -1;
    g_bMixInProgress = false;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_iPicksRemaining = 0;
    g_bVoteInProgress = false;
    g_fLastVoteTime = 0.0;
    g_fPickTimerStartTime = 0.0;
    
    // Reset player locks and votes
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerLocked[i] = false;
        g_bPlayerVoted[i] = false;
    }
    
    // Kill all timers safely
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hHudTimer);
    KillTimerSafely(g_hGraceTimer);
    KillTimerSafely(g_hVoteTimer);
    
    // Ensure game state is not locked at map start
    ServerCommand("mp_tournament 0");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
}

public void OnClientPutInServer(int client) {
    if (IsValidClient(client)) {
        GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        g_bPlayerLocked[client] = false;
    }
}

public void OnClientDisconnect(int client) {
    if (!IsValidClient(client))
        return;
        
    // Restore original name if they were a captain
    if (client == g_iCaptain1 || client == g_iCaptain2) {
        SetClientName(client, g_sOriginalNames[client]);
    }
    
    // Handle captain disconnects
    if (client == g_iCaptain1) {
        g_iCaptain1 = -1;
        if (g_bMixInProgress) {
            // Don't start grace period for bots during draft
            if (!IsFakeClient(client) || g_iPicksRemaining <= 0) {
                StartGracePeriod(0); // 0 for Captain1
            }
        } else {
            PrintToChatAll("\x01[Mix] \x03First captain has left the game!");
        }
    } else if (client == g_iCaptain2) {
        g_iCaptain2 = -1;
        if (g_bMixInProgress) {
            // Don't start grace period for bots during draft
            if (!IsFakeClient(client) || g_iPicksRemaining <= 0) {
                StartGracePeriod(1); // 1 for Captain2
            }
        } else {
            PrintToChatAll("\x01[Mix] \x03Second captain has left the game!");
        }
    }
    
    g_bPlayerLocked[client] = false;
}

public Action Command_Captain(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    // Only allow captain commands in pre-draft phase
    if (g_bMixInProgress) {
        ReplyToCommand(client, "\x01[Mix] \x03Captain selection is only available before the draft starts!");
        return Plugin_Handled;
    }
        
    // Check cooldown
    float currentTime = GetGameTime();
    float timeSinceLastCommand = currentTime - g_fLastCommandTime[client];
    float cooldownTime = g_cvCommandCooldown.FloatValue;
    
    if (timeSinceLastCommand < cooldownTime) {
        ReplyToCommand(client, "\x01[Mix] \x03Please wait %.1f seconds before using this command again.", cooldownTime - timeSinceLastCommand);
        return Plugin_Handled;
    }
    
    g_fLastCommandTime[client] = currentTime;
        
    // Check if player is already a captain
    if (client == g_iCaptain1 || client == g_iCaptain2) {
        // Remove captain status
        if (client == g_iCaptain1) {
            g_iCaptain1 = -1;
            SetClientName(client, g_sOriginalNames[client]);
            PrintToChat(client, "\x01[Mix] \x03You are no longer the first captain."); // Personal confirmation
            if (g_bMixInProgress) {
                // Kill pick timer first to prevent any race conditions
                KillTimerSafely(g_hPickTimer);
                // Start grace period for first captain
                StartGracePeriod(0);
                // Force immediate HUD update
                Timer_UpdateHUD(g_hHudTimer);
            } else {
                PrintToChatAll("\x01[Mix] \x03%N\x01 is no longer a captain!", client); // Server announcement if not in draft
            }
        } else { // client == g_iCaptain2
            g_iCaptain2 = -1;
            SetClientName(client, g_sOriginalNames[client]);
            PrintToChat(client, "\x01[Mix] \x03You are no longer the second captain."); // Personal confirmation
            if (g_bMixInProgress) {
                // Kill pick timer first to prevent any race conditions
                KillTimerSafely(g_hPickTimer);
                // Start grace period for second captain
                StartGracePeriod(1);
                // Force immediate HUD update
                Timer_UpdateHUD(g_hHudTimer);
            } else {
                PrintToChatAll("\x01[Mix] \x03%N\x01 is no longer a captain!", client); // Server announcement if not in draft
            }
        }
        return Plugin_Handled;
    }
    
    // If we're in grace period, check if this player can replace the missing captain
    if (g_bMixInProgress && g_iMissingCaptain != -1) {
        if (g_iMissingCaptain == 0) {
            g_iCaptain1 = client;
            // Store original name if not already stored
            if (strlen(g_sOriginalNames[client]) == 0) {
                GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
            }
            char newName[MAX_NAME_LENGTH];
            Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
            SetClientName(client, newName);
            PrintToChatAll("\x01[Mix] \x03%N\x01 has become the replacement first captain!", client); // Server announcement
            
            // End grace period
            KillTimerSafely(g_hGraceTimer);
            g_iMissingCaptain = -1;
            
            // Resume draft
            ResumeDraft();
            // Force immediate HUD update
            Timer_UpdateHUD(g_hHudTimer);
            return Plugin_Handled;
        } else { // g_iMissingCaptain == 1
            g_iCaptain2 = client;
            // Store original name if not already stored
            if (strlen(g_sOriginalNames[client]) == 0) {
                GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
            }
            char newName[MAX_NAME_LENGTH];
            Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
            SetClientName(client, newName);
            PrintToChatAll("\x01[Mix] \x03%N\x01 has become the replacement second captain!", client); // Server announcement
            
            // End grace period
            KillTimerSafely(g_hGraceTimer);
            g_iMissingCaptain = -1;
            
            // Resume draft
            ResumeDraft();
            // Force immediate HUD update
            Timer_UpdateHUD(g_hHudTimer);
            return Plugin_Handled;
        }
    }
    
    // Normal captain assignment logic
    if (g_iCaptain1 == -1) {
        g_iCaptain1 = client;
        // Store original name if not already stored
        if (strlen(g_sOriginalNames[client]) == 0) {
            GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
        SetClientName(client, newName);
        PrintToChatAll("\x01[Mix] \x03%N\x01 is now the first team captain!", client); // Server announcement
    } else if (g_iCaptain2 == -1) {
        g_iCaptain2 = client;
        // Store original name if not already stored
        if (strlen(g_sOriginalNames[client]) == 0) {
            GetClientName(client, g_sOriginalNames[client], sizeof(g_sOriginalNames[]));
        }
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
        SetClientName(client, newName);
        PrintToChatAll("\x01[Mix] \x03%N\x01 is now the second team captain!", client); // Server announcement
    } else {
        ReplyToCommand(client, "\x01[Mix] \x03There are already two captains!");
        return Plugin_Handled;
    }
    
    // Check if we can start drafting
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
    g_fLastVoteTime = 0.0;
    g_iPicksRemaining = 10;
    
    // Set game state for draft
    ServerCommand("mp_tournament 1");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("mp_forceautoteam 0");
    ServerCommand("tf_bot_quota_mode none");
    ServerCommand("tf_bot_quota 0");
    
    // Move captains to teams
    int team1 = GetRandomInt(TFTeam_Red, TFTeam_Blue);
    int team2 = (view_as<TFTeam>(team1) == TFTeam_Red) ? TFTeam_Blue : TFTeam_Red;
    
    MovePlayerToTeam(g_iCaptain1, view_as<TFTeam>(team1));
    MovePlayerToTeam(g_iCaptain2, view_as<TFTeam>(team2));
    
    // Move all other players to spectator
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && i != g_iCaptain1 && i != g_iCaptain2) {
            MovePlayerToTeam(i, TFTeam_Spectator);
        }
    }
    
    // Start timers
    g_fPickTimerStartTime = GetGameTime();
    g_hPickTimer = CreateTimer(1.0, Timer_PickTime, _, TIMER_REPEAT);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03Draft has started! First captain's turn to pick.");
}

public Action Command_Mix(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;
        
    // Check if a mix is already in progress
    if (g_bMixInProgress) {
        ReplyToCommand(client, "\x01[Mix] \x03A mix is already in progress!");
        return Plugin_Handled;
    }
    
    // Check if we have enough players
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i))
            totalPlayers++;
    }
    
    if (totalPlayers < 12) {
        ReplyToCommand(client, "\x01[Mix] \x03Need at least 12 players to start a mix. Current players: %d", totalPlayers);
        return Plugin_Handled;
    }
    
    // Start the mix
    StartMix();
    return Plugin_Handled;
}

public Action Command_Draft(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;

    // Only allow draft commands during active draft phase (when picks are remaining)
    if (!g_bMixInProgress || g_iPicksRemaining <= 0) {
        ReplyToCommand(client, "\x01[Mix] \x03Draft commands are only available during the active draft phase!");
        return Plugin_Handled;
    }
    
    // Check if it's this captain's turn
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
    
    // Rest of the drafting logic
    if (args > 0) {
        char target[32];
        GetCmdArg(1, target, sizeof(target));
        
        // Custom target finding logic
        int targetClient = -1;
        char targetName[MAX_NAME_LENGTH];
        
        // First try exact match
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
                GetClientName(i, targetName, sizeof(targetName));
                if (StrEqual(targetName, target, false)) {
                    targetClient = i;
                    break;
                }
            }
        }
        
        // If no exact match, try partial match
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

void ShowDraftMenu(int client) {
    if (!IsValidClient(client) || !IsClientInGame(client))
        return;
        
    Menu menu = new Menu(DraftMenuHandler, MENU_ACTIONS_ALL);
    menu.SetTitle("Select a player to draft:");
    
    // Add Random Pick option
    menu.AddItem("random", "Pick Random Player");
    
    // Create array of spectators
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
    
    // Sort spectators alphabetically
    spectators.SortCustom(SortSpectators);
    
    // Add sorted spectators to menu
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
            char info[32]; // Increased buffer size
            menu.GetItem(param2, info, sizeof(info));
            
            // Handle Random Pick selection
            if (StrEqual(info, "random")) {
                 // Find a random valid spectator
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
                    ShowDraftMenu(param1); // Re-show menu
                }
                return 0; // Handled
            }
            
            // Handle regular player selection
            int target = GetClientOfUserId(StringToInt(info));
            
            if (IsValidClient(target) && view_as<TFTeam>(GetClientTeam(target)) == TFTeam_Spectator) {
                PickPlayer(param1, target);
            } else {
                ReplyToCommand(param1, "\x01[Mix] \x03That player is no longer available or not in spectator!");
                ShowDraftMenu(param1); // Re-show menu if player is invalid
            }
        }
        case MenuAction_Cancel: {
            if (param2 == MenuCancel_Exit) {
                // Player closed the menu. Allow it.
                // The menu will automatically close when this handler returns.
                // PrintToServer("DEBUG: Client %N cancelled draft menu via Exit button.", param1); // Keep for debugging if needed
            }
            // No action needed for other cancel types or after handling Exit
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
    TF2_ChangeClientTeam(target, view_as<TFTeam>(team));
    g_bPlayerLocked[target] = true;
    g_bPlayerPicked[target] = true;
    
    // Decrease remaining picks
    g_iPicksRemaining--;
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03%N has been drafted to the %s team!", target, (view_as<TFTeam>(team) == TFTeam_Red) ? "RED" : "BLU");
    
    // Check if draft is complete
    if (g_iPicksRemaining <= 0) {
        EndDraft();
        return;
    }
    
    // Switch to next picker
    g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
    int nextCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    
    // Notify next picker
    PrintToChatAll("\x01[Mix] \x03%N's turn to pick! (%d picks remaining)", nextCaptain, g_iPicksRemaining);
    
    // Reset pick timeout timer
    KillTimerSafely(g_hPickTimer);
    g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
    g_fPickTimerStartTime = GetGameTime();
    
    // Manually update HUD after a pick
    UpdateHUDForAll();
}

public void EndDraft() {
    g_bMixInProgress = true;
    
    // Kill timers
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hHudTimer);
    KillTimerSafely(g_hVoteTimer);
    
    // Lock all players
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            g_bPlayerLocked[i] = true;
        }
    }
    
    // Ensure tournament mode is on
    ServerCommand("mp_tournament 1");
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03Draft complete! Mix has started.");
    
    // Show final team composition
    ShowTeamComposition();
    
    // Start the round
    ServerCommand("mp_restartgame 1");
}

void ShowTeamComposition() {
    char redTeam[MAX_NAME_LENGTH * 12] = "RED Team: ";
    char bluTeam[MAX_NAME_LENGTH * 12] = "BLU Team: ";
    char temp[MAX_NAME_LENGTH];
    
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            int team = view_as<TFTeam>(GetClientTeam(i));
            if (view_as<TFTeam>(team) == TFTeam_Red) { // RED
                GetClientName(i, temp, sizeof(temp));
                StrCat(redTeam, sizeof(redTeam), temp);
                StrCat(redTeam, sizeof(redTeam), ", ");
            }
            else if (view_as<TFTeam>(team) == TFTeam_Blue) { // BLU
                GetClientName(i, temp, sizeof(temp));
                StrCat(bluTeam, sizeof(bluTeam), temp);
                StrCat(bluTeam, sizeof(bluTeam), ", ");
            }
        }
    }
    
    // Remove trailing commas
    redTeam[strlen(redTeam) - 2] = '\0';
    bluTeam[strlen(bluTeam) - 2] = '\0';
    
    // Show team composition in chat
    PrintToChatAll("\x01[Mix] \x07FF0000%s", redTeam);
    PrintToChatAll("\x01[Mix] \x070000FF%s", bluTeam);
    
    // Also show in HUD
    SetHudTextParams(-1.0, 0.3, 10.0, 255, 0, 0, 255, 0, 0.0, 0.0, 0.0);
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            ShowHudText(i, -1, "%s", redTeam);
        }
    }
    
    SetHudTextParams(-1.0, 0.4, 10.0, 0, 0, 255, 255, 0, 0.0, 0.0, 0.0);
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            ShowHudText(i, -1, "%s", bluTeam);
        }
    }
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    int newTeam = event.GetInt("team");
    bool disconnect = event.GetBool("disconnect");
    
    if (!IsValidClient(client) || disconnect)
        return Plugin_Continue;
    
    // Skip team change restrictions for bots during draft phase to prevent disconnections
    if (IsFakeClient(client) && g_bMixInProgress && g_iPicksRemaining > 0) {
        return Plugin_Continue;
    }
        
    // If player is locked to a team AND we are in a mix, prevent team change
    if (g_bMixInProgress && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) != TFTeam_Spectator) { // Don't force back if they somehow got to spectator
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
            return Plugin_Handled;
        }
    }
    
    // During draft phase (when picks are remaining), prevent non-captains from switching teams
    if (g_bMixInProgress && g_iPicksRemaining > 0 && client != g_iCaptain1 && client != g_iCaptain2) {
        // If they are moving to a team that isn't spectator, move them back to spectator
        if (view_as<TFTeam>(newTeam) != TFTeam_Spectator) {
            TF2_ChangeClientTeam(client, view_as<TFTeam>(TFTeam_Spectator));
            return Plugin_Handled;
        }
    }
    
    // During mix phase (after draft complete), prevent all team changes
    if (g_bMixInProgress && g_iPicksRemaining <= 0) {
        // Allow only spectator movement during mix
        if (view_as<TFTeam>(newTeam) != TFTeam_Spectator) {
            TF2_ChangeClientTeam(client, view_as<TFTeam>(TFTeam_Spectator));
            return Plugin_Handled;
        }
    }
    
    return Plugin_Continue;
}

public Action Timer_ForceTeam(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    // Only run if client is valid AND we are in a mix AND client is locked
    // Skip for bots during draft phase to prevent disconnections
    if (IsValidClient(client) && g_bMixInProgress && g_bPlayerLocked[client] && 
        !(IsFakeClient(client) && g_iPicksRemaining > 0)) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) { // If they're in spectator, force them back to their team
            // Find their original team
            int originalTeam = -1;
            if (client == g_iCaptain1) {
                originalTeam = view_as<TFTeam>(GetClientTeam(g_iCaptain1));
            } else if (client == g_iCaptain2) {
                originalTeam = view_as<TFTeam>(GetClientTeam(g_iCaptain2));
            } else {
                // For other players, find their team based on captain assignments - simplified logic, assumes they were drafted
                 // We need to find the team they were drafted onto. This is tricky without storing it.
                 // A better approach might be to iterate through all players and find which team has this player after draft.
                 // For now, let's try to find which captain's team they are on.
                 if (IsValidClient(g_iCaptain1) && view_as<TFTeam>(GetClientTeam(g_iCaptain1)) == view_as<TFTeam>(currentTeam)) {
                      originalTeam = view_as<TFTeam>(GetClientTeam(g_iCaptain1));
                 } else if (IsValidClient(g_iCaptain2) && view_as<TFTeam>(GetClientTeam(g_iCaptain2)) == view_as<TFTeam>(currentTeam)) {
                      originalTeam = view_as<TFTeam>(GetClientTeam(g_iCaptain2));
                 } else { // Fallback: try finding which team they were drafted to by iterating players
                     for (int i = 1; i <= MaxClients; i++) {
                         if (IsValidClient(i) && i != g_iCaptain1 && i != g_iCaptain2 && g_bPlayerLocked[i] && view_as<TFTeam>(GetClientTeam(i)) != TFTeam_Spectator) {
                             // Check if this player's team matches any drafted player's team (imperfect, but a guess)
                              if (view_as<TFTeam>(GetClientTeam(i)) != TFTeam_Spectator) {
                                  originalTeam = view_as<TFTeam>(GetClientTeam(i));
                                  break;
                              }
                         }
                     }
                 }
            }
            
            if (originalTeam != -1 && view_as<TFTeam>(originalTeam) != TFTeam_Spectator) {
                TF2_ChangeClientTeam(client, view_as<TFTeam>(originalTeam));
                PrintToChat(client, "\x01[Mix] \x03You are locked to your team!");
            } else { // If we can't find their team, unlock them to prevent further issues
                 g_bPlayerLocked[client] = false;
                 PrintToChat(client, "\x01[Mix] \x03Could not determine your team, unlocking.");
            }
        }
    }
    // Stop the timer if not in a mix or client is invalid/unlocked
    return Plugin_Stop;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    // Ensure captain suffix is maintained (always, regardless of mix)
    if ((client == g_iCaptain1 || client == g_iCaptain2) && !StrContains(g_sOriginalNames[client], "[CAP]")) {
        char newName[MAX_NAME_LENGTH];
        Format(newName, sizeof(newName), "%s [CAP]", g_sOriginalNames[client]);
        SetClientName(client, newName); // Changed to SetClientName
    }
    
    // If in mix AND player is locked, ensure player is on correct team
    if (g_bMixInProgress && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) {
             // Force them back to team using the timer
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        }
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerChangeClass(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    // If in mix AND player is locked, ensure player stays on their team
    if (g_bMixInProgress && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        }
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    // If in mix AND player is locked, ensure player stays on their team
    if (g_bMixInProgress && g_bPlayerLocked[client]) {
        int currentTeam = view_as<TFTeam>(GetClientTeam(client));
        if (view_as<TFTeam>(currentTeam) == TFTeam_Spectator) {
            CreateTimer(0.1, Timer_ForceTeam, GetClientUserId(client));
        }
    }
    
    return Plugin_Continue;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // Only reset draft state if not in progress
    if (!g_bMixInProgress) {
        g_iCaptain1 = -1;
        g_iCaptain2 = -1;
        g_iCurrentPicker = 0;
    }
    
    // Kill timers safely
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hHudTimer);
    KillTimerSafely(g_hGraceTimer);
    KillTimerSafely(g_hVoteTimer);
    
    // Reset player locks if not in draft
    if (!g_bMixInProgress) {
        for (int i = 1; i <= MaxClients; i++) {
            g_bPlayerLocked[i] = false;
        }
    }
    
    return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (!g_bMixInProgress)
        return Plugin_Continue;
        
    // Start vote after a short delay
    CreateTimer(3.0, Timer_StartVote);
    
    return Plugin_Continue;
}

public Action Timer_StartVote(Handle timer) {
    if (!g_bMixInProgress)
        return Plugin_Stop;
        
    // Reset vote counts
    g_iVoteCount[0] = 0;
    g_iVoteCount[1] = 0;
    g_iVoteCount[2] = 0;
    
    // Reset player votes
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerVoted[i] = false;
    }
    
    // Show vote menu to all players
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            ShowVoteMenu(i);
        }
    }
    
    // Start vote timer
    if (g_hVoteTimer != INVALID_HANDLE) {
        KillTimer(g_hVoteTimer);
    }
    g_hVoteTimer = CreateTimer(g_cvVoteDuration.FloatValue, Timer_EndVote);
    
    // Show vote started message
    PrintToChatAll("\x01[Mix] \x03Vote started! You have %.0f seconds to vote.", g_cvVoteDuration.FloatValue);
    
    return Plugin_Stop;
}

void ShowVoteMenu(int client) {
    if (!IsValidClient(client))
        return;
        
    Menu menu = new Menu(VoteMenuHandler, MENU_ACTIONS_ALL);
    menu.SetTitle("Mix Vote - What would you like to do?");
    
    menu.AddItem("continue", "Continue with same teams");
    menu.AddItem("newdraft", "Start new draft");
    menu.AddItem("endmix", "End mix");
    
    menu.ExitButton = false;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int VoteMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
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
                PrintToChatAll("\x01[Mix] \x03%N\x01 voted to continue with same teams", param1);
            } else if (StrEqual(info, "newdraft")) {
                g_iVoteCount[1]++;
                PrintToChatAll("\x01[Mix] \x03%N\x01 voted to start a new draft", param1);
            } else if (StrEqual(info, "endmix")) {
                g_iVoteCount[2]++;
                PrintToChatAll("\x01[Mix] \x03%N\x01 voted to end the mix", param1);
            }
        }
        case MenuAction_Cancel: {
            if (param2 == MenuCancel_Exit) {
                // Player closed the menu without voting
                if (IsValidClient(param1)) {
                    PrintToChat(param1, "\x01[Mix] \x03You must vote to continue the mix!");
                    ShowVoteMenu(param1);
                }
            }
        }
    }
    return 0;
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
                // Player closed the menu without voting
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
    
    // Count total votes
    int totalVotes = g_iVoteCount[0] + g_iVoteCount[1];
    if (totalVotes == 0) {
        PrintToChatAll("\x01[Mix] \x03No votes cast. Continuing with current draft.");
        return Plugin_Stop;
    }
    
    // Check for majority (simple majority, not 2/3)
    if (g_iVoteCount[1] > g_iVoteCount[0]) {
        PrintToChatAll("\x01[Mix] \x03Vote passed: Restarting draft from beginning.");
        EndMix(true); // true = start new draft
    } else {
        PrintToChatAll("\x01[Mix] \x03Vote failed: Continuing with current draft.");
    }
    
    return Plugin_Stop;
}

public Action Timer_EndVote(Handle timer) {
    g_hVoteTimer = INVALID_HANDLE;
    
    // Count total votes
    int totalVotes = g_iVoteCount[0] + g_iVoteCount[1] + g_iVoteCount[2];
    if (totalVotes == 0) {
        PrintToChatAll("\x01[Mix] \x03No votes cast. Continuing with same teams.");
        return Plugin_Stop;
    }
    
    // Check for 2/3 majority
    float threshold = float(totalVotes) * (2.0/3.0);
    
    if (float(g_iVoteCount[0]) >= threshold) {
        PrintToChatAll("\x01[Mix] \x03Vote passed: Continuing with same teams.");
    } else if (float(g_iVoteCount[1]) >= threshold) {
        PrintToChatAll("\x01[Mix] \x03Vote passed: Starting new draft.");
        EndMix(true); // true = start new draft
    } else if (float(g_iVoteCount[2]) >= threshold) {
        PrintToChatAll("\x01[Mix] \x03Vote passed: Ending mix.");
        EndMix(false); // false = don't start new draft
    } else {
        PrintToChatAll("\x01[Mix] \x03No option reached 2/3 majority. Continuing with same teams.");
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
    // Reset all timers
    ResetAllTimers();
    
    // Reset all states
    g_bMixInProgress = false;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_bVoteInProgress = false;
    g_fLastVoteTime = 0.0;
    
    // Reset captain names
    if (g_iCaptain1 != -1) {
        SetClientName(g_iCaptain1, g_sOriginalNames[g_iCaptain1]);
        g_iCaptain1 = -1;
    }
    if (g_iCaptain2 != -1) {
        SetClientName(g_iCaptain2, g_sOriginalNames[g_iCaptain2]);
        g_iCaptain2 = -1;
    }
    
    // Clear all arrays
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerPicked[i] = false;
        g_sOriginalNames[i][0] = '\0';
        g_iOriginalTeam[i] = 0;
    }
    
    // Set normal game state
    ServerCommand("mp_tournament 0");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    
    // Reset all player teams
    ResetAllPlayerTeams();
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03Mix has ended. Teams are now unlocked.");
}

// HUD and timer display functions
void UpdateHUDForAll() {
    char buffer[256];
    
    // Build HUD message based on current state
    if (g_bMixInProgress) {
        // Check if we're in grace period
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
        // Check if we're in active draft (picks remaining)
        else if (g_iPicksRemaining > 0) {
            int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
            char captainName[MAX_NAME_LENGTH];
            
            if (IsValidClient(currentCaptain)) {
                GetClientName(currentCaptain, captainName, sizeof(captainName));
            } else {
                strcopy(captainName, sizeof(captainName), "Unknown Captain");
            }
            
            // Calculate time remaining
            float timeLeft = g_cvPickTimeout.FloatValue - (GetGameTime() - g_fPickTimerStartTime);
            if (timeLeft < 0.0) timeLeft = 0.0;
            
            // Calculate picks per team
            int picksPerTeam = (g_iPicksRemaining + 1) / 2; // +1 to account for current pick
            int team1Picks = (g_iCurrentPicker == 0) ? picksPerTeam : picksPerTeam - 1;
            int team2Picks = (g_iCurrentPicker == 1) ? picksPerTeam : picksPerTeam - 1;
            
            Format(buffer, sizeof(buffer), "DRAFT IN PROGRESS\n%s's turn to pick\nTime: %.0fs\nRED: %d picks | BLU: %d picks", 
                   captainName, timeLeft, team1Picks, team2Picks);
        }
        // Draft is complete, mix is active
        else {
            Format(buffer, sizeof(buffer), "MIX IN PROGRESS\nTeams are locked");
        }
    } else {
        Format(buffer, sizeof(buffer), "Type !captain to become a captain");
    }
    
    // Display HUD message to all players using HL2-style hint text
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

public Action Timer_PickTime(Handle timer) {
    if (!g_bMixInProgress || g_iMissingCaptain != -1) {
        return Plugin_Continue;
    }
    
    float currentTime = GetGameTime();
    float timeLeft = g_cvPickTimeout.FloatValue - (currentTime - g_fPickTimerStartTime);
    
    if (timeLeft <= 0.0) {
        // Time's up, auto-pick next available player
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        int nextPlayer = FindNextAvailablePlayer();
        
        if (nextPlayer != -1) {
            // Auto-pick the player
            PickPlayer(currentCaptain, nextPlayer);
        } else {
            // No players left to pick
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
        // Grace period expired, cancel the mix
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

// Update the existing functions to use the new HUD system
void StartGracePeriod(int missingCaptain) {
    if (g_iMissingCaptain != -1 || !g_bMixInProgress) {
        if (g_iMissingCaptain == missingCaptain) return;
        if (!g_bMixInProgress) return;
    }
    
    g_iMissingCaptain = missingCaptain;
    
    // Kill existing timers
    KillTimerSafely(g_hPickTimer);
    KillTimerSafely(g_hGraceTimer);
    
    // Start grace period timer
    g_fPickTimerStartTime = GetGameTime();
    g_hGraceTimer = CreateTimer(1.0, Timer_GracePeriod, _, TIMER_REPEAT);
    
    // Restart HUD timer
    KillTimerSafely(g_hHudTimer);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    // Force immediate HUD update
    UpdateHUDForAll();
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03A captain has left! You have %.0f seconds to type !captain to replace them.", g_cvGracePeriod.FloatValue);
}

void ResumeDraft() {
    if (!g_bMixInProgress || g_iMissingCaptain == -1) return;
    
    // Kill grace timer
    KillTimerSafely(g_hGraceTimer);
    
    // Reset missing captain
    g_iMissingCaptain = -1;
    
    // Restart pick timer
    g_fPickTimerStartTime = GetGameTime();
    g_hPickTimer = CreateTimer(1.0, Timer_PickTime, _, TIMER_REPEAT);
    
    // Restart HUD timer
    KillTimerSafely(g_hHudTimer);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    // Force immediate HUD update
    UpdateHUDForAll();
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03Draft has resumed! Current captain's turn to pick.");
}

// Add new function to handle chat messages
public Action OnSayText2(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init) {
    char message[256];
    msg.ReadString(message, sizeof(message));
    
    // Block any message containing "changed name to"
    if (StrContains(message, "changed name to") != -1) {
        return Plugin_Handled;
    }
    
    return Plugin_Continue;
}

public Action Command_VoteMix(int client, int args) {
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
    
    float currentTime = GetGameTime();
    if (currentTime - g_fLastVoteTime < 120.0) { // 2 minute cooldown
        ReplyToCommand(client, "\x01[Mix] \x03Please wait %.1f seconds before starting another vote.", 120.0 - (currentTime - g_fLastVoteTime));
        return Plugin_Handled;
    }
    
    // Start the vote
    g_bVoteInProgress = true;
    g_iVoteCount[0] = 0; // Continue
    g_iVoteCount[1] = 0; // New Draft
    g_iVoteCount[2] = 0; // End Mix
    g_fLastVoteTime = currentTime;
    
    // Reset all player votes
    for (int i = 1; i <= MaxClients; i++) {
        g_bPlayerVoted[i] = false;
    }
    
    // Show restart vote menu to all players
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            ShowRestartVoteMenu(i);
        }
    }
    
    // Start vote timer
    if (g_hVoteTimer != INVALID_HANDLE) {
        KillTimer(g_hVoteTimer);
    }
    g_hVoteTimer = CreateTimer(30.0, Timer_EndRestartVote); // 30 second vote duration
    
    // Show vote started message
    PrintToChatAll("\x01[Mix] \x03%N has started a vote to restart the draft!", client);
    PrintToChatAll("\x01[Mix] \x03You have 30 seconds to vote.");
    
    return Plugin_Handled;
}

void CancelMix(int admin) {
    // Reset all states first
    g_bMixInProgress = false;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_iPicksRemaining = 0;
    g_bVoteInProgress = false;
    g_fLastVoteTime = 0.0;
    g_fPickTimerStartTime = 0.0;
    
    // Kill any active timers
    KillAllTimers();
    
    // Reset captain status and names
    if (g_iCaptain1 != -1 && IsValidClient(g_iCaptain1)) {
        SetClientName(g_iCaptain1, g_sOriginalNames[g_iCaptain1]);
        g_iCaptain1 = -1;
    }
    if (g_iCaptain2 != -1 && IsValidClient(g_iCaptain2)) {
        SetClientName(g_iCaptain2, g_sOriginalNames[g_iCaptain2]);
        g_iCaptain2 = -1;
    }
    
    // Keep players in their current teams but unlock them
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            // Only reset states, don't change teams
            g_bPlayerLocked[i] = false;
            g_bPlayerPicked[i] = false;
            g_iOriginalTeam[i] = 0;
        }
    }
    
    // Aggressively reset server state
    ServerCommand("mp_tournament 0");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 1");
    ServerCommand("mp_forceautoteam 0");
    ServerCommand("tf_bot_quota_mode normal");
    ServerCommand("tf_bot_quota 0");
    
    // Force a round restart to ensure all changes take effect
    ServerCommand("mp_restartgame 1");
    
    // Notify players
    if (admin == -1) {
        PrintToChatAll("\x01[Mix] \x03Mix has been cancelled by vote! Teams are now unlocked.");
    } else {
        PrintToChatAll("\x01[Mix] \x03Mix has been cancelled by admin %N! Teams are now unlocked.", admin);
    }
    
    // Create a delayed timer to verify team unlocks
    CreateTimer(1.0, Timer_VerifyTeamUnlock);
}

// Update verify timer to be less aggressive
public Action Timer_VerifyTeamUnlock(Handle timer) {
    // Double check that tournament mode is off
    if (GetConVarBool(FindConVar("mp_tournament"))) {
        ServerCommand("mp_tournament 0");
    }
    
    // Verify all players are unlocked but don't change their teams
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            g_bPlayerLocked[i] = false;
            g_bPlayerPicked[i] = false;
        }
    }
    
    return Plugin_Stop;
}

// Add admin command to auto-draft
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
    
    // Ensure we have captains
    if (!IsValidClient(g_iCaptain1) || !IsValidClient(g_iCaptain2)) {
         ReplyToCommand(client, "\x01[Mix] \x03Cannot auto-draft, captains are not set or invalid!");
         return Plugin_Handled;
    }
    
    // Determine how many players are needed
    int picksToMake = g_iPicksRemaining;
    if (picksToMake <= 0) {
         ReplyToCommand(client, "\x01[Mix] \x03Draft is already complete!");
         return Plugin_Handled;
    }
    
    // Create array of spectators (including bots)
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
    
    // Auto-draft players to fill 6v6 teams (10 total picks needed)
    int draftedCount = 0;
    int totalPicksNeeded = 10; // 5 players per team for 6v6
    
    while (g_iPicksRemaining > 0 && spectators.Length > 0 && draftedCount < totalPicksNeeded) {
        int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
        
        // Get a random target from remaining spectators
        int randomIndex = GetRandomInt(0, spectators.Length - 1);
        int targetClient = spectators.Get(randomIndex);
        
        // Remove from spectators list to avoid picking again
        spectators.Erase(randomIndex);
        
        // Perform the draft
        PickPlayer(currentCaptain, targetClient); // This function handles switching picker and checking completion
        draftedCount++;
    }
    
    delete spectators;
    
    ReplyToCommand(client, "\x01[Mix] \x03Auto-drafted %d players.", draftedCount);
    
    return Plugin_Handled;
}

// Timer management functions
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
    
    // Store original team if not already stored
    if (g_iOriginalTeam[client] == 0) {
        g_iOriginalTeam[client] = GetClientTeam(client);
    }
    
    // Change team
    TF2_ChangeClientTeam(client, team);
}

void ResetPlayerTeam(int client) {
    if (!IsValidClient(client)) return;
    
    // Move back to original team if possible
    if (g_iOriginalTeam[client] > 0) {
        TF2_ChangeClientTeam(client, view_as<TFTeam>(g_iOriginalTeam[client]));
    } else {
        // If no original team stored, move to spectator
        TF2_ChangeClientTeam(client, TFTeam_Spectator);
    }
    
    // Reset original team
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
    
    // Custom target finding logic
    int targetClient = -1;
    char targetName[MAX_NAME_LENGTH];
    
    // First try exact match
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i)) {
            GetClientName(i, targetName, sizeof(targetName));
            if (StrEqual(targetName, target, false)) {
                targetClient = i;
                break;
            }
        }
    }
    
    // If no exact match, try partial match
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
    
    // Check if target is already a captain
    if (targetClient == g_iCaptain1 || targetClient == g_iCaptain2) {
        // Remove captain status
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
    
    // Check if we already have two captains
    if (g_iCaptain1 != -1 && g_iCaptain2 != -1) {
        ReplyToCommand(client, "\x01[Mix] \x03There are already two captains!");
        return Plugin_Handled;
    }
    
    // Assign as captain
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
    
    // Check if we can start drafting.
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
    
    // Custom target finding logic
    int targetClient = -1;
    char targetName[MAX_NAME_LENGTH];
    
    // First try exact match
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && view_as<TFTeam>(GetClientTeam(i)) == TFTeam_Spectator) {
            GetClientName(i, targetName, sizeof(targetName));
            if (StrEqual(targetName, target, false)) {
                targetClient = i;
                break;
            }
        }
    }
    
    // If no exact match, try partial match
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
    
    // Get the current captain's team
    int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    if (!IsValidClient(currentCaptain)) {
        ReplyToCommand(client, "\x01[Mix] \x03Current captain is not valid!");
        return Plugin_Handled;
    }
    
    int team = view_as<TFTeam>(GetClientTeam(currentCaptain));
    TF2_ChangeClientTeam(targetClient, view_as<TFTeam>(team));
    g_bPlayerLocked[targetClient] = true;
    
    // Decrease remaining picks
    g_iPicksRemaining--;
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03Admin %N has picked %N for the %s team!", client, targetClient, (view_as<TFTeam>(team) == TFTeam_Red) ? "RED" : "BLU");
    
    // Check if draft is complete
    if (g_iPicksRemaining <= 0) {
        EndDraft();
        return Plugin_Handled;
    }
    
    // Switch to next picker
    g_iCurrentPicker = (g_iCurrentPicker == 0) ? 1 : 0;
    
    // Reset pick timeout timer
    KillTimerSafely(g_hPickTimer);
    g_hPickTimer = CreateTimer(g_cvPickTimeout.FloatValue, Timer_PickTimeout);
    g_fPickTimerStartTime = GetGameTime();
    
    // Manually update HUD after admin pick
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

public Action Timer_PickTimeout(Handle timer) {
    if (!g_bMixInProgress)
        return Plugin_Stop;
        
    // Get current captain
    int currentCaptain = (g_iCurrentPicker == 0) ? g_iCaptain1 : g_iCaptain2;
    
    if (!IsValidClient(currentCaptain)) {
        PrintToChatAll("\x01[Mix] \x03Current captain is unavailable. Draft may need to be cancelled.");
        KillTimerSafely(g_hPickTimer);
        g_fPickTimerStartTime = 0.0;
        // Force immediate HUD update
        UpdateHUDForAll();
        return Plugin_Stop;
    }
    
    // Find a random available player to auto-pick
    int randomPlayer = FindNextAvailablePlayer();
    
    if (randomPlayer != -1) {
        // Auto-pick the random player
        PrintToChatAll("\x01[Mix] \x03Pick timed out! Auto-picking random player.");
        PickPlayer(currentCaptain, randomPlayer);
    } else {
        // No players left to pick, end draft
        PrintToChatAll("\x01[Mix] \x03Pick timed out! No players available. Ending draft.");
        EndDraft();
    }
    
    return Plugin_Stop;
}

void StartMix() {
    if (g_bMixInProgress) return;
    
    // Reset all timers and states
    ResetAllTimers();
    
    // Set mix state
    g_bMixInProgress = true;
    g_iCurrentPicker = 0;
    g_iMissingCaptain = -1;
    g_bVoteInProgress = false;
    g_fLastVoteTime = 0.0;
    g_iPicksRemaining = 10;
    
    // Set game state for mix
    ServerCommand("mp_tournament 1");
    ServerCommand("mp_teams_unbalance_limit 1");
    ServerCommand("mp_autoteambalance 0");
    ServerCommand("mp_forceautoteam 0");
    ServerCommand("tf_bot_quota_mode none");
    ServerCommand("tf_bot_quota 0");
    
    // Move captains to teams
    int team1 = GetRandomInt(TFTeam_Red, TFTeam_Blue);
    int team2 = (view_as<TFTeam>(team1) == TFTeam_Red) ? TFTeam_Blue : TFTeam_Red;
    
    MovePlayerToTeam(g_iCaptain1, view_as<TFTeam>(team1));
    MovePlayerToTeam(g_iCaptain2, view_as<TFTeam>(team2));
    
    // Move all other players to spectator
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && i != g_iCaptain1 && i != g_iCaptain2) {
            MovePlayerToTeam(i, TFTeam_Spectator);
        }
    }
    
    // Start timers
    g_fPickTimerStartTime = GetGameTime();
    g_hPickTimer = CreateTimer(1.0, Timer_PickTime, _, TIMER_REPEAT);
    g_hHudTimer = CreateTimer(1.0, Timer_UpdateHUD, _, TIMER_REPEAT);
    
    // Notify players
    PrintToChatAll("\x01[Mix] \x03Mix has started! First captain's turn to pick.");
}