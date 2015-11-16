#include <clientprefs>
#include <cstrike>
#include <sourcemod>
#include "include/logdebug.inc"
#include "include/priorityqueue.inc"
#include "include/pugsetup.inc"
#include "pugsetup/generic.sp"

#pragma semicolon 1
#pragma newdecls required

/*
 * This isn't meant to be a comprehensive stats system, it's meant to be a simple
 * way to balance teams to replace manual stuff using a (exponentially) weighted moving average.
 * The update takes place every round, following this equation
 *
 * R' = (1-a) * R_prev + alpha * R
 * Where
 *    R' is the new rating
 *    a is the alpha factor (how much a new round counts into the new rating)
 *    R is the round-rating
 *
 * Alpha is made to be variable, where it decreases linearly to allow
 * ratings to change more quickly early on when a player has few rounds played.
 */
#define ALPHA_INIT 0.1
#define ALPHA_FINAL 0.003
#define ROUNDS_FINAL 250.0
#define AUTH_METHOD AuthId_Steam2

/** Client cookie handles **/
Handle g_RWSCookie = INVALID_HANDLE;
Handle g_RoundsPlayedCookie = INVALID_HANDLE;

Handle g_PeriodRWSCookie = INVALID_HANDLE;
Handle g_PeriodRoundsPlayedCookie = INVALID_HANDLE;

/** Client stats **/
float g_PlayerRWS[MAXPLAYERS+1];
int g_PlayerRounds[MAXPLAYERS+1];

float g_PlayerPeriodRWS[MAXPLAYERS+1];
int g_PlayerPeriodRounds[MAXPLAYERS+1];

// HLTV.org Rating
float g_PlayerRating[MAXPLAYERS+1];
int g_PlayerRatingRoundsSurvived[MAXPLAYERS+1];
int g_PlayerRatingTotalRounds[MAXPLAYERS+1];
int g_PlayerRatingKills[MAXPLAYERS+1];
int g_PlayerRatingMultiKillValue[MAXPLAYERS+1];

bool g_PlayerHasStats[MAXPLAYERS+1];

/** Rounds stats **/
int g_RoundPoints[MAXPLAYERS+1];
int g_RoundHealth[MAXPLAYERS+1];
int g_RoundKills[MAXPLAYERS+1];
int g_RoundSurvived[MAXPLAYERS+1];

/** Cvars **/
ConVar g_AllowRWSCommandCvar;
ConVar g_RecordRWSCvar;
ConVar g_SetCaptainsByRWSCvar;
ConVar g_ShowRWSOnMenuCvar;

bool g_ManuallySetCaptains = false;
bool g_SetTeamBalancer = false;


public Plugin myinfo = {
    name = "CS:GO PugSetup: RWS balancer",
    author = "splewis",
    description = "Sets player teams based on historical RWS ratings stored via clientprefs cookies",
    version = PLUGIN_VERSION,
    url = "https://github.com/splewis/csgo-pug-setup"
};

