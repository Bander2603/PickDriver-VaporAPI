//
//  NotificationMigrations.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 20.01.26.
//

import Fluent
import SQLKit
import Vapor

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

// MARK: - push_tokens

struct CreatePushTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.push_tokens (
            id SERIAL PRIMARY KEY,
            user_id integer NOT NULL,
            token character varying(256) NOT NULL,
            platform character varying(20) NOT NULL,
            device_id character varying(64),
            is_active boolean DEFAULT true NOT NULL,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            updated_at timestamp without time zone DEFAULT now() NOT NULL,
            last_seen_at timestamp without time zone,
            CONSTRAINT push_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
            CONSTRAINT push_tokens_token_key UNIQUE (token)
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_push_tokens_user_id ON public.push_tokens USING btree (user_id)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.push_tokens")
    }
}

// MARK: - push_notifications

struct CreatePushNotifications: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.push_notifications (
            id SERIAL PRIMARY KEY,
            user_id integer NOT NULL,
            type character varying(50) NOT NULL,
            title character varying(120) NOT NULL,
            body text NOT NULL,
            data jsonb,
            league_id integer,
            race_id integer,
            created_at timestamp without time zone DEFAULT now() NOT NULL,
            read_at timestamp without time zone,
            delivered_at timestamp without time zone,
            CONSTRAINT push_notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE,
            CONSTRAINT push_notifications_league_id_fkey FOREIGN KEY (league_id) REFERENCES public.leagues(id) ON DELETE SET NULL,
            CONSTRAINT push_notifications_race_id_fkey FOREIGN KEY (race_id) REFERENCES public.races(id) ON DELETE SET NULL
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_push_notifications_user_created ON public.push_notifications USING btree (user_id, created_at DESC)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_push_notifications_unread ON public.push_notifications USING btree (user_id, read_at)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.push_notifications")
    }
}
