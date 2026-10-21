# Public documentation language review, October 21

## Scope

Reviewed the 198 tracked Markdown files listed by `git ls-files '*.md'` at BookiE `c18b8626e`. Screening covered root documents, contributor instructions, application documentation, specs, current docs, archives and evidence summaries. Searches targeted first-person review notes, personal references, competitive rankings, unsupported comparative claims and upstream-alignment language. Matching passages were inspected in context. This was a language review, not a fresh technical audit or a sentence-by-sentence proof of every historical claim.

## Editorial changes

- State the independent capability-selection rule in the existing capability review: product goals, accepted contracts and demonstrated user benefit determine adoption.
- Describe implementation behavior and evidence instead of relative project standing or release-speed judgments.
- Remove first-person research narration and the reference to an individual's language skills.
- Preserve project names when they identify a source, dependency, protocol, product boundary or contribution destination.
- Preserve dated source pins, numerical evidence, issue ownership and ADR decisions. Archived prose received editorial corrections under the maintainer's explicit request; those changes do not update historical implementation status.
- Keep user-guide instructions addressed to the reader where that helps explain an action. Those instructions do not evaluate a person or organization.

## Exclusions and checks

License text, copyright/attribution notices, the Code of Conduct pledge, third-party notices and raw captured logs were not rewritten for tone. Code, tests, runtime strings and package metadata were outside the documentation edit. Code examples, source titles and technical terms such as naive timestamps are not editorial rankings.

Validation: documentation links, known-issue index and ignored-test registration checks. No product test or build was needed for these wording changes. Remaining subjective phrasing may require context-specific review; keyword screening is not a universal language guarantee.
