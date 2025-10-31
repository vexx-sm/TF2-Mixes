#include <sourcemod>
#include <tf2>
#include <tf2_stocks>
#include <sdktools>
#include <float>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
    name = "TF2-Mixes DM Module",
    author = "vexx-sm",
    description = "DM features for TF2-Mixes plugin",
    version = "0.3.2",
    url = "https://github.com/vexx-sm/TF2-Mixes"
};

// ========================================
// DM MODULE VARIABLES
// ========================================

// Movement detection for spawn system
bool g_bPlayerMoved[MAXPLAYERS + 1];

// Health regeneration system
int g_iRegenHP;
bool g_bRegen[MAXPLAYERS + 1];
bool g_bKillStartRegen;
float g_fRegenTick;
float g_fRegenDelay;
Handle g_hRegenTimer[MAXPLAYERS + 1];
ConVar g_hRegenHP;
ConVar g_hRegenTick;
ConVar g_hRegenDelay;
ConVar g_hKillStartRegen;
int g_iMaxHealth[MAXPLAYERS + 1];

// Pre-game DM system
ConVar g_cvPreGameEnable;
ConVar g_cvPreGameSpawnProtect;

// Random spawn system
bool g_bSpawnRandom;
bool g_bTeamSpawnRandom;
ConVar g_hTeamSpawnRandom;
ConVar g_hSpawnRandom;
ConVar g_hSpawnDelay;
ConVar g_hNoVelocityOnSpawn;
float g_fSpawnDelay = 0.1;
bool g_bNoVelocityOnSpawn = true;
ArrayList g_hRedSpawns;
ArrayList g_hBluSpawns;
Handle g_hKv;

// Main plugin detection
bool g_bMainPluginLoaded = false;

// Communication ConVars from main plugin
ConVar g_hDMPreGameActive;
ConVar g_hDMDraftInProgress;
ConVar g_hDMStopAll;

// ========================================
// HELPER FUNCTIONS
// ========================================

bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

void KillTimerSafely(Handle &timer) {
    if (timer != INVALID_HANDLE) {
        delete timer;
        timer = INVALID_HANDLE;
    }
}

bool IsDMActive() {
    if (g_hDMPreGameActive == null || g_cvPreGameEnable == null) {
        return false;
    }
    
    return GetConVarBool(g_cvPreGameEnable) && 
           (GetConVarBool(g_hDMPreGameActive) || 
            (g_hDMDraftInProgress != null && GetConVarBool(g_hDMDraftInProgress)));
}

// ========================================
// PLUGIN LIFECYCLE
// ========================================

