# Example Corp Password and Access Policy

Document owner: IT Security. Version 2.3, effective 1 March 2026.

## Purpose

This policy defines the minimum requirements for passwords and account access
across all Example Corp systems, including email, VPN, the HR portal, and cloud
consoles. It applies to employees, contractors, and service accounts.

## Password requirements

- Passwords must be at least 14 characters long.
- Passphrases of four or more unrelated words are encouraged.
- Passwords must not contain the user name, the company name, or any part of the
  employee ID.
- The last 12 passwords cannot be reused.

## Rotation

- Standard user passwords must be rotated every 180 days.
- Privileged and administrator passwords must be rotated every 90 days.
- Service account credentials are rotated automatically every 60 days by the
  secrets manager.
- A password must be changed immediately if it is suspected to be compromised.

## Multi-factor authentication

Multi-factor authentication is mandatory for VPN, email, and all cloud consoles.
Approved factors are the corporate authenticator app and FIDO2 hardware keys.
SMS codes are not an approved factor.

## Resetting a forgotten password

1. Open the self-service portal at `reset.example.corp` and choose *Forgot password*.
2. Confirm your identity with your registered authenticator.
3. Set a new password that meets the requirements above.

If the self-service portal is unavailable, contact the IT service desk. The
service desk verifies identity by calling back the phone number on record and
never sends passwords by email.

## Account lockout

Ten consecutive failed sign-in attempts lock the account for 30 minutes. Locked
privileged accounts are only unlocked by the service desk after verification.

## Exceptions

Exceptions require written approval from the Chief Information Security Officer
and are reviewed every six months.
