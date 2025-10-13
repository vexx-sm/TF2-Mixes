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
    version = "0.3.0",
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

// Recent damage tracking for regen
#define RECENT_DAMAGE_SECONDS 10
int g_iRecentDamage[MAXPLAYERS + 1][MAXPLAYERS + 1][RECENT_DAMAGE_SECONDS];
Handle g_hRecentDamageTimer;

// Pre-game DM system
ConVar g_cvPreGameEnable;
ConVar g_cvPreGameSpawnProtect;

// Random spawn system
bool g_bSpawnRandom;
bool g_bTeamSpawnRandom;
ConVar g_hTeamSpawnRandom;
ConVar g_hSpawnRandom;
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
        // Use CloseHandle which is safer for plugin reload scenarios
        CloseHandle(timer);
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
    
    // Hook communication ConVars from main plugin
    HookConVarChange(g_hDMPreGameActive, OnDMPreGameActiveChanged);
    HookConVarChange(g_hDMDraftInProgress, OnDMDraftInProgressChanged);
    HookConVarChange(g_hDMStopAll, OnDMStopAllChanged);
    
    // Initialize regen timer array
    for (int i = 0; i <= MaxClients; i++) {
        g_hRegenTimer[i] = INVALID_HANDLE;
        g_bRegen[i] = false;
        g_iMaxHealth[i] = 0;
    }
    
    // Initialize damage tracking array
    for (int attacker = 0; attacker <= MaxClients; attacker++) {
        for (int victim = 0; victim <= MaxClients; victim++) {
            for (int i = 0; i < RECENT_DAMAGE_SECONDS; i++) {
                g_iRecentDamage[attacker][victim][i] = 0;
            }
        }
    }
    
    // Start recent damage tracking timer
    g_hRecentDamageTimer = INVALID_HANDLE;
    g_hRecentDamageTimer = CreateTimer(1.0, Timer_RecentDamage, _, TIMER_REPEAT);
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
    if (!IsValidClient(client))
        return;
        
    // Initialize player state
    g_bPlayerMoved[client] = false;
    g_bRegen[client] = false;
    g_iMaxHealth[client] = 0;
}

public void OnClientDisconnect(int client) {
    if (!IsValidClient(client))
        return;
        
    // Reset movement flag
    g_bPlayerMoved[client] = false;
    
    // Stop regen for disconnected player
    StopRegen(client);
    
    // Reset health tracking
    g_iMaxHealth[client] = 0;
    
    // Reset damage tracking for this player
    ResetPlayerDmgBasedRegen(client, true);
}

public void OnPluginEnd() {
    // Clean up health regen system
    KillTimerSafely(g_hRecentDamageTimer);
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
        // Reset movement flag - player will teleport on first movement
        g_bPlayerMoved[client] = false;
        float prot = GetConVarFloat(g_cvPreGameSpawnProtect);
        if (prot > 0.0) {
            TF2_AddCondition(client, TFCond_UberchargedHidden, prot);
        }
        
        // Store max health for regen system
        g_iMaxHealth[client] = GetClientHealth(client);
        
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
    }
        
    return Plugin_Continue;
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

    int damage = event.GetInt("damageamount");
    
    // Track recent damage for regen system
    g_iRecentDamage[attacker][victim][RECENT_DAMAGE_SECONDS - 1] += damage;
    
    // Stop regen for victim when they take damage
    StopRegen(victim);
    
    // Start regen after delay
    if (g_iRegenHP > 0) {
        CreateTimer(g_fRegenDelay, StartRegen, GetClientUserId(victim), TIMER_FLAG_NO_MAPCHANGE);
    }
    
    return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    if (!IsValidClient(client) || !IsPlayerAlive(client)) {
        return Plugin_Continue;
    }

    // Check if player is in DM and hasn't moved yet (only when globally enabled and during pre-game)
    if (IsDMActive() && !g_bPlayerMoved[client]) {
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
    if (g_hRegenTimer[client] != INVALID_HANDLE) {
        KillTimer(g_hRegenTimer[client]);
        g_hRegenTimer[client] = INVALID_HANDLE;
    }
    g_bRegen[client] = false;
}

public Action Timer_RegenTick(Handle timer, any userid) {
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client) || !IsPlayerAlive(client)) {
        StopRegen(client);
        return Plugin_Stop;
    }
    
    // Only regen when globally enabled and during pre-game DM phase (before draft starts)
    if (!IsDMActive()) {
        StopRegen(client);
        return Plugin_Stop;
    }
    
    // Stop regen if disabled
    if (g_iRegenHP <= 0) {
        StopRegen(client);
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
        LoadSpawnPoints();
    } else {
        ResetAllPlayersRegen();
    }
}

public void OnDMDraftInProgressChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    if (convar == null) return;
    
    // Draft state changed - no direct action needed
    // DM activation is controlled by OnDMPreGameActiveChanged
}

public void OnDMStopAllChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    if (convar == null) return;
    
    if (GetConVarBool(convar)) {
        ResetAllPlayersRegen();
        SetConVarInt(convar, 0);
    }
}

void ResetPlayerDmgBasedRegen(int client, bool alsoResetTaken = false) {
    for (int player = 1; player <= MaxClients; player++) {
        for (int i = 0; i < RECENT_DAMAGE_SECONDS; i++) {
            g_iRecentDamage[player][client][i] = 0;
        }
    }
    
    if (alsoResetTaken) {
        for (int player = 1; player <= MaxClients; player++) {
            for (int i = 0; i < RECENT_DAMAGE_SECONDS; i++) {
                g_iRecentDamage[client][player][i] = 0;
            }
        }
    }
}

void ResetAllPlayersRegen() {
    for (int i = 1; i <= MaxClients; i++) {
        // Stop active regen timers for connected players
        if (IsValidClient(i)) {
            StopRegen(i);
        }
        // Reset all player state arrays (must happen for all indices)
        ResetPlayerDmgBasedRegen(i);
        g_bRegen[i] = false;
        g_iMaxHealth[i] = 0;
        g_bPlayerMoved[i] = false;
    }
}

public Action Timer_RecentDamage(Handle timer) {
    // Shift damage array left by 1 second
    for (int attacker = 1; attacker <= MaxClients; attacker++) {
        for (int victim = 1; victim <= MaxClients; victim++) {
            for (int i = 0; i < RECENT_DAMAGE_SECONDS - 1; i++) {
                g_iRecentDamage[attacker][victim][i] = g_iRecentDamage[attacker][victim][i + 1];
            }
            g_iRecentDamage[attacker][victim][RECENT_DAMAGE_SECONDS - 1] = 0;
        }
    }
    return Plugin_Continue;
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
    
    g_hRedSpawns = new ArrayList(3);
    g_hBluSpawns = new ArrayList(3);
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
    // Default spawn loading
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
    // Spawn point selection
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