public void OnPluginStart() {
    InitDebugLog(DEBUG_CVAR, "rwsbalance");
    LoadTranslations("pugsetup.phrases");
    LoadTranslations("common.phrases");

    HookEvent("bomb_defused", Event_Bomb);
    HookEvent("bomb_planted", Event_Bomb);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_DamageDealt);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("round_start", Event_RoundStart);

    RegAdminCmd("sm_showrws", Command_DumpRWS, ADMFLAG_KICK, "Dumps all player historical rws and rounds played");
    RegConsoleCmd("sm_rws", Command_RWS, "Show player's historical rws");
    AddChatAlias(".trws", "sm_rws");

    RegConsoleCmd("sm_hltv_rating", Command_Rating, "Show player's rating");
    AddChatAlias(".rating", "sm_hltv_rating");

    RegConsoleCmd("sm_period_rws", Command_PeriodRWS, "Show player's period rws");
    AddChatAlias(".rws", "sm_period_rws");

    g_AllowRWSCommandCvar = CreateConVar("sm_pugsetup_rws_allow_rws_command", "0", "Whether players can use the .rws or !rws command on other players");
    g_RecordRWSCvar = CreateConVar("sm_pugsetup_rws_record_stats", "1", "Whether rws should be recorded during live matches (set to 0 to disable changing players rws stats)");
    g_SetCaptainsByRWSCvar = CreateConVar("sm_pugsetup_rws_set_captains", "1", "Whether to set captains to the highest-rws players in a game using captains. Note: this behavior can be overwritten by the pug-leader or admins.");
    g_ShowRWSOnMenuCvar = CreateConVar("sm_pugsetup_rws_display_on_menu", "0", "Whether rws stats are to be displayed on captain-player selection menus");

    AutoExecConfig(true, "pugsetup_rwsbalancer", "sourcemod/pugsetup");

    g_RWSCookie = RegClientCookie("pugsetup_rws", "Pugsetup RWS rating", CookieAccess_Protected);
    g_RoundsPlayedCookie = RegClientCookie("pugsetup_roundsplayed", "Pugsetup rounds played", CookieAccess_Protected);

    g_PeriodRWSCookie = RegClientCookie("pugsetup_period_rws", "Pugsetup RWS rating over the current period", CookieAccess_Protected);
    g_PeriodRoundsPlayedCookie = RegClientCookie("pugsetup_period_roundsplayed", "Pugsetup rounds played over the current period", CookieAccess_Protected);

    g_RatingCookie = RegClientCookie("pugsetup_rating", "Pugsetup HLTV rating", CookieAccess_Protected);
    g_RatingRoundsSurvivedCookie = RegClientCookie("pugsetup_rating_roundssurvived", "Pugsetup HLTV rating rounds played", CookieAccess_Protected);
    g_RatingTotalRoundsCookie = RegClientCookie("pugsetup_rating_totalrounds", "Pugsetup HLTV rating total rounds", CookieAccess_Protected);
    g_RatingKillsCookie = RegClientCookie("pugsetup_rating_kills", "Pugsetup HLTV rating kills", CookieAccess_Protected);
    g_RatingMultiKillValueCookie = RegClientCookie("pugsetup_rating_multikillvalue", "Pugsetup HLTV rating multi kill value", CookieAccess_Protected);
}

public void OnAllPluginsLoaded() {
    g_SetTeamBalancer = SetTeamBalancer(BalancerFunction);
}

public void OnPluginEnd() {
    if (g_SetTeamBalancer)
        ClearTeamBalancer();
}

public void OnMapStart() {
    g_ManuallySetCaptains = false;
}

public void OnPermissionCheck(int client, const char[] command, Permission p, bool& allow) {
    if (StrEqual(command, "sm_capt", false)) {
        g_ManuallySetCaptains = true;
    }
}

public void OnClientCookiesCached(int client) {
    if (IsFakeClient(client))
        return;

    g_PlayerRWS[client] = GetCookieFloat(client, g_RWSCookie);
    g_PlayerRounds[client] = GetCookieInt(client, g_RoundsPlayedCookie);

    g_PlayerPeriodRWS[client] = GetCookieFloat(client, g_PeriodRWSCookie);
    g_PlayerPeriodRounds[client] = GetCookieInt(client, g_PeriodRoundsPlayedCookie);

    g_PlayerRating[client] = GetCookieFloat(client, g_RatingCookie);
    g_PlayerRatingRoundsSurvived[client] = GetCookieInt(client, g_RatingRoundsSurvivedCookie);
    g_PlayerRatingTotalRounds[client] = GetCookieInt(client, g_RatingTotalRoundsCookie);
    g_PlayerRatingKills[client] = GetCookieInt(client, g_RatingKillsCookie);
    g_PlayerRatingMultiKillValue[client] = GetCookieInt(client, g_RatingMultiKillValueCookie);

    g_PlayerHasStats[client] = true;
}

public void OnClientConnected(int client) {
    g_PlayerRWS[client] = 0.0;
    g_PlayerRounds[client] = 0;

    g_PlayerPeriodRWS[client] = 0.0;
    g_PlayerPeriodRounds[client] = 0;

    g_PlayerRating[client] = 0.0;
    g_PlayerRatingRoundsSurvived[client] = 0;
    g_PlayerRatingTotalRounds[client] = 0;
    g_PlayerRatingKills[client] = 0;
    g_PlayerRatingMultiKillValue[client] = 0;

    g_RoundPoints[client] = 0;
    g_RoundHealth[client] = 100;
    g_RoundKills[client] = 0;
    g_RoundSurvived[client] = 1;
    
    g_PlayerHasStats[client] = false;
}

