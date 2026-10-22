# The ToDoz Philosophy
## How ToDoz Embodies Sovereign Personal Software

> *Software should serve people without claiming permanent custody over their information, choices, or work.*

ToDoz was created as a reference implementation of [Sovereign Personal Software](https://sovereign.polla.dev/). The full manifesto—along with its [intellectual lineage](https://sovereign.polla.dev/lineage/), its evidence-led [evaluation methodology](https://sovereign.polla.dev/methodology/), the [Sovereign Index](https://sovereign.polla.dev/directory/), and a [reading edition](https://sovereign.polla.dev/read/)—lives on its own site. This document describes how ToDoz applies the framework in practice.

## How ToDoz Applies the Four Foundational Principles

The Sovereign Software framework establishes four foundational principles in a deliberate conceptual order (**Sovereignty** defines the goal; **Longevity** protects it across time; **Locality** provides a primary means of independence; **Transparency and Control** make authority effective in operation):

1. **Sovereignty (Authority belongs to the user):** Your tasks, projects, comments, and history live in a local SQLite database under your custody. ToDoz requires no commercial cloud account or subscription, and its optional sync server (`server/`, Dart + SQLite) runs on hardware you control with per-device pairing tokens you can revoke at any time.
2. **Longevity (Information outlives software):** Your records are stored in documented SQLite schemas and exported in portable, human-inspectable formats (**JSON** full-fidelity backups, **CSV** project tables, **ICS** calendar feeds, and plain-text lists). Automatic local folder backups and verified restore paths (including backwards-compatible TaskFlow 1.0 backup imports) ensure your commitments survive beyond any single binary.
3. **Locality (Independence is designed in):** On Android and Windows, the local database is the primary working environment. Creating, completing, rescheduling, searching, and filtering tasks work completely offline. Network connectivity is used only when you choose to synchronize devices or connect external calendars, and offline changes queue locally until your server is reachable.
4. **Transparency and Control (Consequential behavior remains governable):** Recurring schedules (`every! 2 months`, `every last workday`), reminders, and Boolean filter queries execute on deterministic, testable rules in `packages/taskflow_core`. Ambiguous grammar is explicitly reported rather than silently guessed; every destructive action records an inspectable activity-log entry with Undo; and the app states honestly that self-hosted server sync uses field-level Last-Write-Wins (LWW) without end-to-end encryption so you know exactly who can read synced data.

## Supporting Engineering Qualities (`T6` & `T7`)

In the Sovereign Software methodology, interoperability, modularity, and UI responsiveness are supporting engineering qualities (`T6` and `T7`) that serve user authority rather than replacing it:

- **Interoperability and Bounded Scope (`T6`):** ToDoz focuses on task execution and scheduling rather than trying to swallow your long-form notes or knowledge base. It connects to Markdown vaults, journals, and external tools through a documented REST API, signed incoming/outgoing webhooks, ICS calendar feeds, and CSV/JSON interchange.
- **Human Experience and Responsiveness (`T7`):** Because routine interactions read and write directly to local SQLite without waiting on remote round-trips, ToDoz targets immediate sub-100ms feedback on local actions while avoiding dark patterns, telemetry, or nagging notifications.

## AI in the Build, Not in the Product

ToDoz was built with the assistance of AI coding agents, which lowered the engineering cost of implementing a full cross-platform task manager. However, the application itself contains no mandatory AI dependencies: recurring schedules, filters, and state transitions run on deterministic code that works with every external service switched off.

**AI helped build ToDoz. Your ability to access and govern your tasks never depends on an AI provider.**

## What ToDoz Refuses to Become

- **Captive data or mandatory accounts:** No third-party cloud account or subscription is ever required to access, export, or restore your tasks.
- **Opaque automation in predictable operations:** No probabilistic guessing where deterministic scheduling and filter rules belong.
- **Silent loss through synchronization:** Field-level LWW conflict rules are documented, device tokens are revocable, and replicated server state is never confused with an independent local JSON backup.
- **Concealed dependencies and surveillance:** Zero tracking telemetry, zero analytics SDKs, and zero undisclosed background network calls.
- **Unbounded feature bloat:** Because AI makes code cheaper to generate, the discipline of keeping the system understandable, testable, and maintainable matters more, not less.

---

*ToDoz: Sovereign productivity, by design. Reference implementation of the [Sovereign Personal Software](https://sovereign.polla.dev/) manifesto and evaluated under the `finance_tasks` domain profile of the [Sovereign Software Methodology](https://sovereign.polla.dev/methodology/).*
