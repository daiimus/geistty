# Privacy Policy for Geistty

**Last Updated: December 2024**

## Overview

Geistty is an SSH terminal app for iOS. We are committed to protecting your privacy. This policy explains what data Geistty collects and how it's used.

## Data Collection

### What We Collect

**Geistty does not collect, store, or transmit any personal data to external servers.**

All data is stored locally on your device:

- **Connection Profiles**: Server hostnames, ports, and usernames are stored locally in the app's sandboxed storage
- **SSH Keys**: Private keys are stored securely in the iOS Keychain on your device
- **Passwords**: If you choose to save passwords, they are stored in the iOS Keychain
- **Configuration**: Terminal preferences (fonts, colors, themes) are stored locally

### What We Don't Collect

- No analytics or telemetry
- No crash reports sent externally
- No usage tracking
- No advertising identifiers
- No location data
- No device identifiers shared externally

## Network Access

Geistty requires network access solely to establish SSH connections to servers you specify. The app:

- Connects only to servers you explicitly configure
- May access local network devices when you enable local network permissions
- Does not communicate with any third-party servers
- Does not phone home or check for updates externally

## Data Security

- SSH credentials are stored in the iOS Keychain, Apple's secure credential storage
- All SSH connections use industry-standard encryption (SSH protocol)
- No data leaves your device except through your configured SSH connections

## Third-Party Services

Geistty does not integrate with any third-party analytics, advertising, or tracking services.

## Encryption

Geistty uses encryption for:
- SSH protocol communication (handled by libssh2)
- Credential storage (iOS Keychain)

This encryption is used solely for secure SSH connections, not for transmitting data to external services.

## Data Retention

All data remains on your device until you delete it. Uninstalling Geistty removes all associated data from your device.

## Children's Privacy

Geistty does not knowingly collect any information from children under 13.

## Changes to This Policy

We may update this privacy policy from time to time. We will notify users of any material changes by updating the "Last Updated" date.

## Contact

For privacy questions or concerns, please open an issue on our GitHub repository.

## Your Rights

Since all data is stored locally on your device, you have complete control over your data. You can:
- View all stored connection profiles within the app
- Delete any or all saved connections
- Remove the app to delete all associated data

---

**Summary**: Geistty is a privacy-focused SSH client. Your data stays on your device. We don't collect anything.
