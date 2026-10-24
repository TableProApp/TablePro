## Change

Describe the user-visible behavior or the issue this change addresses. Link the owning issue.

## Release note

One line per user-facing change, written as user impact, or `none`. The PR body becomes the squash commit body, so these lines reach history unchanged.

```
Release-Note: <Added|Changed|Deprecated|Removed|Fixed|Security>: <what the user sees>
Release-Note: none
```

## Reproduction and regression proof

For a behavior change, give the smallest trigger and what happened before the fix. Name the regression test, or explain which existing behavior the test pins.

## Validation

- Tested commit:
- Local commands and results:
- Unrun, blocked or pending checks:
- Forgejo gate required: yes / no

For UI findings, include the Linux distribution, desktop and display protocol, BookiE commit and install method, and database/version when relevant. Redact secrets and private data from logs and screenshots.
