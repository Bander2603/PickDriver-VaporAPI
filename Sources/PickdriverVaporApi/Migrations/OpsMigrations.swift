//
//  OpsMigrations.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 08.02.26.
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

// MARK: - ops_audit_events

struct CreateOpsAuditEvents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec(#"""
        CREATE TABLE public.ops_audit_events (
            id SERIAL PRIMARY KEY,
            event_type character varying(64) NOT NULL,
            source character varying(64) NOT NULL,
            metadata jsonb,
            created_at timestamp without time zone DEFAULT now() NOT NULL
        )
        """#)

        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_ops_audit_events_created_at ON public.ops_audit_events USING btree (created_at DESC)")
        try await sql.exec("CREATE INDEX IF NOT EXISTS idx_ops_audit_events_event_type ON public.ops_audit_events USING btree (event_type)")
    }

    func revert(on database: any Database) async throws {
        let sql = try database.sql()
        try await sql.exec("DROP TABLE IF EXISTS public.ops_audit_events")
    }
}
