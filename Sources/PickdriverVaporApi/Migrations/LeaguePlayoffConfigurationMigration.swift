import Fluent
import SQLKit
import Vapor

/// Adds the durable league-level configuration and schedule anchor for playoffs.
///
/// `playoff_schedule_anchor_round` is deliberately separate from the mutable
/// season calendar. It records the first race the league could draft, so a
/// league started partway through a season never counts earlier races.
struct AddLeaguePlayoffConfiguration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw("""
            ALTER TABLE public.leagues
            ADD COLUMN playoffs_enabled boolean DEFAULT false NOT NULL
        """).run()
        try await sql.raw("""
            ALTER TABLE public.leagues
            ADD COLUMN playoff_schedule_anchor_round integer
        """).run()
        try await sql.raw("""
            ALTER TABLE public.leagues
            ADD COLUMN playoff_schedule_anchor_at timestamp without time zone
        """).run()

        // Existing active leagues already have the start of their effective
        // calendar recorded. Preserve that boundary without inventing an
        // activation timestamp that cannot be reconstructed reliably.
        try await sql.raw("""
            UPDATE public.leagues
            SET playoff_schedule_anchor_round = initial_race_round
            WHERE initial_race_round IS NOT NULL
        """).run()

        // A persisted bracket is already authoritative. Keep it enabled when
        // migrating an installation that had the previous automatic behavior.
        try await sql.raw("""
            UPDATE public.leagues AS l
            SET playoffs_enabled = true
            WHERE EXISTS (
                SELECT 1
                FROM public.league_playoffs AS lp
                WHERE lp.league_id = l.id
            )
        """).run()

        try await sql.raw("""
            CREATE INDEX idx_leagues_playoffs_enabled
            ON public.leagues USING btree (playoffs_enabled)
            WHERE playoffs_enabled = true
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw("DROP INDEX IF EXISTS public.idx_leagues_playoffs_enabled").run()
        try await sql.raw("ALTER TABLE public.leagues DROP COLUMN IF EXISTS playoff_schedule_anchor_at").run()
        try await sql.raw("ALTER TABLE public.leagues DROP COLUMN IF EXISTS playoff_schedule_anchor_round").run()
        try await sql.raw("ALTER TABLE public.leagues DROP COLUMN IF EXISTS playoffs_enabled").run()
    }
}