public void OnPluginStart() {
    // Wait for main plugin to load
    CreateTimer(1.0, Timer_CheckMainPlugin);
    
    // Create DM ConVars
    g_cvPreGameEnable = CreateConVar("sm_mix_pregame_enable", "1", "Enable pre-game DM during lobby and draft");
    g_cvPreGameSpawnProtect = CreateConVar("sm_mix_pregame_spawnprotect", "1.0", "Pre-game DM spawn protection seconds");
    
    // Health regeneration ConVars
    g_hRegenHP = CreateConVar("sm_mix_regenhp", "1", "Health added per regeneration tick. Set to 0 to disable.", FCVAR_NOTIFY);
    g_hRegenTick = CreateConVar("sm_mix_regentick", "0.1", "Delay between regeneration ticks.", FCVAR_NOTIFY);
    g_hRegenDelay = CreateConVar("sm_mix_regendelay", "5.0", "Seconds after damage before regeneration.", FCVAR_NOTIFY);
    g_hKillStartRegen = CreateConVar("sm_mix_kill_start_regen", "1", "Start the heal-over-time regen immediately after a kill.", FCVAR_NOTIFY);
    
    // Spawn system convars
    g_hSpawnRandom = CreateConVar("sm_mix_spawnrandom", "1", "Enable random spawns.", FCVAR_NOTIFY);
    g_hTeamSpawnRandom = CreateConVar("sm_mix_teamspawnrandom", "0", "Enable random spawns independent of team", FCVAR_NOTIFY);
    g_hSpawnDelay = CreateConVar("sm_mix_dm_spawn_delay", "0.1", "Delay after spawn before DM teleport.", FCVAR_NOTIFY);
    g_hNoVelocityOnSpawn = CreateConVar("sm_mix_dm_novelocity", "1", "Zero player velocity on DM teleport.", FCVAR_NOTIFY);

    // Communication ConVars from main plugin
    g_hDMPreGameActive = CreateConVar("sm_mix_dm_pregame_active", "0", "DM pre-game active state (controlled by main plugin)", FCVAR_DONTRECORD);
    g_hDMDraftInProgress = CreateConVar("sm_mix_dm_draft_in_progress", "0", "DM draft in progress state (controlled by main plugin)", FCVAR_DONTRECORD);
    g_hDMStopAll = CreateConVar("sm_mix_dm_stop_all", "0", "DM stop all features (controlled by main plugin)", FCVAR_DONTRECORD);
    
    // Hook events
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_PlayerHurt);
    
    // Initialize health regen values
    g_iRegenHP = GetConVarInt(g_hRegenHP);
    g_fRegenTick = GetConVarFloat(g_hRegenTick);
    g_fRegenDelay = GetConVarFloat(g_hRegenDelay);
    g_bKillStartRegen = GetConVarBool(g_hKillStartRegen);
    
    // Hook ConVar changes to update values
    HookConVarChange(g_hRegenHP, OnRegenConVarChanged);
    HookConVarChange(g_hRegenTick, OnRegenConVarChanged);
    HookConVarChange(g_hRegenDelay, OnRegenConVarChanged);
    HookConVarChange(g_hKillStartRegen, OnRegenConVarChanged);
    HookConVarChange(g_cvPreGameEnable, OnPreGameEnableChanged);
    HookConVarChange(g_hSpawnDelay, OnSpawnConVarChanged);
    HookConVarChange(g_hNoVelocityOnSpawn, OnSpawnConVarChanged);
    
    // Hook communication ConVars from main plugin
    HookConVarChange(g_hDMPreGameActive, OnDMPreGameActiveChanged);
    HookConVarChange(g_hDMDraftInProgress, OnDMDraftInProgressChanged);
    HookConVarChange(g_hDMStopAll, OnDMStopAllChanged);
    
    // Initialize regen timer array
    for (int i = 1; i <= MaxClients; i++) {
        g_hRegenTimer[i] = INVALID_HANDLE;
        g_bRegen[i] = false;
        g_iMaxHealth[i] = 0;
    }

    // Initialize spawn cvar cache
    g_fSpawnDelay = GetConVarFloat(g_hSpawnDelay);
    g_bNoVelocityOnSpawn = GetConVarBool(g_hNoVelocityOnSpawn);
}

public Action Timer_CheckMainPlugin(Handle timer) {
    // Assume main plugin is loaded since DM module depends on it
    g_bMainPluginLoaded = true;
    // Silent loading - main plugin will announce DM status
    return Plugin_Stop;
}

public void OnMapStart() {
    // Reset all regen timers and damage tracking
    ResetAllPlayersRegen();
    
    // Reset max health tracking and movement flags
    for (int i = 1; i <= MaxClients; i++) {
        g_iMaxHealth[i] = 0;
        g_bPlayerMoved[i] = false;
    }
    
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

    // Don't set g_bPreGameDMActive here - let ConVar handlers manage it
    // This prevents race conditions with main plugin communication
}

public void OnClientPutInServer(int client) {
    // Don't use IsValidClient - client may not be fully in-game yet
    if (client <= 0 || client > MaxClients)
        return;
        
    // Initialize player state
    g_bPlayerMoved[client] = false;
    g_bRegen[client] = false;
    g_iMaxHealth[client] = 0;
}

public void OnClientDisconnect(int client) {
    // Don't use IsValidClient - client is disconnecting so IsClientInGame returns false
    if (client <= 0 || client > MaxClients)
        return;
        
    // Reset movement flag
    g_bPlayerMoved[client] = false;
    
    // Stop regen for disconnected player
    StopRegen(client);
    
    // Reset health tracking
    g_iMaxHealth[client] = 0;
}

