# TablePro Documentation

Source files for the [TablePro documentation site](https://docs.tablepro.app), powered by [Mintlify](https://mintlify.com).

## Structure

```
docs/
├── index.mdx                # Introduction
├── quickstart.mdx           # Getting started guide
├── installation.mdx         # Installation instructions
├── changelog.mdx            # Release changelog
├── databases/               # Database connection guides
├── features/                # Feature documentation
├── customization/           # Settings and customization
├── external-api/            # URL scheme, MCP, pairing
└── development/             # Developer documentation
```

## Local Development

Install the [Mintlify CLI](https://www.npmjs.com/package/mint) and start the dev server:

```bash
npm i -g mint
mint dev
```

Preview at `http://localhost:3000`.

## Deployment

Changes pushed to the default branch are deployed automatically via the [Mintlify GitHub app](https://dashboard.mintlify.com/settings/organization/github-app).
