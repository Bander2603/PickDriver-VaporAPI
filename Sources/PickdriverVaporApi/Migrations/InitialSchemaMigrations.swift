//
//  InitialSchemaMigrations.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 09.01.26.
//

import Fluent
import SQLKit
import Vapor

// MARK: - Helpers

private extension Database {
    func sql() throws -> any SQLDatabase {
        guard let sql = self as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }
        return sql
    }
}

private extension SQLDatabase {
    func exec(_ statement: String) async throws {
        try await self.raw(SQLQueryString(statement)).run()
    }
}

// MARK: - Extensions (pg_trgm)

struct CreatePgTrgmExtension: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    }

    func revert(on database: any Database) async throws {
        // Safer as no-op (dropping may fail if other objects depend on it in partial reverts)
    }
}

// MARK: - seasons

struct CreateSeasons: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.seasons (
            id SERIAL PRIMARY KEY,
            year integer NOT NULL,
            name character varying(50) NOT NULL,
            active boolean DEFAULT true NOT NULL,
            CONSTRAINT seasons_year_key UNIQUE (year)
        )
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.seasons")
    }
}

// MARK: - users

struct CreateUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.users (
            id SERIAL PRIMARY KEY,
            firebase_uid character varying(128),
            username character varying(50) NOT NULL,
            email character varying(100) NOT NULL,
            password_hash character varying(256),
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            CONSTRAINT users_email_key UNIQUE (email),
            CONSTRAINT users_firebase_uid_key UNIQUE (firebase_uid)
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_users_email ON public.users USING btree (email)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_users_username ON public.users USING btree (username)")

        // Trigram
        try await sql.exec("CREATE INDEX IF NOT EXISTS trgm_idx_username ON public.users USING gin (username public.gin_trgm_ops)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.users")
    }
}

// MARK: - f1_teams

struct CreateF1Teams: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.f1_teams (
            id SERIAL PRIMARY KEY,
            season_id integer NOT NULL,
            name character varying(100) NOT NULL,
            color character varying(20) NOT NULL,
            CONSTRAINT f1_teams_season_id_name_key UNIQUE (season_id, name),
            CONSTRAINT f1_teams_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.seasons(id)
        )
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.f1_teams")
    }
}

// MARK: - drivers