public void OnClientDisconnect(int client) {
    WriteStats(client);
}

public bool HasStats(int client) {
    return g_PlayerHasStats[client];
}

public void WriteStats(int client) {
    if (!IsValidClient(client) || IsFakeClient(client) || !g_PlayerHasStats[client])
        return;

    SetCookieInt(client, g_RoundsPlayedCookie, g_PlayerRounds[client]);
    SetCookieFloat(client, g_RWSCookie, g_PlayerRWS[client]);

    SetCookieInt(client, g_PeriodRoundsPlayedCookie, g_PlayerPeriodRounds[client]);
    SetCookieFloat(client, g_PeriodRWSCookie, g_PlayerPeriodRWS[client]);

    SetCookieFloat(client, g_RatingCookie, g_PlayerRating[client]);
    SetCookieInt(client, g_RatingRoundsSurvivedCookie, g_PlayerRatingRoundsSurvived[client]);
    SetCookieInt(client, g_RatingTotalRoundsCookie, g_PlayerRatingTotalRounds[client]);
    SetCookieInt(client, g_RatingKillsCookie, g_PlayerRatingKills[client] );
    SetCookieInt(client, g_RatingMultiKillValueCookie, g_PlayerRatingMultiKillValue[client]);
}

public void SplitRemainingPlayers(int teamSize, ArrayList playerList, ArrayList &remainingTeamTwoOptions) {
	if ( playerList.Length == teamSize ) {
		remainingTeamTwoOptions.Push(playerList);
	} else {
		// Do recursion and stuff
		for (int i = 0; i < playerList.Length; i++) {
			ArrayList playerListClone = CloneArray(playerList);
			RemoveFromArray(playerListClone, i);
			SplitRemainingPlayers(teamSize, playerListClone, remainingTeamTwoOptions);

		}
	}
}

public void SortPlayers(int teamSize, ArrayList firstTeam, ArrayList playerList, ArrayList &final_team_one, ArrayList &final_team_two, float &minRwsDifference) {

	if (firstTeam.Length == teamSize) {
			// Narrow down team two
			ArrayList team_one = firstTeam;
			ArrayList possibleTwos = new ArrayList();
			ArrayList remainingPlayers = new ArrayList();

			// Add the people that aren't in the first team to the 2nd team
			for (int i = 0; i < playerList.Length; i++) {
				if ( FindValueInArray(team_one, playerList.Get(i)) == -1 ) {
					remainingPlayers.Push(playerList.Get(i));
				} 
			}
			
			SplitRemainingPlayers(teamSize, remainingPlayers, possibleTwos);

			for(int i = 0; i < possibleTwos.Length; i++) {
				ArrayList team_two = possibleTwos.Get(i);

				// Get RWS of teams 1 and 2 and compare them
				float team_one_rws = 0.0;
				float team_two_rws = 0.0;
				
				for (int i = 0; i < team_one.Length; i++) {
					int client = team_one.Get(i);
					
					float player_rws = g_PlayerRWS[client];
			    	if (player_rws < 1) {
			    		// Set new players RWS to a slightly below average value (8)
			    		player_rws = 8.0;
			    	}
					team_one_rws += player_rws;
				}
				for (int i = 0; i < team_two.Length; i++) {
					int client = team_two.Get(i);

					float player_rws = g_PlayerRWS[client];
			    	if (player_rws < 1) {
			    		// Set new players RWS to a slightly below average value (8)
			    		player_rws = 8.0;
			    	}

					team_two_rws += player_rws;
				}

				float localDifference = FloatAbs(team_one_rws - team_two_rws);

				if (localDifference < minRwsDifference) {
					final_team_one = CloneArray(team_one);
					final_team_two = CloneArray(team_two);
					minRwsDifference = localDifference;
				}
			}
			delete possibleTwos;
			delete remainingPlayers;
	} else {

		// Do recursion and stuff
		for (int i = 0; i < firstTeam.Length; i++) {
			
			ArrayList firstTeamclone = CloneArray(firstTeam);
			RemoveFromArray(firstTeamclone, i);
			SortPlayers(teamSize, firstTeamclone, playerList, final_team_one, final_team_two, minRwsDifference);
			delete firstTeamclone;
			
		}
	}
}

