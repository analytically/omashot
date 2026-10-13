# Listing Snapmenu on plugins.omarchy.org

The marketplace is repository-based. It reads `manifest.json` from the root of the
public GitHub repository, validates **one exact commit**, runs a static security
baseline over that commit without executing any of it, and a maintainer approves
the listing. Nothing in the marketplace runs plugin code, and approval is a
listing decision rather than a security review.

## What the repository must contain

| Requirement | Here |
|---|---|
| Public GitHub repository, repository root URL | `https://github.com/analytically/snapmenu` |
| `manifest.json` at the repository root | yes, and `omarchy plugin validate .` passes |
| README with installation **and removal** instructions | `## Install`, `## Uninstall` |
| Root license file | `LICENSE`, MIT |
| External dependencies documented | `### Requirements` in the README |
| One plugin per repository, globally unique id outside `omarchy.*` | `io.github.analytically.snapmenu` |
| Optional root preview, one of `preview.png` / `.jpg` / `.jpeg` / `.webp` / `.avif` | `preview.png` |

The preview is processed automatically — no manual resizing or compression, up to
50 MB and 40 megapixels. Ours is 1454×1138 and about 150 KB.

## Submitting it

Open [the submission form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml),
or file the issue from the CLI with the body below. Keep all six headings, in this
order, and keep the checklist text as it is. The title must start with `[Plugin]:`.

Category and tags are chosen from the marketplace's own lists — the category is
case-sensitive and must match its spelling exactly:

- **Category:** `Productivity` — the marketplace's own category list. The manifest's
  `barWidget.category` (`Utilities`) is a different field: the token the bar uses to
  group its widgets, not the marketplace's taxonomy.
- **Tags:** `bar`, `quickshell`, `system`

```markdown
### Repository URL
https://github.com/analytically/snapmenu

### Category
Productivity

### Tags
bar, quickshell, system

### Suggest a missing tag
_No response_

### Maintainer notes
Screenshot menu for the Omarchy bar: a capture menu (area, window, screen,
previous area, self-timer), a frozen-frame picker with drag constraints, and an
action card with a capture history. Optional native clipboard helper written in
Rust; everything else is shell and QML.

### Submission checklist
- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
```

Automated validation and the security baseline report on the issue; a maintainer
then applies `approved-and-verified` to publish.

## Keeping it current

The marketplace inspects the branch head for compatibility on a schedule, but the
security baseline is bound to the commit that was approved. Once the branch moves,
the listing shows **Update unverified**, so each published update is explicitly
re-verified:

1. Bump `version` in `manifest.json` — it is what the marketplace displays, so it
   must change when the code does.
2. Commit, and push to `main`.
3. Note the exact commit: `git rev-parse HEAD` (full 40 characters).
4. Open the [verification form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml),
   choose **Verify and publish a newer upstream commit**, and give the existing
   plugin id (`io.github.analytically.snapmenu`), the repository root URL, and that
   SHA.
5. Validation and the baseline re-run against that commit. A maintainer approves,
   and the snapshot is replaced atomically; the superseded evidence stays in the
   registry's history.

Selectively blocking findings and scan failures block promotion, so they have to
be fixed in a new commit before re-verifying. Nothing else about the listing — its
id, category and tags — changes on an update; the id in particular is permanent.
