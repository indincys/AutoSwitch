# AGENTS.md

## Repository Context

This repository contains AutoSwitch, a self-use native macOS app for Apple Silicon and macOS 26 that switches macOS system input sources by active app rules.

## Read First

Before implementation or review work, read these files in order:

1. `PLAN.md` - stable product and technical specification.
2. `GOAL.md` - active `/goal` execution contract, scope, stopping condition and pause rules.
3. `docs/goal/progress.md` - live checkpoint status. Treat this as the current progress source and rewrite it after meaningful checkpoints.
4. `macos-floating-teacup.md` - original user-provided technical selection notes, useful when implementation needs rationale behind `PLAN.md`.

## Document Roles

- `PLAN.md` defines the product, architecture, data model, UI requirements, non-goals and acceptance checklist.
- `GOAL.md` defines the current long-running objective, validation proof, run control and pause conditions.
- `docs/goal/progress.md` records current execution state only. Do not append a long history.
- `AGENTS.md` contains durable repository guidance only. Do not put transient status, checkpoint progress, or "repository is empty" style snapshots here.

## Durable Constraints

- Build a native macOS app with Swift 6, SwiftUI/AppKit where appropriate, Carbon TIS APIs, Accessibility AX observer, `SMAppService`, Sparkle 2.x and Swift Package Manager.
- Target Apple Silicon and macOS 26 only.
- Do not add Intel support, App Store distribution, Developer ID notarization, menu bar residency, cloud sync, telemetry, or third-party IME internal mode handling unless the user explicitly changes scope.
- Do not store Sparkle private keys, signing certificate material, GitHub tokens, or other secrets in the repository.
- Treat `docs/goal/progress.md` and the actual filesystem as live state after context compaction or `/goal resume`.