public void FindSecondTeam(ArrayList buffer, ArrayList remainingPlayers, int done, int begin, int end, ArrayList &seconds ) {

	for (int i = begin; i < end; i++)
    {
    	buffer.Set(done, remainingPlayers.Get(i));

      	if (done == buffer.Length - 1) {
      		ArrayList bufferClone = CloneArray( buffer );
        	seconds.Push(bufferClone);
    	}

      	else {
        	FindSecondTeam(buffer, remainingPlayers, done+1, i+1, end, seconds);
      	}
    }
}

public void FindFirstTeam(ArrayList buffer, ArrayList players, int done, int begin, int end, ArrayList &final_team_one, ArrayList &final_team_two, float &minRwsDifference) {
    for (int i = begin; i < end; i++)
    {
    	buffer.Set(done, players.Get(i));

      	if (done == buffer.Length - 1) {
      		// We have a possible team one ("buffer"), now find a team two

        	ArrayList remainingPlayers = new ArrayList();

			// Add the people that aren't in the first team to the 2nd team
			for (int j = 0; j < players.Length; j++) {
				if ( FindValueInArray(buffer, players.Get(j)) == -1 ) {
					remainingPlayers.Push(players.Get(j));
				} 
			}


        	ArrayList possibleSecondTeams = new ArrayList();
        	ArrayList secondTeamBuffer = new ArrayList(1, buffer.Length);
        	FindSecondTeam(secondTeamBuffer, remainingPlayers, 0, 0, remainingPlayers.Length, possibleSecondTeams);
        	float team_one_rws = 0.0;

        	for (int j = 0; j < buffer.Length; j++) {
        		int client = buffer.Get(j);
					
				float player_rws = g_PlayerRWS[client];
		    	if (player_rws < 1) {
		    		// Set new players RWS to a slightly below average value (8)
		    		player_rws = 8.0;
		    	}
				team_one_rws += player_rws;
			}

        	for (int j = 0; j < possibleSecondTeams.Length; j++) {

        		ArrayList secondteam = possibleSecondTeams.Get(j);
        		float team_two_rws = 0.0;

        		for (int k = 0; k < secondteam.Length; k++ ) {
        			int client = secondteam.Get(k);
					
					float player_rws = g_PlayerRWS[client];
			    	if (player_rws < 1) {
			    		// Set new players RWS to a slightly below average value (8)
			    		player_rws = 8.0;
			    	}
					team_two_rws += player_rws;
        		}

        		// Compare the RWS for team one and team two and if ti's less than the min then make them the new mins 
        		float localDifference = FloatAbs(team_one_rws - team_two_rws);

				if (localDifference < minRwsDifference) {
					final_team_one = CloneArray(buffer);
					final_team_two = CloneArray(secondteam);
					minRwsDifference = localDifference;
				}
				delete secondteam;

			}
			delete possibleSecondTeams;
			delete secondTeamBuffer;
			delete remainingPlayers;
    	}

      	else {
        	FindFirstTeam(buffer, players, done+1, i+1, end, final_team_one, final_team_two, minRwsDifference);
      }
    }
}


public void FindCombinations(int m, ArrayList players, ArrayList &final_team_one, ArrayList &final_team_two, float &minRwsDifference){
	ArrayList buffer = new ArrayList(1, m);
	FindFirstTeam(buffer, players, 0, 0, players.Length, final_team_one, final_team_two, minRwsDifference);
	delete buffer;
}


/**
 * Here the teams are actually set to use the rws stuff.
 */
