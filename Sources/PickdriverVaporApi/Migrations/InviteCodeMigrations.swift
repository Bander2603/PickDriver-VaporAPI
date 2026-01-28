//
//  InviteCodeMigrations.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 29.01.26.
//

import Fluent
import SQLKit

struct AddInviteCodes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS public.invite_codes (
                id serial PRIMARY KEY,
                code character varying(64) NOT NULL UNIQUE,
                used_at timestamp without time zone,
                used_by_user_id integer REFERENCES public.users(id),
                created_at timestamp without time zone DEFAULT now()
            )
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_invite_codes_code
            ON public.invite_codes USING btree (code)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("DROP TABLE IF EXISTS public.invite_codes").run()
    }
}

