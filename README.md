# WrongBook Solver

Native SwiftUI operator application for answering questions submitted by students through WrongBook's **由真人解題** feature.

## Status

**Migration in progress — not production-ready.** The canonical existing implementation currently lives in the private [WrongBook iOS repository](https://github.com/jamshih/wrongbook-swift-ios-app) under `HumanSolverAdmin/`. The V183 project is the historical baseline; current source must be audited before being imported here.

## Product contract

1. A signed-in student requests help from the existing question's AI Tutor.
2. The server stores a privacy-minimized snapshot: subject, full printed stem/choices, the student's **selected original crop**, and any necessary **separate diagram/chart extracts**.
3. An authorized operator views the request, claims it, and replies with text, images, or both.
4. The reply is durably stored with private attachments and appears as a clearly labeled **真人解題** entry in the same AI Tutor conversation.
5. The student receives a durable in-app notification, with remote push where permitted. Tapping it opens the exact question and automatically opens its Tutor conversation.
6. The first release supports one operator. The authorization/data model must support later expansion without exposing other students' questions.

## Boundaries

- This repository owns only the native **operator app**, operator-app tests, and documentation.
- The private [WrongBook iOS repository](https://github.com/jamshih/wrongbook-swift-ios-app) remains the source of truth for the student app, Supabase migrations/functions, and notification delivery until a separate migration is explicitly reviewed.
- The operator app must use only a Supabase **publishable** client key. Never commit service-role keys, operator keys, signing identities, access tokens, or student content.
- All question images and answer attachments are private and must be accessed using time-limited, authorization-checked URLs.
- Never deploy, migrate a live database, publish an App Store build, or merge a PR without explicit review and approval.

## Implementation sequence

1. Security-audited extraction of the existing `HumanSolverAdmin/` SwiftUI project.
2. Exact question snapshot contract for the original crop and extracted diagrams/charts.
3. Reliable reply persistence and notification/outbox semantics.
4. APNs delivery and question/Tutor deep-link verification.
5. Simulator, backend and physical-device acceptance testing.

All implementation work happens in reviewable pull requests. See GitHub Issues for scoped agent tasks.
