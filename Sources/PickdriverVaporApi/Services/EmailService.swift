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
        req.logger.info("📧 [EMAIL] Verification link for \(email): \(verificationLink)")
    }

    func sendPasswordResetEmail(
        to email: String,
        username: String,
        resetLink: String,
        on req: Request
    ) async throws {
        req.logger.info("📧 [EMAIL] Password reset link for \(email): \(resetLink)")
    }
}

struct SendGridEmailService: EmailService {
    struct EmailAddress: Content {
        let email: String
        let name: String?
    }

    struct Personalization: Content {
        let to: [EmailAddress]
        let subject: String
    }

    struct ContentItem: Content {
        let type: String
        let value: String
    }

    struct SendGridRequest: Content {
        let personalizations: [Personalization]
        let from: EmailAddress
        let content: [ContentItem]
    }

    let apiKey: String
    let fromEmail: String
    let fromName: String?

    func sendVerificationEmail(
        to email: String,
        username: String,
        verificationLink: String,
        on req: Request
    ) async throws {
        let subject = "Verifica tu email"
        let textBody = """
        Hola \(username),

        Confirma tu email haciendo click en el siguiente enlace:
        \(verificationLink)

        Si no creaste esta cuenta, puedes ignorar este correo.
        """
        let htmlBody = """
        <p>Hola \(username),</p>
        <p>Confirma tu email haciendo click en el siguiente enlace:</p>
        <p><a href="\(verificationLink)">Verificar email</a></p>
        <p>Si no creaste esta cuenta, puedes ignorar este correo.</p>
        """

        let payload = SendGridRequest(
            personalizations: [
                Personalization(
                    to: [EmailAddress(email: email, name: username)],
                    subject: subject
                )
            ],
            from: EmailAddress(email: fromEmail, name: fromName),
            content: [
                ContentItem(type: "text/plain", value: textBody),
                ContentItem(type: "text/html", value: htmlBody)
            ]
        )

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")

        let response = try await req.client.post(URI(string: "https://api.sendgrid.com/v3/mail/send"), headers: headers) { clientReq in
            try clientReq.content.encode(payload, as: .json)
        }

        guard response.status == .accepted else {
            throw Abort(.internalServerError, reason: "Failed to send verification email.")
        }
    }

    func sendPasswordResetEmail(
        to email: String,
        username: String,
        resetLink: String,
        on req: Request
    ) async throws {
        let subject = "Restablece tu contraseña"
        let textBody = """
        Hola \(username),

        Para restablecer tu contraseña, abre el siguiente enlace:
        \(resetLink)

        Si no solicitaste este cambio, puedes ignorar este correo.
        """
        let htmlBody = """
        <p>Hola \(username),</p>
        <p>Para restablecer tu contraseña, abre el siguiente enlace:</p>
        <p><a href="\(resetLink)">Restablecer contraseña</a></p>
        <p>Si no solicitaste este cambio, puedes ignorar este correo.</p>
        """

        let payload = SendGridRequest(
            personalizations: [
                Personalization(
                    to: [EmailAddress(email: email, name: username)],
                    subject: subject
                )
            ],
            from: EmailAddress(email: fromEmail, name: fromName),
            content: [
                ContentItem(type: "text/plain", value: textBody),
                ContentItem(type: "text/html", value: htmlBody)
            ]
        )

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(apiKey)")

        let response = try await req.client.post(URI(string: "https://api.sendgrid.com/v3/mail/send"), headers: headers) { clientReq in
            try clientReq.content.encode(payload, as: .json)
        }

        guard response.status == .accepted else {
            throw Abort(.internalServerError, reason: "Failed to send password reset email.")
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