public void OnPluginEnd() {
    // Clean up health regen system
    ResetAllPlayersRegen();
    
    // Clean up spawn point arrays
    if (g_hRedSpawns != null) {
        delete g_hRedSpawns;
    }
    if (g_hBluSpawns != null) {
        delete g_hBluSpawns;
    }
    if (g_hKv != null) {
        delete g_hKv;
    }
}

// ========================================
// DM EVENT HANDLERS
// ========================================

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    // Only enable DM when globally enabled and during pre-game (before draft starts)
    if (IsDMActive()) {
        // Apply brief invulnerability during teleport window
        float prot = GetConVarFloat(g_cvPreGameSpawnProtect);
        if (prot > 0.0) {
            TF2_AddCondition(client, TFCond_UberchargedHidden, prot);
        }

        // Store max health for regen system
        g_iMaxHealth[client] = GetClientHealth(client);

        // Teleport to a safe random spawn shortly after spawn
        CreateTimer(g_fSpawnDelay, RandomSpawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

        // Start health regen after spawn protection - only if enabled
        if (g_iRegenHP > 0) {
            CreateTimer(prot, StartRegen, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        }
    }
    
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;
        
    // Only enable DM when globally enabled and during pre-game (before draft starts)
    if (IsDMActive()) {
        int attacker = GetClientOfUserId(event.GetInt("attacker"));
        if (IsValidClient(attacker) && attacker != client) {
            TF2_RegeneratePlayer(attacker);
            
            // Store max health for regen system
            g_iMaxHealth[attacker] = GetClientHealth(attacker);
            
            // Start regen immediately after kill if enabled
            if (g_bKillStartRegen && g_iRegenHP > 0) {
                CreateTimer(0.1, StartRegen, GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
            }
        }
        
        // Reset movement flag for respawn
        g_bPlayerMoved[client] = false;
        
        // Stop regen for dead player
        StopRegen(client);
        
        // Ensure instant respawn during DM (no wait/no transition)
        // Keep respawn times disabled while DM is active
        ServerCommand("mp_disable_respawn_times 1");
        
        // Respawn player immediately next frame to avoid deathcam
        CreateTimer(0.0, Timer_RespawnNow, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
        
    return Plugin_Continue;
}

public Action Timer_RespawnNow(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client)) {
        return Plugin_Stop;
    }
    
    // Only respawn if DM is still active
    if (!IsDMActive()) {
        return Plugin_Stop;
    }
    
    TF2_RespawnPlayer(client);
    return Plugin_Stop;
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast) {
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    
    if (!IsValidClient(victim)) {
        return Plugin_Continue;
    }
    
    // Skip if attacker is world/environment (fall damage, etc.)
    if (attacker == 0) {
        return Plugin_Continue;
    }
    
    // Skip if attacker is invalid (but allow self-damage where attacker == victim)
    if (!IsValidClient(attacker) && attacker != victim) {
        return Plugin_Continue;
    }
    
    // Only track damage when globally enabled and during pre-game DM phase (before draft starts)
    if (!IsDMActive()) {
        return Plugin_Continue;
    }

    // Don't process regen if disabled
    if (g_iRegenHP <= 0) {
        return Plugin_Continue;
    }

    // Stop regen for victim when they take damage
    StopRegen(victim);
    
    // Start regen after delay
    if (g_iRegenHP > 0) {
        CreateTimer(g_fRegenDelay, StartRegen, GetClientUserId(victim), TIMER_FLAG_NO_MAPCHANGE);
    }
    
    return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    // Movement-based teleport disabled; spawns handled on player_spawn.
    return Plugin_Continue;
}

// ========================================
// HEALTH REGENERATION SYSTEM
// ========================================

public Action StartRegen(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client) || !IsPlayerAlive(client)) {
        return Plugin_Stop;
    }
    
    // Only enable regen when globally enabled and during pre-game DM phase (before draft starts)
    if (!IsDMActive()) {
        return Plugin_Stop;
    }
    
    // Don't start regen if disabled
    if (g_iRegenHP <= 0) {
        return Plugin_Stop;
    }
    
    if (g_bRegen[client]) {
        return Plugin_Stop; // Already regenerating
    }
    
    g_bRegen[client] = true;
    g_hRegenTimer[client] = CreateTimer(g_fRegenTick, Timer_RegenTick, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    
    return Plugin_Stop;
}

void StopRegen(int client) {
    KillTimerSafely(g_hRegenTimer[client]);
    g_bRegen[client] = false;
}

public Action Timer_RegenTick(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    // IMPORTANT: Never delete/kill the timer from inside its own callback.
    // Instead, clear our bookkeeping and return Plugin_Stop.
    if (!IsValidClient(client) || !IsPlayerAlive(client)) {
        g_bRegen[client] = false;
        g_hRegenTimer[client] = INVALID_HANDLE;
        return Plugin_Stop;
    }
    
    // Only regen when globally enabled and during pre-game DM phase (before draft starts)
    if (!IsDMActive()) {
        g_bRegen[client] = false;
        g_hRegenTimer[client] = INVALID_HANDLE;
        return Plugin_Stop;
    }
    
    // Stop regen if disabled
    if (g_iRegenHP <= 0) {
        g_bRegen[client] = false;
        g_hRegenTimer[client] = INVALID_HANDLE;
        return Plugin_Stop;
    }
    
    int currentHealth = GetClientHealth(client);
    int maxHealth = g_iMaxHealth[client];
    
    if (maxHealth <= 0) {
        maxHealth = currentHealth;
        g_iMaxHealth[client] = maxHealth;
    }
    
    if (currentHealth < maxHealth) {
        int newHealth = currentHealth + g_iRegenHP;
        if (newHealth > maxHealth) {
            newHealth = maxHealth;
        }
        SetEntityHealth(client, newHealth);
    }
    
    return Plugin_Continue;
}

public void OnRegenConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    // Update regen values when ConVars change
    g_iRegenHP = GetConVarInt(g_hRegenHP);
    g_fRegenTick = GetConVarFloat(g_hRegenTick);
    g_fRegenDelay = GetConVarFloat(g_hRegenDelay);
    g_bKillStartRegen = GetConVarBool(g_hKillStartRegen);
}

