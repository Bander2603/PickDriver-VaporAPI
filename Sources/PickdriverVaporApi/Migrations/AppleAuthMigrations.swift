//
//  AppleAuthMigrations.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 19.02.26.
//

import Fluent
import SQLKit

struct AddAppleIDToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS apple_id character varying(128)
        """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_users_apple_id
            ON public.users USING btree (apple_id)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS public.idx_users_apple_id").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS apple_id").run()
    }
}
