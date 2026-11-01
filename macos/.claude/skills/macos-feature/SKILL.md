---
name: macos-feature
description: Implement a macOS feature using native SwiftUI and Apple HIG conventions. Use for new features and substantial UI changes in this project.
argument-hint: "[what to build]"
---

# macOS feature

Feature: $ARGUMENTS

## 1. Understand

Read `CLAUDE.md`, `DESIGN_SPEC.md`, `ARCHITECTURE.md`, the part of the product spec that covers this
area, and the existing code. Check the deployment target. Change nothing yet.

## 2. Design

Describe:

- The user's workflow
- Window and navigation structure
- Native controls, and any custom control with its reason
- Toolbar and menu commands, and keyboard interaction
- Accessibility
- Light and dark, and each supported language
- Empty, loading and error states

Read the relevant Apple HIG pages from `Design/HIG_REFERENCES.md`. If the user asked to approve the
design first, stop here and wait.

## 3. Implement

Prefer SwiftUI, and use AppKit only with a stated reason. Reuse existing components and tokens. A new
deviation from the system default goes in the design spec's deviations table.

## 4. Verify

Follow "When a change is done" in `CLAUDE.md`. Fix all confirmed Critical and Major findings, then
re-run what the fix touched.

## 5. Report

Give what changed and the evidence for each check. Mark everything unchecked as NOT VERIFIED.
