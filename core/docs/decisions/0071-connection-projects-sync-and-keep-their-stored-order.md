# 0071: Connection projects sync over TablePro Sync and keep their stored order

- **Status**: Accepted; amends 0067
- **Date**: 2026-11-27

## Context

[0067](0067-connection-projects.md) kept projects on the device: no record carried one (Consequences), and every read and write numbered the projects from 0 (Repair). #4642 syncs them over TablePro Sync. A pull can land a project list over several pages. Numbering from 0 on every read and write then reordered projects mid-pull, and the next push sent the new orders back. 0067 is Accepted, so the change goes here, and 0067 changes only its Status line.

## Decision

- **Order.** A reorder and a deletion number the projects from 0. A new project goes after the last. A read and a pull keep the order each project has stored.
- **What syncs.** On TablePro Sync, `connection_project` carries a project's name, colour, icon and order, and a connection and a group carry `project_id`. A pull applies `project_id`, and a record that names none takes the member out of every project. A pulled project deletion leaves its members naming it, so they read as in no project (0067, Repair).
- **iCloud waits for Production.** `ConnectionProject` and `projectId` stay pending in the core's CloudKit registry until the record type and field are deployed to Production. Until then nothing goes up for them over iCloud, and a pull keeps this device's membership.
- **A pulled project with no name** the store can hold keeps the name of the project stored under its id. With none stored, it is refused as unreadable, so the engine holds it by id. Dropping it would read as a deletion and go up as one.

## Consequences

- A project list that arrives over several pages keeps its order, and no device pushes orders it did not change.
- iCloud carries projects only after a schema deployment and a registry change.
