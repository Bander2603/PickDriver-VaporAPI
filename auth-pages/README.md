# auth.pickdriver.cc (Cloudflare Pages)

Minimal static pages for:
- `/email-verified`
- `/reset-password`

Also includes Universal Links files:
- `/.well-known/apple-app-site-association`
- `/apple-app-site-association`

## 1) Cloudflare Pages

1. Create a new Pages project.
2. Connect this repository.
3. Configure:
   - Framework preset: `None`
   - Build command: *(empty)*
   - Build output directory: `auth-pages`
4. Add custom domain: `auth.pickdriver.cc`.

## 2) Backend env (API)

Set these values in the API deployment environment:

- `EMAIL_VERIFICATION_SUCCESS_REDIRECT_URL=https://auth.pickdriver.cc/email-verified`
- `PASSWORD_RESET_REDIRECT_URL=https://auth.pickdriver.cc/reset-password`
- `EMAIL_VERIFICATION_LINK_BASE_URL=https://api.pickdriver.cc/api/auth/verify-email-link`
- `PASSWORD_RESET_LINK_BASE_URL=https://api.pickdriver.cc/api/auth/reset-password-link`

## 3) CORS note

`/reset-password` calls `https://api.pickdriver.cc/api/auth/reset-password` from browser JS.

Make sure API CORS allows origin:
- `https://auth.pickdriver.cc`

## 4) iOS Universal Links

In iOS project:
1. Add Associated Domains capability.
2. Add domain:
   - `applinks:auth.pickdriver.cc`

Then edit both files:
- `auth-pages/.well-known/apple-app-site-association`
- `auth-pages/apple-app-site-association`

Replace:
- `TEAM_ID.BUNDLE_ID`

Example:
- `ABCDE12345.com.pickdriver.ios`

After deploy, verify:
- `https://auth.pickdriver.cc/.well-known/apple-app-site-association`
- `https://auth.pickdriver.cc/apple-app-site-association`

Both must return JSON with HTTP 200.