public void OnPreGameEnableChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    // Pre-game enable state changed - no action needed
}

public void OnDMPreGameActiveChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    if (convar == null) return;
    
    bool active = GetConVarBool(convar);
    
    if (active) {
        // Ensure instant respawn is active during DM
        ServerCommand("mp_disable_respawn_times 1");
        LoadSpawnPoints();
    } else {
        ResetAllPlayersRegen();
    }
}

public void OnDMDraftInProgressChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    if (convar == null) return;
    
    // Draft state changed - if DM is active, ensure instant respawn
    if (IsDMActive()) {
        ServerCommand("mp_disable_respawn_times 1");
    }
    // DM activation is controlled by OnDMPreGameActiveChanged
}

public void OnDMStopAllChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    if (convar == null) return;
    
    // Don't modify ConVar from its own callback - use deferred action instead
    if (GetConVarBool(convar)) {
        ResetAllPlayersRegen();
        // Reset via deferred timer to avoid ConVar callback loop
        CreateTimer(0.1, Timer_ResetDMStop);
    }
}

public Action Timer_ResetDMStop(Handle timer) {
    SetConVarInt(g_hDMStopAll, 0);
    return Plugin_Stop;
}

void ResetAllPlayersRegen() {
    for (int i = 1; i <= MaxClients; i++) {
        // Stop active regen timers for connected players
        if (IsValidClient(i)) {
            StopRegen(i);
        }
        // Reset all player state arrays (must happen for all indices)
        g_bRegen[i] = false;
        g_iMaxHealth[i] = 0;
        g_bPlayerMoved[i] = false;
    }
}

public void OnSpawnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    g_fSpawnDelay = GetConVarFloat(g_hSpawnDelay);
    g_bNoVelocityOnSpawn = GetConVarBool(g_hNoVelocityOnSpawn);
}

// ========================================
// RANDOM SPAWN SYSTEM
// ========================================