public void BalancerFunction(ArrayList players) {

	ArrayList team_one = new ArrayList();
	ArrayList team_two = new ArrayList();
	float minRwsDifference = 9999.0;

	// Assign all players to spec to account for color bug
	for(int i = 0; i < GetPugMaxPlayers(); i++) {
		SwitchPlayerTeam(players.Get(i), CS_TEAM_SPECTATOR);
	}

	FindCombinations( (GetPugMaxPlayers() / 2), players, team_one, team_two, minRwsDifference);

	
	// SortPlayers((GetPugMaxPlayers() / 2), players, players, team_one, team_two, minRwsDifference);
	LogDebug("[TEAM ONE]");
	LogDebug("----------");
	for(int i = 0; i < team_one.Length; i++) {
		int t1player = team_one.Get(i);
		float t1playerRWS = g_PlayerRWS[t1player];
		if (t1playerRWS < 1 ) {
			t1playerRWS = 8.0;
		}
		LogDebug("%L [%.2f RWS]", t1player, t1playerRWS);
		SwitchPlayerTeam(t1player, CS_TEAM_CT);
	}

	LogDebug("");
	LogDebug("[TEAM TWO]");
	LogDebug("----------");
	for(int i = 0; i < team_two.Length; i++) {
		int t2player = team_two.Get(i);
		float t2playerRWS = g_PlayerRWS[t2player];
		if (t2playerRWS < 1) {
			t2playerRWS = 8.0;
		}
		LogDebug("%L [%.2f RWS]", t2player, t2playerRWS);
		SwitchPlayerTeam(t2player, CS_TEAM_T);
	}
	LogDebug("");
    LogDebug("[Final Team Status]");
    LogDebug("[The RWS difference is: %.2f]", minRwsDifference);

    // Sort out spectators

    LogDebug("");
	LogDebug("[SPECTATORS]");
	LogDebug("----------");
	for (int i = 0; i < players.Length; i++) {
		if ( FindValueInArray( team_one, players.Get(i) ) == -1 && FindValueInArray( team_two, players.Get(i) ) == -1 ) {
			int spectator = players.Get(i);
			if (IsPlayer(spectator)) {
				LogDebug("-- %L", spectator);
            	SwitchPlayerTeam(spectator, CS_TEAM_SPECTATOR);
			}
		} 
	}

	delete team_one;
	delete team_two;
			
}

/**
 * These events update player "rounds points" for computing rws at the end of each round.
 */
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    if (!IsMatchLive())
        return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    bool validAttacker = IsValidClient(attacker);
    bool validVictim = IsValidClient(victim);

    if (validAttacker && validVictim && HelpfulAttack(attacker, victim)) {
        g_RoundPoints[attacker] += 100;
        g_RoundKills[attacker]++;
    }
    if (validVictim) {
        g_RoundSurvived[victim] = 0;
    }
}

public Action Event_Bomb(Event event, const char[] name, bool dontBroadcast) {
    if (!IsMatchLive())
        return;

    int client = GetClientOfUserId(event.GetInt("userid"));
    g_RoundPoints[client] += 25;
}

public Action Event_DamageDealt(Event event, const char[] name, bool dontBroadcast) {
    if (!IsMatchLive())
        return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int damage = event.GetInt("dmg_health");
    bool validAttacker = IsValidClient(attacker);
    bool validVictim = IsValidClient(victim);

    if (validAttacker && validVictim && HelpfulAttack(attacker, victim) ) {        
        // Make sure the attacker doesn't get extra credit for doing more 
        // damage than was done by the killing shot
        if (damage > g_RoundHealth[victim]) {
            g_RoundPoints[attacker] += g_RoundHealth[victim];
        } else {
            g_RoundPoints[attacker] += damage;
            
        }
    }

    // If the victim is valid then you should always
    // detract their HP.
    if (validVictim) {
        if (damage > g_RoundHealth[victim]) {
            g_RoundHealth[victim] = 0;
        } else {
            g_RoundHealth[victim] -= damage;
        }
    }
}

public bool HelpfulAttack(int attacker, int victim) {
    if (!IsValidClient(attacker) || !IsValidClient(victim)) {
        return false;
    }
    int ateam = GetClientTeam(attacker);
    int vteam = GetClientTeam(victim);
    return ateam != vteam && attacker != victim;
}

/**
 * Round end event, updates rws values for everyone.
 */
