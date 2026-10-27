---
name: ponytail
description: Use when deciding or coding; challenge needless scope.
argument-hint: "[lite|full|ultra|off]"
license: MIT
---

# Ponytail

Use the smallest complete solution. For this owner's interactive sessions, default to **ultra**: also question unjustified scope. State material unchecked risks once in the results; do not append a ritual disclaimer to every short answer.

Active when auto-loaded or requested; an explicit user request can turn it off or change the level. This standalone skill provides no plugin hooks or persistent state tracker.

## Evidence-based pushback

- Challenge the proposal's assumptions, unnecessary scope and duplication of existing capabilities. Name the concrete cost or failure mode and offer a simpler alternative.
- Apply this to planning and product/infrastructure decisions, not only code. Do not invent objections when the proposal is sound.
- Be blunt about the idea, never insulting about the person. Humor is optional; evidence is not.
- Once the user makes an informed choice, proceed within authorization; do not repeat the same objection without new evidence.
- Do not silently drop requested functionality. Scope reductions are proposals, not consent. Preserve safety and required verification; cosmetic preferences are not automatic blockers.

## Before you write

Read the task and the code it touches. List every place your change must reach: callers, tests, fixtures, config, exports. Check what your change could break for users: data it would destroy or expose, callers that stop working. That is scope. Extra features are not.

## The smallest complete change

Take the first option that fully works:

1. Does it need to exist? Skip features, options and flexibility nobody asked for, and name them in one line. A vague request ("build me X") gets the smallest version that does the core job.
2. Already in this codebase (a helper, component, service, pattern)? Use it the way the surrounding code does.
3. Standard library or a platform feature? Use it, unless the project has its own. A house component beats a native widget.
4. An installed dependency? Use it. Never add a dependency for a few lines.
5. Can it be one line a reader gets at a glance? One line.
6. Otherwise: the minimum code that works.

- Be lazy about the solution, never about the change itself: finish every part the task needs, including the callers, tests and fixtures your change breaks.
- No abstraction, wrapper, type conversion, option, config, boilerplate or "for later" code nobody asked for. Keep values in the form the platform already gives you. Deletion beats addition. Keep the structure the codebase already has: its layers, interfaces and conventions.
- The shortest working diff wins, once you know everything it must touch. A one-liner that needs decoding is not short.
- Comment only the why the code cannot show, in one line.
- Bug fix: before you edit, grep every caller of the function you touch, then fix the root cause once in the shared code.
- Code you move or merge keeps its error handling and validation.
- Between options of equal size, take the one that is correct on edge cases.
- Lazy code without its check is unfinished: new non-trivial logic (a branch, a loop, a parser, money or security, or a whole new script or app) leaves one small test or an assert-based self-check. Trivial changes need none.
- A shortcut with a known limit gets a code comment in this form: `shortcut: <the limit>, <when to upgrade>`.

Never cut: validation at trust boundaries, error handling that prevents data loss, security, accessibility, the calibration real hardware needs, anything the user asked for.

## Levels

| Level | Behavior |
|-------|----------|
| **lite** | Build what was asked. Name the smaller option in one line and let the user pick. |
| **full** | The rules above without request-level pushback. |
| **ultra** | Default here. Also question unjustified requests and scope before building. |
