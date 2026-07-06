# AGENTS.md
`screencommander` is a macOS Swift command-line automation utility for a terminal-driven observe -> decide -> act loop. It captures the desktop, reads Accessibility structure, and sends mouse/keyboard input with deterministic coordinate mapping.

README owns the public product contract, SKILL.md owns the operator runbook, and `docs/json-output-schema.md` owns JSON output shape.

## Local Dev Toolchain

- Build: `swift build`
- Run tests: `swift test`
- Run the local binary without installing: `swift run screencommander --help`
- Check generated help for changed commands: `swift run screencommander <command> --help`

## Execution Protocol
- When writing a PR intro, make the first sentence earn its place: name the concrete capability completed, include 2-3 examples of scope, and name 2-3 behaviors tightened by the change. A strong intro should let a reviewer understand the shape of the work before reading the bullets.
