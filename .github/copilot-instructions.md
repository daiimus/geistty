# Geistty Copilot Instructions

## Before making changes
- Read relevant documentation files before modifying code
- State your understanding of the current state before proposing changes
- Run existing tests with `./ci.sh test` - do NOT suggest device testing first

## File Provider work
- ALWAYS check `FileProviderExtension.swift` to see which enumerator is active
- Do NOT add debug logging as a first step
- Do NOT test on device before running existing unit tests
- Use existing tests in `GeisttyTests/` - we have comprehensive coverage:
  - `MetadataStoreEnumeratorTests.swift` - enumerator behavior tests
  - `FileProviderExtensionTests.swift` - integration tests
- Reference `FILE_PROVIDER_IMPLEMENTATION.md` for failed approaches and history

## Testing
- Run `./ci.sh test` to verify changes
- Write unit tests for new functionality
- Existing test suite can run locally on simulator

## General
- Use `Logger` not `print()` for logging
- Follow patterns established in upstream Ghostty codebase
