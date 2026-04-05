# Design Conversation Transcript — April 2026

Source: Claude.ai conversation between Zack and Claude, April 2–4, 2026.
Original URL: https://claude.ai/share/bc3c89c7-feb0-4936-9d3b-c9e6cfb18d52

This conversation traces the reasoning from Linux kernel syscall primitives to
the 8-syscall mediator architecture for the Jarvis AI agent sandbox. Key topics:

- OS process identity and how it maps to agent sandbox identity
- SO_PEERCRED for kernel-verified process authentication
- Why most operations (vault, filesystem, binaries) don't need syscalls
- Evolution from 4 → 6 → 7 → 8 syscalls as real constraints emerged
- Policy immutability and versioning
- Privilege inheritance model (children can exceed parent capabilities)
- Namespace isolation via clone(CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWNS)
- The three-UID model (jarvis-agent, jarvis-sandbox, jarvis-daemon)
- Init process constraints (human-gated, Claude Code permission model analog)
- Five challenge workflows that stress-test the design
- SELinux provisioning for external mounts (replaces access_external_mount syscall)
- IPC targeting via policy names, not workflow IDs
- Communication model (Telegram channels, filesystem outboxes, router daemon)

The full transcript is preserved in the shared conversation link above.
The architectural decisions are codified in `mediator-design-decisions.md`.
The rendered design doc is in `eight-syscalls.html`.