void LoadSpawnPoints() {
    // Random spawn system - exact copy
    g_bSpawnRandom = GetConVarBool(g_hSpawnRandom);
    g_bTeamSpawnRandom = GetConVarBool(g_hTeamSpawnRandom);
    
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
    
    g_hRedSpawns = new ArrayList(6);
    g_hBluSpawns = new ArrayList(6);
    g_hKv = new KeyValues("Spawns");
    
    char map[64];
    GetCurrentMapLowercase(map, sizeof(map));
    
    char path[256];
    BuildPath(Path_SM, path, sizeof(path), "configs/mixes/%s.cfg", map);
    
    LoadMapConfig(path);
}

void LoadMapConfig(const char[] path) {
    if (FileExists(path)) {
        if (FileToKeyValues(g_hKv, path)) {
            LoadSpawnsFromConfig();
        } else {
            LoadDefaultSpawns();
        }
    } else {
        LoadDefaultSpawns();
    }
}

void LoadSpawnsFromConfig() {
    // Load spawns from config (origin + angles)
    float vectors[6];
    float origin[3];
    float angles[3];

    if (KvJumpToKey(g_hKv, "red", false)) {
        if (KvGotoFirstSubKey(g_hKv, false)) {
            do {
                char originStr[64];
                char anglesStr[64];
                KvGetString(g_hKv, "origin", originStr, sizeof(originStr));
                KvGetString(g_hKv, "angles", anglesStr, sizeof(anglesStr));

                if (strlen(originStr) > 0 && StringToVector(originStr, origin)) {
                    if (strlen(anglesStr) == 0 || !StringToVector(anglesStr, angles)) {
                        angles[0] = 0.0; angles[1] = 0.0; angles[2] = 0.0;
                    }
                    vectors[0] = origin[0]; vectors[1] = origin[1]; vectors[2] = origin[2];
                    vectors[3] = angles[0]; vectors[4] = angles[1]; vectors[5] = 0.0; // zero roll
                    g_hRedSpawns.PushArray(vectors);
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
                char anglesStr[64];
                KvGetString(g_hKv, "origin", originStr, sizeof(originStr));
                KvGetString(g_hKv, "angles", anglesStr, sizeof(anglesStr));

                if (strlen(originStr) > 0 && StringToVector(originStr, origin)) {
                    if (strlen(anglesStr) == 0 || !StringToVector(anglesStr, angles)) {
                        angles[0] = 0.0; angles[1] = 0.0; angles[2] = 0.0;
                    }
                    vectors[0] = origin[0]; vectors[1] = origin[1]; vectors[2] = origin[2];
                    vectors[3] = angles[0]; vectors[4] = angles[1]; vectors[5] = 0.0; // zero roll
                    g_hBluSpawns.PushArray(vectors);
                }
            } while (KvGotoNextKey(g_hKv, false));
            KvGoBack(g_hKv);
        }
        KvGoBack(g_hKv);
    }
}

void LoadDefaultSpawns() {
    // Default spawn loading with angles from entity rotation
    int ent = -1;
    float origin[3];
    float angles[3];
    float vectors[6];
    while ((ent = FindEntityByClassname(ent, "info_player_teamspawn")) > 0) {
        if (!IsValidEntity(ent)) continue;

        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
        // Try Prop_Data first, then fall back
        if (!GetEntPropVector(ent, Prop_Data, "m_angRotation", angles)) {
            angles[0] = 0.0; angles[1] = 0.0; angles[2] = 0.0;
        }
        vectors[0] = origin[0]; vectors[1] = origin[1]; vectors[2] = origin[2];
        vectors[3] = angles[0]; vectors[4] = angles[1]; vectors[5] = 0.0; // zero roll

        int team = GetEntProp(ent, Prop_Send, "m_iTeamNum");
        if (team == 2) {
            g_hRedSpawns.PushArray(vectors);
        } else if (team == 3) {
            g_hBluSpawns.PushArray(vectors);
        }
    }
}

public bool TraceFilter_None(int entity, int contentsMask) {
    // Do not filter any entity; we want to detect both players and world geometry
    return false;
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

public Action RandomSpawn(Handle timer, any clientid) {
    int client = GetClientOfUserId(clientid);
    if (!IsValidClient(client) || !IsPlayerAlive(client) || !IsDMActive()) {
        return Plugin_Stop;
    }

    if (!g_bSpawnRandom) {
        return Plugin_Stop;
    }

    // Choose spawn list
    int team = GetClientTeam(client);
    ArrayList spawns = null;
    if (g_bTeamSpawnRandom) {
        // Pick a random team list
        spawns = (GetRandomInt(0, 1) == 0) ? g_hRedSpawns : g_hBluSpawns;
        if (spawns.Length == 0) {
            spawns = (spawns == g_hRedSpawns) ? g_hBluSpawns : g_hRedSpawns;
        }
    } else {
        spawns = (team == 2) ? g_hRedSpawns : (team == 3 ? g_hBluSpawns : null);
    }

    if (spawns == null || spawns.Length == 0) {
        return Plugin_Stop;
    }

    int rand = GetRandomInt(0, spawns.Length - 1);
    float vectors[6];
    spawns.GetArray(rand, vectors);

    float origin[3];
    float angles[3];
    origin[0] = vectors[0]; origin[1] = vectors[1]; origin[2] = vectors[2];
    angles[0] = vectors[3]; angles[1] = vectors[4]; angles[2] = 0.0;

    // Validate: outside world?
    if (TR_PointOutsideWorld(origin)) {
        // Remove bad spawn and retry
        RemoveSpawnAt(spawns, rand);
        CreateTimer(0.1, RandomSpawn, clientid, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    // Hull check for collisions with world or players
    float mins[3] = {-24.0, -24.0, 0.0};
    float maxs[3] = {24.0, 24.0, 82.0};
    TR_TraceHullFilter(origin, origin, mins, maxs, MASK_PLAYERSOLID, TraceFilter_None);
    if (TR_DidHit()) {
        int ent = TR_GetEntityIndex();
        if (ent > 0 && ent <= MaxClients) {
            // Occupied by a player; try another spawn
            CreateTimer(0.1, RandomSpawn, clientid, TIMER_FLAG_NO_MAPCHANGE);
            return Plugin_Stop;
        } else {
            // Clipping world or prop; delete this spawn and retry
            RemoveSpawnAt(spawns, rand);
            CreateTimer(0.1, RandomSpawn, clientid, TIMER_FLAG_NO_MAPCHANGE);
            return Plugin_Stop;
        }
    }

    // Teleport: optionally zero velocity
    float zeroVel[3] = {0.0, 0.0, 0.0};
    if (g_bNoVelocityOnSpawn) {
        TeleportEntity(client, origin, angles, zeroVel);
    } else {
        TeleportEntity(client, origin, angles, NULL_VECTOR);
    }

    // Remove temporary invulnerability if still present
    TF2_RemoveCondition(client, TFCond_UberchargedHidden);

    return Plugin_Stop;
}

void RemoveSpawnAt(ArrayList list, int index) {
    if (list != null && index >= 0 && index < list.Length) {
        list.Erase(index);
    }
}

bool FindGroundLevel(const float origin[3], float groundOrigin[3]) {
    groundOrigin = origin;
    
    // Trace down to find ground
    float traceStart[3], traceEnd[3];
    traceStart = origin;
    traceEnd = origin;
    traceEnd[2] -= 1000.0; // Trace down 1000 units
    
    TR_TraceRayFilter(traceStart, traceEnd, MASK_SOLID, RayType_EndPoint, TraceFilter_None);
    
    if (TR_DidHit()) {
        TR_GetEndPosition(groundOrigin);
        groundOrigin[2] += 5.0; // Well above ground to avoid fringe cases
        return true;
    }
    
    return false;
}

// ========================================
// DM MODULE API FUNCTIONS
// ========================================

// Check if DM module is ready
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    RegPluginLibrary("mixes_dm");
    CreateNative("DM_IsReady", Native_DM_IsReady);
    return APLRes_Success;
}

public int Native_DM_IsReady(Handle plugin, int numParams) {
    return g_bMainPluginLoaded ? 1 : 0;
}