public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (!IsMatchLive() || g_RecordRWSCvar.IntValue == 0)
        return;

    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i) && HasStats(i)) {
            int team = GetClientTeam(i);
            if (team == CS_TEAM_CT || team == CS_TEAM_T)
                RWSUpdate(i);
                RatingUpdate(i);
        }
    }

}

/**
 * Round start event, reset round based values for everyone
 */
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    if (!IsMatchLive() || g_RecordRWSCvar.IntValue == 0)
        return;

    // Should do calculations here

    // Reset the stats
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i) && HasStats(i)) {
            // Reset the round points for the next round
            g_RoundPoints[i] = 0;

            // Reset the health for the next round
            g_RoundHealth[i] = 100;

            // Rest the kills and the round survived var
            g_RoundKills[i] = 0;
            g_RoundSurvived[i] = 1;
        }
    }
}

/**
 * Here we apply magic updates to a player's rws based on the previous round.
 */
static void RWSUpdate(int client) {
    float rws = 0.0;
    int playerCount = 0;
    int sum = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i)) {
            sum += g_RoundPoints[i];
            playerCount++;
        }
    }

    if (sum != 0) {
        // scaled so it's always considered "out of 5 players" so different team sizes
        // don't give inflated rws
        rws = 100.0 * float(playerCount) / 10.0 * float(g_RoundPoints[client]) / float(sum);

        
    } else {
        return;
    }

    float alpha = GetAlphaFactor(client);
    g_PlayerRWS[client] = (1.0 - alpha) * g_PlayerRWS[client] + alpha * rws;
    g_PlayerRounds[client]++;

    float periodAlpha = GetPeriodAlphaFactor(client);
    g_PlayerPeriodRWS[client] = (1.0 - periodAlpha) * g_PlayerPeriodRWS[client] + periodAlpha * rws;
    g_PlayerPeriodRounds[client]++;
    
    LogDebug("RoundUpdate(%L), alpha=%f, round_points=%i, round_rws=%f, new_rws=%f", client, alpha, g_RoundPoints[client], rws, g_PlayerRWS[client]);
    LogDebug("RoundUpdate(%L), alpha=%f, round_points=%i, round_rws=%f, new_period_rws=%f", client, alpha, g_RoundPoints[client], rws, g_PlayerPeriodRWS[client]);
}

static void RatingUpdate(int client) {
    float AverageKPR = 0.679; // (average kills per round)
    float AverageSPR = 0.317; // (average survived rounds per round)
    float AverageRMK = 1.277; // (average value calculated from rounds with multiple kills: (1K + 4*2K + 9*3K + 16*4K + 25*5K)/Rounds) 

    g_PlayerRatingTotalRounds[i]++;

    g_PlayerRatingKills[i] +=  g_RoundKills[i];
    g_PlayerRatingRoundsSurvived[i] +=  g_RoundSurvived[i];
    g_PlayerRatingMultiKillValue[i] +=  g_RoundKills[i] * g_RoundKills[i];

    float killRating = g_PlayerRatingKills[i] / g_PlayerRatingTotalRounds[i] / AverageKPR;
    float survivalRating = g_PlayerRatingRoundsSurvived[i] / g_PlayerRatingTotalRounds[i] / AverageSPR;
    float multiKillRating = g_PlayerRatingMultiKillValue[i]  / g_PlayerRatingTotalRounds[i] / AverageRMK;

    g_PlayerRating[i] = (killRating = 0.7*survivalRating + multiKillRating) / 2.7;

}

static float GetAlphaFactor(int client) {
    float rounds = float(g_PlayerRounds[client]);
    if (rounds < ROUNDS_FINAL) {
        return ALPHA_INIT + (ALPHA_INIT - ALPHA_FINAL) / (-ROUNDS_FINAL) * rounds;
    } else {
        return ALPHA_FINAL;
    }
}

static float GetPeriodAlphaFactor(int client) {
    float rounds = float(g_PlayerPeriodRounds[client]);
    if (rounds < ROUNDS_FINAL) {
        return ALPHA_INIT + (ALPHA_INIT - ALPHA_FINAL) / (-ROUNDS_FINAL) * rounds;
    } else {
        return ALPHA_FINAL;
    }
}

