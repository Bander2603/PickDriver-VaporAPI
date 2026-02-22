//
//  EmailService.swift
//  PickdriverVaporApi
//
//  Created by Eduardo Melcon Diez on 28.01.26.
//

import Vapor

protocol EmailService: Sendable {
    func sendVerificationEmail(
        to email: String,
        username: String,
        verificationLink: String,
        on req: Request
    ) async throws

    func sendPasswordResetEmail(
        to email: String,
        username: String,
        resetLink: String,
        on req: Request
    ) async throws
}

struct LogEmailService: EmailService {
    func sendVerificationEmail(
        to email: String,
        username: String,
        verificationLink: String,
        on req: Request
    ) async throws {
        req.logger.info("[EMAIL] Verification link for \(email): \(verificationLink)")
    }

    func sendPasswordResetEmail(
        to email: String,
        username: String,
        resetLink: String,
        on req: Request
    ) async throws {
        req.logger.info("[EMAIL] Password reset link for \(email): \(resetLink)")
    }
}

struct ResendEmailService: EmailService {
    private struct ResendEmailRequest: Content {
        let from: String
        let to: [String]
        let subject: String
        let text: String
        let html: String
    }

    let apiKey: String
    let fromEmail: String
    let fromName: String?

    private var fromHeader: String {
        guard let fromName, !fromName.isEmpty else {
            return fromEmail
        }
        return "\(fromName) <\(fromEmail)>"
    }

    func sendVerificationEmail(
        to email: String,
        username: String,
        verificationLink: String,
        on req: Request
    ) async throws {
        let payload = ResendEmailRequest(
            from: fromHeader,
            to: [email],
            subject: "Verifica tu email",
            text: """
            Hola \(username),

            Confirma tu email abriendo el siguiente enlace:
            \(verificationLink)

            Si no creaste esta cuenta, puedes ignorar este correo.
            """,
            html: """
            <p>Hola \(username),</p>
            <p>Confirma tu email abriendo el siguiente enlace:</p>
            <p><a href="\(verificationLink)">Verificar email</a></p>
            <p>Si no creaste esta cuenta, puedes ignorar este correo.</p>
            """
        )

        try await send(payload: payload, on: req)
    }

    func sendPasswordResetEmail(
        to email: String,
        username: String,
        resetLink: String,
        on req: Request
    ) async throws {
        let payload = ResendEmailRequest(
            from: fromHeader,
            to: [email],
            subject: "Restablece tu contrasena",
            text: """
            Hola \(username),

            Para restablecer tu contrasena, abre el siguiente enlace:
            \(resetLink)

            Si no solicitaste este cambio, puedes ignorar este correo.
            """,
            html: """
            <p>Hola \(username),</p>
            <p>Para restablecer tu contrasena, abre el siguiente enlace:</p>
            <p><a href="\(resetLink)">Restablecer contrasena</a></p>
            <p>Si no solicitaste este cambio, puedes ignorar este correo.</p>
            """
        )

        try await send(payload: payload, on: req)
    }

    private func send(payload: ResendEmailRequest, on req: Request) async throws {
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(apiKey)")

        let response = try await req.client.post(
            URI(string: "https://api.resend.com/emails"),
            headers: headers
        ) { clientReq in
            try clientReq.content.encode(payload)
        }

        guard (200..<300).contains(response.status.code) else {
            let body: String
            if let responseBody = response.body {
                body = responseBody.getString(at: responseBody.readerIndex, length: responseBody.readableBytes) ?? ""
            } else {
                body = ""
            }
            req.logger.error(
                "Resend API failed",
                metadata: [
                    "status": "\(response.status.code)",
                    "body": "\(body)"
                ]
            )
            throw Abort(.internalServerError, reason: "Failed to send email.")
        }
    }
}

extension Application {
    private struct EmailServiceKey: StorageKey {
        typealias Value = any EmailService
    }

    var emailService: any EmailService {
        get { self.storage[EmailServiceKey.self] ?? LogEmailService() }
        set { self.storage[EmailServiceKey.self] = newValue }
    }

    private struct EmailVerificationLinkBaseKey: StorageKey {
        typealias Value = String
    }

    var emailVerificationLinkBaseURL: String {
        get { self.storage[EmailVerificationLinkBaseKey.self] ?? "http://localhost:3000/api/auth/verify-email-link" }
        set { self.storage[EmailVerificationLinkBaseKey.self] = newValue }
    }

    private struct EmailVerificationSuccessRedirectKey: StorageKey {
        typealias Value = String?
    }

    var emailVerificationSuccessRedirectURL: String? {
        get { self.storage[EmailVerificationSuccessRedirectKey.self] ?? nil }
        set { self.storage[EmailVerificationSuccessRedirectKey.self] = newValue }
    }

    private struct PasswordResetLinkBaseKey: StorageKey {
        typealias Value = String
    }

    var passwordResetLinkBaseURL: String {
        get { self.storage[PasswordResetLinkBaseKey.self] ?? "http://localhost:3000/api/auth/reset-password-link" }
        set { self.storage[PasswordResetLinkBaseKey.self] = newValue }
    }

    private struct PasswordResetRedirectKey: StorageKey {
        typealias Value = String?
    }

    var passwordResetRedirectURL: String? {
        get { self.storage[PasswordResetRedirectKey.self] ?? nil }
        set { self.storage[PasswordResetRedirectKey.self] = newValue }
    }
}
