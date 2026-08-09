import Fluent
import SQLKit
import Vapor

struct CreateLeaguePlayoffs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw(#"""
        CREATE TABLE public.league_playoffs (
            id SERIAL PRIMARY KEY,
            league_id integer NOT NULL,
            regular_race_count integer NOT NULL,
            first_race_id integer NOT NULL,
            playoff_race_ids integer[] DEFAULT '{}'::integer[] NOT NULL,
            selection_deadline timestamp without time zone NOT NULL,
            seed_order integer[] DEFAULT '{}'::integer[] NOT NULL,
            top_group_size integer NOT NULL,
            first_pick_order integer[] DEFAULT '{}'::integer[] NOT NULL,
            status character varying(20) DEFAULT 'selecting'::character varying NOT NULL,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            updated_at timestamp without time zone DEFAULT now() NOT NULL,
            CONSTRAINT league_playoffs_league_id_key UNIQUE (league_id),
            CONSTRAINT league_playoffs_league_id_fkey FOREIGN KEY (league_id) REFERENCES public.leagues(id) ON DELETE CASCADE,
            CONSTRAINT league_playoffs_first_race_id_fkey FOREIGN KEY (first_race_id) REFERENCES public.races(id),
            CONSTRAINT league_playoffs_status_check CHECK (status IN ('selecting', 'finalized')),
            CONSTRAINT league_playoffs_regular_race_count_check CHECK (regular_race_count >= 0),
            CONSTRAINT league_playoffs_top_group_size_check CHECK (top_group_size > 0)
        )
        """#).run()

        try await sql.raw(#"""
        CREATE TABLE public.league_playoff_pick_selections (
            id SERIAL PRIMARY KEY,
            playoff_id integer NOT NULL,
            user_id integer NOT NULL,
            selection_rank integer NOT NULL,
            pick_position integer,
            selected_at timestamp without time zone,
            CONSTRAINT league_playoff_pick_selections_playoff_id_fkey FOREIGN KEY (playoff_id) REFERENCES public.league_playoffs(id) ON DELETE CASCADE,
            CONSTRAINT league_playoff_pick_selections_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id),
            CONSTRAINT league_playoff_pick_selections_playoff_user_key UNIQUE (playoff_id, user_id),
            CONSTRAINT league_playoff_pick_selections_playoff_rank_key UNIQUE (playoff_id, selection_rank),
            CONSTRAINT league_playoff_pick_selections_playoff_position_key UNIQUE (playoff_id, pick_position),
            CONSTRAINT league_playoff_pick_selections_rank_check CHECK (selection_rank >= 0),
            CONSTRAINT league_playoff_pick_selections_position_check CHECK (pick_position IS NULL OR pick_position > 0)
        )
        """#).run()

        try await sql.raw("CREATE INDEX idx_league_playoff_pick_selections_playoff_id ON public.league_playoff_pick_selections USING btree (playoff_id)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw("DROP TABLE IF EXISTS public.league_playoff_pick_selections").run()
        try await sql.raw("DROP TABLE IF EXISTS public.league_playoffs").run()
    }
}
