import Fluent
import SQLKit
import Vapor

private func requirePickDriverV2SQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? (any SQLDatabase) else {
        throw Abort(.internalServerError, reason: "PickDriver V2 migrations require PostgreSQL.")
    }
    return sql
}

private extension SQLDatabase {
    func v2Exec(_ statement: String) async throws {
        try await raw(SQLQueryString(statement)).run()
    }
}

struct AddPickDriverV2DraftState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try requirePickDriverV2SQL(database)

        try await sql.v2Exec(#"""
        ALTER TABLE public.race_drafts
            ADD COLUMN IF NOT EXISTS gameplay_version character varying(16) DEFAULT 'legacy' NOT NULL,
            ADD COLUMN IF NOT EXISTS resolution_state character varying(24) DEFAULT 'legacy' NOT NULL,
            ADD COLUMN IF NOT EXISTS resolved_at timestamp without time zone,
            ADD COLUMN IF NOT EXISTS resolution_revision integer DEFAULT 0 NOT NULL
        """#)

        try await sql.v2Exec(#"""
        ALTER TABLE public.race_drafts
            DROP CONSTRAINT IF EXISTS race_drafts_gameplay_version_check
        """#)
        try await sql.v2Exec(#"""
        ALTER TABLE public.race_drafts
            ADD CONSTRAINT race_drafts_gameplay_version_check
            CHECK (gameplay_version IN ('legacy', 'v2'))
        """#)
        try await sql.v2Exec(#"""
        ALTER TABLE public.race_drafts
            DROP CONSTRAINT IF EXISTS race_drafts_resolution_state_check
        """#)
        try await sql.v2Exec(#"""
        ALTER TABLE public.race_drafts
            ADD CONSTRAINT race_drafts_resolution_state_check
            CHECK (resolution_state IN ('legacy', 'collecting', 'resolved', 'finalized', 'cancelled'))
        """#)

        try await sql.v2Exec(#"""
        UPDATE public.race_drafts rd
        SET gameplay_version = 'v2',
            resolution_state = CASE
                WHEN rd.status = 'cancelled' THEN 'cancelled'
                ELSE 'collecting'
            END,
            resolution_revision = 0,
            resolved_at = NULL
        FROM public.races r
        WHERE r.id = rd.race_id
          AND (r.season_id > 2 OR (r.season_id = 2 AND r.round >= 14))
          AND r.completed = false
        """#)

        // Any turn-based activity already submitted for the cutover race is intentionally
        // ignored. V2 will create its definitive 100%-scoring picks from resolved slots at FP1.
        try await sql.v2Exec(#"""
        DELETE FROM public.player_bans pb
        USING public.race_drafts rd
        WHERE pb.draft_id = rd.id
          AND rd.gameplay_version = 'v2'
          AND rd.resolution_state = 'collecting'
        """#)
        try await sql.v2Exec(#"""
        DELETE FROM public.player_picks pp
        USING public.race_drafts rd
        WHERE pp.draft_id = rd.id
          AND rd.gameplay_version = 'v2'
          AND rd.resolution_state = 'collecting'
        """#)

        try await sql.v2Exec(#"""
        CREATE INDEX IF NOT EXISTS idx_race_drafts_gameplay_resolution
        ON public.race_drafts (gameplay_version, resolution_state, race_id)
        """#)
    }

    func revert(on database: any Database) async throws {
        let sql = try requirePickDriverV2SQL(database)
        try await sql.v2Exec("DROP INDEX IF EXISTS public.idx_race_drafts_gameplay_resolution")
        try await sql.v2Exec(#"""
        ALTER TABLE public.race_drafts
            DROP CONSTRAINT IF EXISTS race_drafts_resolution_state_check,
            DROP CONSTRAINT IF EXISTS race_drafts_gameplay_version_check,
            DROP COLUMN IF EXISTS resolution_revision,
            DROP COLUMN IF EXISTS resolved_at,
            DROP COLUMN IF EXISTS resolution_state,
            DROP COLUMN IF EXISTS gameplay_version
        """#)
    }
}

struct CreatePickDriverV2Tables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try requirePickDriverV2SQL(database)

        try await sql.v2Exec(#"""
        CREATE TABLE IF NOT EXISTS public.player_pick_preferences (
            id SERIAL PRIMARY KEY,
            league_id integer NOT NULL REFERENCES public.leagues(id) ON DELETE CASCADE,
            user_id integer NOT NULL REFERENCES public.users(id),
            driver_order integer[] DEFAULT '{}'::integer[] NOT NULL,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            updated_at timestamp without time zone DEFAULT now() NOT NULL,
            CONSTRAINT player_pick_preferences_league_user_key UNIQUE (league_id, user_id)
        )
        """#)

        try await sql.v2Exec(#"""
        CREATE TABLE IF NOT EXISTS public.draft_pick_preference_snapshots (
            id SERIAL PRIMARY KEY,
            draft_id integer NOT NULL REFERENCES public.race_drafts(id) ON DELETE CASCADE,
            user_id integer NOT NULL REFERENCES public.users(id),
            driver_order integer[] DEFAULT '{}'::integer[] NOT NULL,
            captured_at timestamp without time zone DEFAULT now() NOT NULL,
            CONSTRAINT draft_pick_preference_snapshots_draft_user_key UNIQUE (draft_id, user_id)
        )
        """#)

        try await sql.v2Exec(#"""
        CREATE TABLE IF NOT EXISTS public.v2_draft_slots (
            id SERIAL PRIMARY KEY,
            draft_id integer NOT NULL REFERENCES public.race_drafts(id) ON DELETE CASCADE,
            pick_index integer NOT NULL,
            user_id integer NOT NULL REFERENCES public.users(id),
            driver_id integer REFERENCES public.drivers(id),
            is_mirror_pick boolean DEFAULT false NOT NULL,
            resolution_revision integer DEFAULT 1 NOT NULL,
            updated_at timestamp without time zone DEFAULT now() NOT NULL,
            CONSTRAINT v2_draft_slots_draft_pick_index_key UNIQUE (draft_id, pick_index),
            CONSTRAINT v2_draft_slots_pick_index_check CHECK (pick_index >= 0)
        )
        """#)
        try await sql.v2Exec(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS v2_draft_slots_unique_driver
        ON public.v2_draft_slots (draft_id, driver_id)
        WHERE driver_id IS NOT NULL
        """#)

        try await sql.v2Exec(#"""
        CREATE TABLE IF NOT EXISTS public.v2_draft_bans (
            id SERIAL PRIMARY KEY,
            draft_id integer NOT NULL REFERENCES public.race_drafts(id) ON DELETE CASCADE,
            actor_user_id integer NOT NULL REFERENCES public.users(id),
            actor_team_id integer REFERENCES public.league_teams(id),
            target_user_id integer NOT NULL REFERENCES public.users(id),
            target_driver_id integer NOT NULL REFERENCES public.drivers(id),
            target_pick_index integer NOT NULL,
            resolution_revision integer NOT NULL,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            CONSTRAINT v2_draft_bans_not_self CHECK (actor_user_id <> target_user_id),
            CONSTRAINT v2_draft_bans_target_once UNIQUE (draft_id, target_user_id)
        )
        """#)
        try await sql.v2Exec(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS v2_draft_bans_actor_once
        ON public.v2_draft_bans (draft_id, actor_user_id)
        WHERE actor_team_id IS NULL
        """#)
        try await sql.v2Exec(#"""
        CREATE UNIQUE INDEX IF NOT EXISTS v2_draft_bans_team_once
        ON public.v2_draft_bans (draft_id, actor_team_id)
        WHERE actor_team_id IS NOT NULL
        """#)

        try await sql.v2Exec("CREATE INDEX IF NOT EXISTS idx_v2_draft_bans_actor_user ON public.v2_draft_bans (actor_user_id)")
        try await sql.v2Exec("CREATE INDEX IF NOT EXISTS idx_v2_draft_bans_actor_team ON public.v2_draft_bans (actor_team_id)")
        try await sql.v2Exec("CREATE INDEX IF NOT EXISTS idx_v2_draft_slots_draft ON public.v2_draft_slots (draft_id)")
    }

    func revert(on database: any Database) async throws {
        let sql = try requirePickDriverV2SQL(database)
        try await sql.v2Exec("DROP TABLE IF EXISTS public.v2_draft_bans")
        try await sql.v2Exec("DROP TABLE IF EXISTS public.v2_draft_slots")
        try await sql.v2Exec("DROP TABLE IF EXISTS public.draft_pick_preference_snapshots")
        try await sql.v2Exec("DROP TABLE IF EXISTS public.player_pick_preferences")
    }
}
