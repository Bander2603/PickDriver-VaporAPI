//
//  DraftBanProtectionMigration.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 22.03.26.
//

import Fluent
import SQLKit
import Vapor

struct AddProtectedRepickStateToRaceDrafts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw(SQLQueryString("""
        ALTER TABLE public.race_drafts
        ADD COLUMN IF NOT EXISTS protected_repick_user_id integer,
        ADD COLUMN IF NOT EXISTS protected_repick_pick_index integer,
        ADD COLUMN IF NOT EXISTS protected_repick_deadline timestamp without time zone
        """)).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw(SQLQueryString("""
        ALTER TABLE public.race_drafts
        DROP COLUMN IF EXISTS protected_repick_deadline,
        DROP COLUMN IF EXISTS protected_repick_pick_index,
        DROP COLUMN IF EXISTS protected_repick_user_id
        """)).run()
    }
}
