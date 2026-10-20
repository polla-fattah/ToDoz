# The ToDoz Philosophy
## A Manifesto for Sovereign Personal Software

> *Your data belongs to you. Your tools should respect your time, preserve your freedom, and remain useful without depending on someone else's infrastructure.*

---

## 01. The Core Manifesto

Software should adapt to people, not force people to adapt to software.

Modern productivity applications offer remarkable capabilities, but many increasingly depend on cloud services, subscriptions, complex interfaces, and features designed for broad commercial markets rather than individual needs.

ToDoz represents a different choice.

It is built on the belief that personal software should be **owned, controlled, understood, and shaped by the people who use it**.

AI-assisted development makes such software increasingly practical. However, reducing the cost of writing code does not eliminate the importance of architecture, verification, security, and maintenance.

Six principles define ToDoz:

1. **Sovereignty:** Users control their data, infrastructure, and ability to migrate.
2. **Locality:** Core functionality runs on the user's device, independently of network connectivity.
3. **Predictability:** Critical operations are deterministic, transparent, and testable.
4. **Responsiveness:** Software respects the user's time and attention.
5. **Focused Interoperability:** Applications maintain clear responsibilities while exchanging information freely.
6. **Longevity:** Information should outlive individual applications, vendors, and technologies.

These principles take precedence over any framework, database, feature, or implementation technique.

---

## 02. The Six Foundational Principles

### I. Sovereignty: The User Is the Owner

Personal information should not become inaccessible because a subscription expires, an account is suspended, or a service disappears.

Sovereignty requires meaningful control over data, including the ability to inspect, export, back up, migrate, and restore it.

ToDoz prioritizes local ownership, documented formats, self-hosted infrastructure, and freedom from mandatory commercial accounts.

**Ownership is meaningful only when the user retains the ability to leave.**

### II. Locality: The Device Comes First

The network should enhance an application, not determine whether it can function.

Creating tasks, updating priorities, managing schedules, and searching locally stored information must remain available offline.

ToDoz treats the local database as the primary working environment. Synchronization operates separately, with explicit status, predictable conflict handling, and recovery from interrupted connections.

**Offline operation is not an emergency fallback. It is the normal operating model.**

### III. Predictability: Intelligence May Assist, Rules Must Govern

Tasks, reminders, filters, and recurring schedules represent commitments. Their behavior must be consistent, explainable, and reproducible.

ToDoz uses deterministic rules for critical operations and explicitly handles invalid or ambiguous inputs rather than silently guessing.

AI may optionally help interpret a user's intention, but proposed actions must be validated and authorized before execution.

**Intelligence may assist. Predictability must govern.**

### IV. Responsiveness: Respect Human Attention

Software should reduce effort, not become another source of work.

Common local interactions should provide immediate feedback. ToDoz targets a visible response within 100 milliseconds for routine actions on supported hardware.

Responsiveness also means avoiding unnecessary notifications, interface complexity, background processing, and features that distract from the task at hand.

**Good software helps users complete their work without becoming work itself.**

### V. Focused Interoperability: Separate Responsibilities, Connect Information

Tasks manage actions, deadlines, priorities, and operational states. Notes and diaries preserve knowledge, reflection, references, and long-term understanding.

These responsibilities are related but do not require a single monolithic application.

ToDoz focuses on task execution while supporting connections to Markdown repositories, journals, calendars, and complementary applications through documented interfaces and open formats.

Users should be able to change one tool without losing access to information maintained by another.

**Separate responsibilities. Connect information. Preserve freedom of choice.**

### VI. Longevity: Information Should Outlive Software

Applications and technologies change, but personal records may remain valuable for decades.

ToDoz favors documented, widely supported formats, portable exports, verified backups, and maintainable migration paths.

No technology guarantees fifty-year compatibility. Longevity depends on continued attention to recoverability, documentation, and preservation.

**Applications are temporary. Personal information deserves a longer life.**

---

## 03. The Architecture of Personal Productivity

ToDoz follows a modular model that separates execution from reflection while allowing both to cooperate.

### Execution Layer: ToDoz

Responsible for capturing commitments, managing tasks, schedules, priorities, recurring activities, reminders, and completion history.

