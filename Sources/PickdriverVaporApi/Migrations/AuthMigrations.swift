//
//  AuthMigrations.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 10.02.26.
//

import Fluent
import SQLKit
import Vapor

struct AddEmailVerificationToUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS email_verified boolean NOT NULL DEFAULT false
            """).run()

        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS email_verification_token_hash character varying(128)
            """).run()

        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS email_verification_expires_at timestamp without time zone
            """).run()

        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS email_verification_sent_at timestamp without time zone
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_users_email_verification_token_hash
            ON public.users USING btree (email_verification_token_hash)
            """).run()

        // Avoid locking out existing users.
        try await sql.raw("""
            UPDATE public.users
            SET email_verified = true
            WHERE email_verified = false
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw("DROP INDEX IF EXISTS public.idx_users_email_verification_token_hash").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS email_verification_sent_at").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS email_verification_expires_at").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS email_verification_token_hash").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS email_verified").run()
    }
}

struct RemoveFirebaseUIDFromUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw("ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_firebase_uid_key").run()
        try await sql.raw("ALTER TABLE public.users DROP COLUMN IF EXISTS firebase_uid").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else {
            throw Abort(.internalServerError, reason: "This migration requires an SQLDatabase (Postgres).")
        }

        try await sql.raw("""
            ALTER TABLE public.users
            ADD COLUMN IF NOT EXISTS firebase_uid character varying(128)
            """).run()
        try await sql.raw("""
            ALTER TABLE public.users
            ADD CONSTRAINT users_firebase_uid_key UNIQUE (firebase_uid)
            """).run()
    }
}
