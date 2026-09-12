# nExBot Upstream

This experimental integration vendors nExBot from:

- Repository: https://github.com/mCodex/nExBot
- Commit: `19632d414405e0e9087a11492e39274b14bdfa2d`
- Retrieved: 2026-09-12

Xibat adaptations replace bot-package selector lookups with the fixed `nExBot`
package name. The upstream updater, private-script loader, and usage analytics are
disabled so the built-in bot does not download or execute additional code and does
not report usage to a third party.

The upstream README labels the project as MIT, but this revision does not contain a
`LICENSE` file. Resolve the licensing discrepancy before distributing these files.