public int rwsSortFunction(int index1, int index2, Handle array, Handle hndl) {
    int client1 = GetArrayCell(array, index1);
    int client2 = GetArrayCell(array, index2);
    return g_PlayerRWS[client1] < g_PlayerRWS[client2];
}

public void OnReadyToStartCheck(int readyPlayers, int totalPlayers) {
    if (!g_ManuallySetCaptains &&
        g_SetCaptainsByRWSCvar.IntValue != 0 &&
        totalPlayers >= GetPugMaxPlayers() &&
        GetTeamType() == TeamType_Captains) {

        // The idea is to set the captains to the 2 highest rws players,
        // so they are thrown into an array and sorted by rws,
        // then the captains are set to the first 2 elements of the array.

        ArrayList players = new ArrayList();

        for (int i = 1; i <= MaxClients; i++) {
            if (IsPlayer(i))
                PushArrayCell(players, i);
        }

        SortADTArrayCustom(players, rwsSortFunction);

        if (players.Length >= 1)
            SetCaptain(1, GetArrayCell(players, 0));

        if (players.Length >= 2)
            SetCaptain(2, GetArrayCell(players, 1));

        delete players;
    }
}

public Action Command_DumpRWS(int client, int args) {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i) && HasStats(i)) {
            ReplyToCommand(client, "%L has RWS=%f, roundsplayed=%d", i, g_PlayerRWS[i], g_PlayerRounds[i]);
        }
    }

    return Plugin_Handled;
}

public Action Command_RWS(int client, int args) {
    if (g_AllowRWSCommandCvar.IntValue == 0) {
        return Plugin_Handled;
    }

    char arg1[32];
    if (args >= 1 && GetCmdArg(1, arg1, sizeof(arg1))) {
        int target = FindTarget(client, arg1, true, false);
        if (target != -1) {
            if (HasStats(target))
                PugSetupMessage(client, "%N has a RWS of %.1f with %d rounds played",
                              target, g_PlayerRWS[target], g_PlayerRounds[target]);
            else
                PugSetupMessage(client, "%N does not currently have stats stored", target);
        }
    } else {
        PugSetupMessage(client, "Usage: .trws <player>");
    }

    return Plugin_Handled;
}

public Action Command_PeriodRWS(int client, int args) {
    if (g_AllowRWSCommandCvar.IntValue == 0) {
        return Plugin_Handled;
    }

    char arg1[32];
    if (args >= 1 && GetCmdArg(1, arg1, sizeof(arg1))) {
        int target = FindTarget(client, arg1, true, false);
        if (target != -1) {
            if (HasStats(target))
                PugSetupMessage(client, "%N has a RWS of %.1f with %d rounds played over the current period",
                              target, g_PlayerPeriodRWS[target], g_PlayerPeriodRounds[target]);
            else
                PugSetupMessage(client, "%N does not currently have stats stored", target);
        }
    } else {
        PugSetupMessage(client, "Usage: .rws <player>");
    }

    return Plugin_Handled;
}

public Action Command_Rating(int client, int args) {
    if (g_AllowRWSCommandCvar.IntValue == 0) {
        return Plugin_Handled;
    }

    char arg1[32];
    if (args >= 1 && GetCmdArg(1, arg1, sizeof(arg1))) {
        int target = FindTarget(client, arg1, true, false);
        if (target != -1) {
            if (HasStats(target))
                PugSetupMessage(client, "%N has a rating of %.1f with %d rounds played",
                              target, g_PlayerRating[target], g_PlayerRatingTotalRounds[target]);
            else
                PugSetupMessage(client, "%N does not currently have stats stored", target);
        }
    } else {
        PugSetupMessage(client, "Usage: .rating <player>");
    }

    return Plugin_Handled;
}

public void OnPlayerAddedToCaptainMenu(Menu menu, int client, char[] menuString, int length) {
    if (g_ShowRWSOnMenuCvar.IntValue != 0 && HasStats(client)) {
        Format(menuString, length, "%N [%.1f RWS]", client, g_PlayerPeriodRWS[client]);
    }
}