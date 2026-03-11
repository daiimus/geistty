---
name: Environment Drift Audit
about: Periodic checklist to verify dev environment is clean
title: "Environment drift audit"
labels: env-hygiene
---

## Pre-flight

- [ ] `git status` clean in both repos
- [ ] ghostty on `ios-external-backend`, geistty on `main`
- [ ] Hooks installed: `git config core.hooksPath` returns `.githooks`
- [ ] No LFS warnings: `git lfs env` shows no active tracking

## Artifact policy

- [ ] No `.a` files tracked in geistty: `git ls-files '*.a'` returns empty
- [ ] No xcframework binaries tracked: `git ls-files '*.a' -- Geistty/Frameworks/` returns empty
- [ ] `.gitignore` covers: `.a`, `.o`, `.dylib`, `DerivedData/`, `*.app`, `*.dSYM`, `*.xcarchive`
- [ ] Post-build `git status` is clean (no untracked build output)

## Issue tracker

- [ ] All closed issues have summary comment + commit link
- [ ] Open issues have accurate priority labels
- [ ] No stale `in-progress` items without recent activity

## Docs

- [ ] `AGENTS.md` canonical paths match actual filesystem
- [ ] Session-start checklist is current
- [ ] No references to deprecated tool names or paths
