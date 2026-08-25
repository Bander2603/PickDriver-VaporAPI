import Fluent
import SQLKit
import Vapor

struct AddRaceDriverSubstitutions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "Race substitution migrations require PostgreSQL.")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS public.race_driver_entries (
                id SERIAL PRIMARY KEY,
                race_id integer NOT NULL REFERENCES public.races(id) ON DELETE CASCADE,
                driver_id integer NOT NULL REFERENCES public.drivers(id),
                f1_team_id integer NOT NULL REFERENCES public.f1_teams(id),
                status character varying(20) NOT NULL,
                created_at timestamp without time zone DEFAULT now() NOT NULL,
                updated_at timestamp without time zone DEFAULT now() NOT NULL,
                CONSTRAINT race_driver_entries_race_driver_key UNIQUE (race_id, driver_id),
                CONSTRAINT race_driver_entries_status_check
                    CHECK (status IN ('entered', 'withdrawn', 'reserve'))
            )
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_race_driver_entries_race_status
            ON public.race_driver_entries (race_id, status)
        """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS public.race_driver_substitutions (
                id SERIAL PRIMARY KEY,
                race_id integer NOT NULL REFERENCES public.races(id) ON DELETE CASCADE,
                outgoing_driver_id integer NOT NULL REFERENCES public.drivers(id),
                incoming_driver_id integer NOT NULL REFERENCES public.drivers(id),
                f1_team_id integer NOT NULL REFERENCES public.f1_teams(id),
                announced_at timestamp without time zone,
                created_at timestamp without time zone DEFAULT now() NOT NULL,
                CONSTRAINT race_driver_substitutions_outgoing_key
                    UNIQUE (race_id, outgoing_driver_id),
                CONSTRAINT race_driver_substitutions_incoming_key
                    UNIQUE (race_id, incoming_driver_id),
                CONSTRAINT race_driver_substitutions_distinct_driver_check
                    CHECK (outgoing_driver_id <> incoming_driver_id)
            )
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_race_driver_substitutions_race
            ON public.race_driver_substitutions (race_id)
        """).run()

        try await sql.raw("""
            ALTER TABLE public.v2_draft_slots
                ADD COLUMN IF NOT EXISTS original_driver_id integer
                    REFERENCES public.drivers(id),
                ADD COLUMN IF NOT EXISTS substitution_revision integer DEFAULT 0 NOT NULL
        """).run()

        try await sql.raw("""
            ALTER TABLE public.player_picks
                ADD COLUMN IF NOT EXISTS original_driver_id integer
                    REFERENCES public.drivers(id),
                ADD COLUMN IF NOT EXISTS substitution_revision integer DEFAULT 0 NOT NULL
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_v2_draft_slots_original_driver
            ON public.v2_draft_slots (original_driver_id)
            WHERE original_driver_id IS NOT NULL
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_player_picks_original_driver
            ON public.player_picks (original_driver_id)
            WHERE original_driver_id IS NOT NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "Race substitution migrations require PostgreSQL.")
        }

        try await sql.raw("DROP INDEX IF EXISTS public.idx_player_picks_original_driver").run()
        try await sql.raw("DROP INDEX IF EXISTS public.idx_v2_draft_slots_original_driver").run()
        try await sql.raw("""
            ALTER TABLE public.player_picks
                DROP COLUMN IF EXISTS substitution_revision,
                DROP COLUMN IF EXISTS original_driver_id
        """).run()
        try await sql.raw("""
            ALTER TABLE public.v2_draft_slots
                DROP COLUMN IF EXISTS substitution_revision,
                DROP COLUMN IF EXISTS original_driver_id
        """).run()
        try await sql.raw("DROP TABLE IF EXISTS public.race_driver_substitutions").run()
        try await sql.raw("DROP TABLE IF EXISTS public.race_driver_entries").run()
    }
}
