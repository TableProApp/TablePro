# User contexts

These role descriptions identify the workflows and constraints the product must support. They are design tools, not demographic profiles or claims about every user. Product rules remain in [PRODUCT.md](../PRODUCT.md) and accepted [ADRs](decisions/README.md).

| Context | Typical task | Important constraints |
|---|---|---|
| Database operator | Connect to a database, inspect schemas and rows, run SQL, and make controlled changes. | Local operation, explicit query outcomes, preserved values, safe credential storage, and clear limits when the engine cannot provide an exact result. |
| MCP operator | Configure a local agent process to access selected database tools. | Least-privilege token scopes, connection allowlists, rate limits, policy checks, result masking, and auditable outcomes. |
| Package user | Install and run a supported Linux package without building the source tree. | Stable application identity and data paths, documented platform requirements, and a launch command supplied by the package. |
| Package maintainer | Build, inspect, and distribute application packages. | Reproducible inputs, dependency notices, correct package contents, and compatibility with existing identifiers and user data. |

## Design checks

- Can the workflow complete locally without account creation or remote entitlement checks?
- Does the interface distinguish an empty value, SQL NULL, an unsupported value, and an unknown operation outcome?
- Can the user tell which records are loaded, filtered, truncated, pending, or still being processed?
- Does cancellation reach the database operation, and does the result describe uncertainty honestly?
- Can an agent access only the tools and connections granted to its token while still passing through SQL policy?
- Can a package be upgraded or rolled back without changing the application's stored identity or deleting user data?

These checks inform product and architecture decisions. They do not replace the regression tests, driver fixtures, or installed desktop acceptance required by [AGENTS.md](../AGENTS.md).
