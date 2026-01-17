# Geistty Copilot Instructions

## Before making changes
- Read relevant documentation files before modifying code
- State your understanding of the current state before proposing changes
- Run existing tests with `./ci.sh test` - do NOT suggest device testing first

## Testing
- Run `./ci.sh test` to verify changes
- Write unit tests for new functionality
- Existing test suite can run locally on simulator

## General
- Use `Logger` not `print()` for logging
- Follow patterns established in upstream Ghostty codebase

## Archived Features
- **File Provider** - Archived Jan 2026. See `FILE_PROVIDER_LEARNINGS.md` and branch `archive/file-provider-jan-2026`
