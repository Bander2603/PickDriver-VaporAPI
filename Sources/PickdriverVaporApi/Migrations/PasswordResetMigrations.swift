//
//  PasswordResetMigrations.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 28.01.26.
//

import Fluent
import SQLKit

struct AddPasswordResetToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS password_reset_token_hash character varying(128)
        """).run()
        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS password_reset_expires_at timestamp without time zone
        """).run()
        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS password_reset_sent_at timestamp without time zone
        """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_users_password_reset_token_hash
            ON public.users USING btree (password_reset_token_hash)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS public.idx_users_password_reset_token_hash").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS password_reset_sent_at").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS password_reset_expires_at").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS password_reset_token_hash").run()
    }
}

