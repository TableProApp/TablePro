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
├── integrations/            # Using TablePro with other tools
├── developers/              # Build an integration, API reference, directory listing
└── development/             # Contributing
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

## License

The pages in this directory are covered by the repository's [AGPLv3 license](../LICENSE), like the rest of TablePro. The TablePro name and logo, including `logo/` and `favicon.png`, are trademarks of Ngo Quoc Dat and are not licensed under it. Screenshots of other products belong to their owners.