**Its central question: What needs to be done, when, and in what state is it?**

### Knowledge Layer: Markdown Ecosystem

Responsible for journals, research notes, documentation, ideas, references, retrospectives, and long-term knowledge.

**Its central question: What have I learned, experienced, and understood?**

### Integration Layer: Open Connections

The two layers communicate through documented mechanisms such as application URIs, Markdown links, local APIs, command-line interfaces, and standard calendar formats.

Each system should remain independently usable and replaceable.

**Integration should create convenience, not dependency.**

---

## 04. Artificial Intelligence Without Artificial Dependency

AI coding agents can accelerate software development, but generated code still requires human judgment, testing, security review, and maintenance.

Likewise, AI features should not become mandatory simply because they are available.

ToDoz accepts optional AI assistance only when:

- Core functionality remains available without AI.
- The user retains control over proposed actions.
- Critical operations remain deterministic and verifiable.
- Privacy, cost, and external dependencies are transparent.
- Removing AI does not compromise access to existing information.

AI should expand human capability without undermining independence or predictability.

**AI may help create the software. It does not have to become the software.**

---

## 05. Synchronization Without Surrender

Synchronization is a convenience, not a transfer of ownership.

ToDoz favors user-controlled infrastructure, secure device pairing, minimal operational complexity, predictable conflict resolution, and recoverability after disconnection.

Its design must make encryption guarantees, trust boundaries, and the risk of conflicting changes explicit.

Synchronization strategies involve trade-offs. The preferred solution is not necessarily the most sophisticated, but the simplest architecture that satisfies the required correctness and security guarantees.

**Complexity must justify its existence.**

---

## 06. The Engineering Evaluation Tests

Every significant feature or architectural decision must pass seven tests:

1. **Airplane Test:** Does core functionality remain available without internet access?
2. **100ms Test:** Do common local interactions respond immediately on supported hardware?
3. **Longevity Test:** Can users recover and understand their information if the application disappears?
4. **Responsibility Test:** Does the feature belong in ToDoz, or should a specialized tool provide it?
5. **Dependency Test:** Does it introduce an avoidable external dependency, subscription, or recurring cost?
6. **Predictability Test:** Can its behavior be specified, reproduced, tested, and explained?
7. **Security and Recovery Test:** Does it preserve confidentiality, integrity, access control, and recoverability?

These tests guide engineering judgment. Exceptions must be deliberate, justified, and documented.

---

## 07. What ToDoz Refuses to Become

ToDoz deliberately resists:

- Mandatory cloud accounts and subscriptions for essential functionality.
- Unnecessary AI inference in predictable operations.
- Invasive telemetry or undisclosed collection of personal activity.
- Feature bloat and duplication of specialized applications.
- Hidden synchronization behavior that risks data integrity.
- Proprietary data lock-in and avoidable technological dependencies.
- Architectural complexity adopted without a demonstrated need.

These boundaries are not restrictions against innovation. They protect the application's purpose.

**The ability to add a feature is not sufficient reason to add it.**

---

## 08. Personal Software in the Age of AI

Traditionally, software development required substantial engineering effort, encouraging products designed for large markets.

AI-assisted development is beginning to change that economic relationship.

Individuals and small communities can increasingly create applications around their particular needs without requiring a commercial-scale audience.

This does not eliminate engineering costs. Verification, security, maintenance, and architectural judgment remain essential.

But it creates a new possibility:

**Software no longer always needs a large market to justify its existence.**

ToDoz is one experiment in this emerging model. Its ambition is not to become an all-encompassing productivity platform, but to demonstrate that personal software can be sovereign, responsive, predictable, interoperable, and durable.

---

## 09. The Final Commitment

ToDoz is not defined by Flutter, SQLite, Docker, or any particular synchronization algorithm. Those are implementation choices that may evolve.

Its identity rests on enduring principles:

Software should remain useful when disconnected, understandable when examined, recoverable when systems fail, and adaptable when needs change.

It should respect human attention, preserve personal information, and avoid dependencies that do not serve a clear purpose.

Above all, it should remain a tool under human control.

**The software belongs to the user. The architecture must never forget that.**

---

*ToDoz: Sovereign productivity, by design.*
