# ivoyager_assistant

AI assistant for accessible solar system navigation. Also provides AI interface for development tests.

UNDER DEVELOPMENT!

Today the TCP server (JSON-RPC on `localhost:29071`) is usable for AI-driven testing — state queries, body queries, controls, screenshots, save/load, action emulation, and generic GUI inspection. Accessibility features (voice control, screen reader, spatial audio) are planned.

This plugin will provide an interface so that AI can navigate the solar system, change anything accessible in the GUI (options, HUDs visibilities and colors, etc.), know what's on screen, and check on what's happening elsewhere. The motivation is twofold:

1. So AI can conduct tests (prerequisite to any serious AI-assisted coding).
2. So the Planetarium and other I, Voyager apps can be more accessible, for example, allowing navigation around the solar system via voice control.

The plugin itself is being developed using Claude Code. See Claude's specs and plans in:

- SPECIFICATION.md
- CODING_PLAN.md
