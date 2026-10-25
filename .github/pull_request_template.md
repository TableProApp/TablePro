## Change

Describe the user-visible behavior or the issue this change addresses. Link the owning issue.

## Release note

One line per user-facing change, written as user impact, or `none`. The PR body becomes the squash commit body, so these lines reach history unchanged.

```
Release-Note: <Added|Changed|Deprecated|Removed|Fixed|Security>: <what the user sees>
Release-Note: none
```

## Reproduction and regression proof

For a behavior change, include the issue's user-visible Given / When / Then scenario and the smallest trigger. Name the regression test that verifies each observable outcome, or describe the manual acceptance step when automation cannot cover it. State what happened before the fix.

## Validation

- Tested commit:
- Local commands and results:
- Unrun, blocked or pending checks:
- Forgejo gate required: yes / no

For UI findings, include the Linux distribution, desktop and display protocol, BookiE commit and install method, and database/version when relevant. Redact secrets and private data from logs and screenshots.