struct CreateDrivers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.drivers (
            id SERIAL PRIMARY KEY,
            season_id integer NOT NULL,
            f1_team_id integer NOT NULL,
            first_name character varying(50) NOT NULL,
            last_name character varying(50) NOT NULL,
            country character varying(50) NOT NULL,
            driver_number integer NOT NULL,
            active boolean DEFAULT true,
            driver_code character varying(3) DEFAULT 'TBD'::character varying NOT NULL,
            CONSTRAINT drivers_season_id_driver_number_key UNIQUE (season_id, driver_number),
            CONSTRAINT unique_driver_code UNIQUE (driver_code, season_id),
            CONSTRAINT drivers_f1_team_id_fkey FOREIGN KEY (f1_team_id) REFERENCES public.f1_teams(id),
            CONSTRAINT drivers_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.seasons(id)
        )
        """#)

        // Trigram
        try await sql.exec("CREATE INDEX IF NOT EXISTS trgm_idx_driver_name ON public.drivers USING gin (last_name public.gin_trgm_ops)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.drivers")
    }
}

// MARK: - races

struct CreateRaces: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.races (
            id SERIAL PRIMARY KEY,
            season_id integer NOT NULL,
            round integer NOT NULL,
            name character varying(100) NOT NULL,
            circuit_name character varying(100) NOT NULL,
            circuit_data jsonb DEFAULT '{}'::jsonb NOT NULL,
            country character varying(50) NOT NULL,
            country_code character varying(2) NOT NULL,
            sprint boolean DEFAULT false NOT NULL,
            completed boolean DEFAULT false NOT NULL,
            fp1_time timestamp without time zone,
            fp2_time timestamp without time zone,
            fp3_time timestamp without time zone,
            qualifying_time timestamp without time zone,
            sprint_time timestamp without time zone,
            race_time timestamp without time zone,
            sprint_qualifying_time timestamp without time zone,
            CONSTRAINT races_season_id_round_key UNIQUE (season_id, round),
            CONSTRAINT races_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.seasons(id)
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_races_completed_round ON public.races USING btree (completed, round)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_races_season_completed ON public.races USING btree (season_id, completed)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.races")
    }
}

// MARK: - leagues

struct CreateLeagues: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.leagues (
            id SERIAL PRIMARY KEY,
            name character varying(100) NOT NULL,
            owner_id integer NOT NULL,
            max_players integer DEFAULT 20 NOT NULL,
            teams_enabled boolean DEFAULT false NOT NULL,
            bans_enabled boolean DEFAULT false NOT NULL,
            mirror_picks_enabled boolean DEFAULT false NOT NULL,
            invite_code character varying(10) NOT NULL,
            status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            teams_assigned boolean DEFAULT false NOT NULL,
            initial_race_round integer,
            season_id integer NOT NULL,
            CONSTRAINT leagues_invite_code_key UNIQUE (invite_code),
            CONSTRAINT leagues_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id),
            CONSTRAINT leagues_season_id_fkey FOREIGN KEY (season_id) REFERENCES public.seasons(id)
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_leagues_invite_code ON public.leagues USING btree (invite_code)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_leagues_owner_id ON public.leagues USING btree (owner_id)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_leagues_season_id ON public.leagues USING btree (season_id)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_leagues_status ON public.leagues USING btree (status)")

        // Trigram
        try await sql.exec("CREATE INDEX IF NOT EXISTS trgm_idx_league_name ON public.leagues USING gin (name public.gin_trgm_ops)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.leagues")
    }
}

// MARK: - league_members

struct CreateLeagueMembers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.league_members (
            league_id integer NOT NULL,
            user_id integer NOT NULL,
            pick_order integer,
            joined_at timestamp without time zone DEFAULT now() NOT NULL,
            id SERIAL PRIMARY KEY,
            CONSTRAINT league_members_league_id_fkey FOREIGN KEY (league_id) REFERENCES public.leagues(id) ON DELETE CASCADE,
            CONSTRAINT league_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_league_members_league_user ON public.league_members USING btree (league_id, user_id)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_league_members_user_id ON public.league_members USING btree (user_id)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.league_members")
    }
}

// MARK: - league_teams

struct CreateLeagueTeams: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.league_teams (
            id SERIAL PRIMARY KEY,
            league_id integer NOT NULL,
            name character varying(100) NOT NULL,
            bans_remaining integer DEFAULT 3 NOT NULL,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            min_size integer DEFAULT 2,
            max_size integer DEFAULT 2,
            CONSTRAINT league_teams_league_id_fkey FOREIGN KEY (league_id) REFERENCES public.leagues(id) ON DELETE CASCADE
        )
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.league_teams")
    }
}

// MARK: - team_members

struct CreateTeamMembers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.team_members (
            team_id integer NOT NULL,
            user_id integer NOT NULL,
            id SERIAL PRIMARY KEY,
            CONSTRAINT team_members_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.league_teams(id) ON DELETE CASCADE,
            CONSTRAINT team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE
        )
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.team_members")
    }
}

// MARK: - race_drafts

struct CreateRaceDrafts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.race_drafts (
            id SERIAL PRIMARY KEY,
            league_id integer NOT NULL,
            race_id integer NOT NULL,
            current_pick_index integer DEFAULT 0 NOT NULL,
            mirror_picks boolean DEFAULT false NOT NULL,
            status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            updated_at timestamp without time zone DEFAULT now() NOT NULL,
            pick_order integer[] DEFAULT '{}'::integer[] NOT NULL,
            CONSTRAINT race_drafts_league_id_race_id_key UNIQUE (league_id, race_id),
            CONSTRAINT race_drafts_league_id_fkey FOREIGN KEY (league_id) REFERENCES public.leagues(id) ON DELETE CASCADE,
            CONSTRAINT race_drafts_race_id_fkey FOREIGN KEY (race_id) REFERENCES public.races(id) ON DELETE CASCADE
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_race_drafts_league_status ON public.race_drafts USING btree (league_id, status)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.race_drafts")
    }
}

// MARK: - player_picks

struct CreatePlayerPicks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.player_picks (
            id SERIAL PRIMARY KEY,
            draft_id integer NOT NULL,
            user_id integer NOT NULL,
            driver_id integer NOT NULL,
            is_mirror_pick boolean DEFAULT false NOT NULL,
            picked_at timestamp without time zone DEFAULT now() NOT NULL,
            is_banned boolean DEFAULT false NOT NULL,
            banned_by integer,
            banned_at timestamp without time zone,
            CONSTRAINT player_picks_draft_id_fkey FOREIGN KEY (draft_id) REFERENCES public.race_drafts(id) ON DELETE CASCADE,
            CONSTRAINT player_picks_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id),
            CONSTRAINT player_picks_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.drivers(id),
            CONSTRAINT player_picks_banned_by_fkey FOREIGN KEY (banned_by) REFERENCES public.users(id)
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_player_picks_banned ON public.player_picks USING btree (is_banned)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_player_picks_draft_id ON public.player_picks USING btree (draft_id)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_player_picks_driver ON public.player_picks USING btree (driver_id)")

        // Unique partial index: only one valid (non-banned) pick per (draft, user, mirror flag)
        try await sql.exec(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS unique_valid_pick
        ON public.player_picks USING btree (draft_id, user_id, is_mirror_pick)
        WHERE (is_banned = false)
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.player_picks")
    }
}

// MARK: - unique driver picks per draft

struct AddUniqueDriverPickPerDraft: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS unique_driver_pick_per_draft
        ON public.player_picks USING btree (draft_id, driver_id)
        WHERE (is_banned = false)
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP INDEX IF EXISTS public.unique_driver_pick_per_draft")
    }
}

// MARK: - player_bans

struct CreatePlayerBans: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.player_bans (
            draft_id integer NOT NULL,
            user_id integer,
            bans_remaining integer DEFAULT 2 NOT NULL,
            team_id integer,
            is_team_scope boolean DEFAULT false NOT NULL,
            CONSTRAINT player_bans_draft_id_fkey FOREIGN KEY (draft_id) REFERENCES public.race_drafts(id) ON DELETE CASCADE,
            CONSTRAINT player_bans_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
        )
        """#)

        // Partial unique indexes
        try await sql.exec(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_player_bans_solo
        ON public.player_bans USING btree (draft_id, user_id)
        WHERE (is_team_scope = false)
        """#)

        try await sql.exec(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_player_bans_team
        ON public.player_bans USING btree (draft_id, team_id)
        WHERE (is_team_scope = true)
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.player_bans")
    }
}

// MARK: - race_results

struct CreateRaceResults: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()

        try await sql.exec(#"""
        CREATE TABLE public.race_results (
            id SERIAL PRIMARY KEY,
            race_id integer NOT NULL,
            driver_id integer NOT NULL,
            "position" integer,
            points integer DEFAULT 0 NOT NULL,
            fastest_lap boolean DEFAULT false NOT NULL,
            status character varying(20) DEFAULT 'FINISHED'::character varying NOT NULL,
            f1_team_id integer,
            sprint_points integer,
            CONSTRAINT race_results_race_id_driver_id_key UNIQUE (race_id, driver_id),
            CONSTRAINT race_results_race_id_fkey FOREIGN KEY (race_id) REFERENCES public.races(id) ON DELETE CASCADE,
            CONSTRAINT race_results_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.drivers(id),
            CONSTRAINT race_results_f1_team_id_fkey FOREIGN KEY (f1_team_id) REFERENCES public.f1_teams(id)
        )
        """#)

        try await sql.exec(#"""
        CREATE INDEX IF NOT EXISTS idx_race_results_points
        ON public.race_results USING btree (race_id, points DESC)
        """#)

        try await sql.exec(#"""
        CREATE INDEX IF NOT EXISTS idx_race_results_position
        ON public.race_results USING btree (race_id, "position")
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.race_results")
    }
}

// MARK: - maintenance_stats

struct CreateMaintenanceStats: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.maintenance_stats (
            id SERIAL PRIMARY KEY,
            "timestamp" timestamp without time zone DEFAULT now(),
            database_size_bytes bigint,
            largest_table text,
            largest_table_size_bytes bigint,
            vacuum_duration_seconds integer,
            tables_analyzed integer,
            indexes_rebuilt integer,
            bloat_percentage numeric(5,2)
        )
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.maintenance_stats")
    }
}
