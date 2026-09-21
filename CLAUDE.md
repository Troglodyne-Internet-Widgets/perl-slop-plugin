# perl-slop-plugin

## Releasing

A release changes two repositories: this one and the marketplace, `Troglodyne-Internet-Widgets/claude-plugins-marketplace`. The marketplace pins the plugin version, so a tag here does not reach installs by itself.

1. Merge or commit the changes to `master` first.
2. Bump `version` in `.claude-plugin/plugin.json`. Change nothing else in that commit.
3. Commit it as `Release X.Y.Z`. In the body, say why the release is minor or patch, and summarize what changed.
4. Make an annotated tag: `git tag -a perl-slop--vX.Y.Z -m "perl-slop X.Y.Z"`.
5. Push `master` and the tag: `git push origin master perl-slop--vX.Y.Z`.
6. In a clone of the marketplace, bump the perl-slop `version` in `.claude-plugin/marketplace.json`.
7. Commit it as `perl-slop X.Y.Z`, and push it to `master`.
8. Refresh the marketplace: `claude plugin marketplace update troglodyne-marketplace </dev/null`.
9. Update the plugin: `claude plugin update perl-slop@troglodyne-marketplace </dev/null`.
10. Restart Claude Code to load the new version.

Close standard input on both of those. If you run step 8 from inside a Claude Code session with stdin open, it hangs. It looks like a slow clone until something kills it. With `</dev/null` it finishes in seconds. Step 9 has not hung, and takes the redirect for the same reason.

If a release adds a skill or a gate, or widens what a gate refuses, use a minor version. For fixes and wording, use a patch version.
