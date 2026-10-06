# perl-slop-plugin

## Releasing

A release changes two repositories: this one and the marketplace, `Troglodyne-Internet-Widgets/claude-plugins-marketplace`. The marketplace pins the plugin version, so a tag here does not reach installs by itself.

1. Merge or commit the changes to `master` first.
2. Run the evals of the skills that changed since the last release: `RELEASE_TESTING=1 prove -v t/release-evals.t`. Each case is a paid Claude session, so the test runs only the skills whose files or cases changed since the last `perl-slop--v*` tag, and stops at its cost cap. It needs `claude` logged in, and `bubblewrap` and `socat` for the sandbox. Do not release while it fails.  In the event that `bwrap` can't make its sandbox, ask the user to run scripts/setup-eval-sandbox.
3. Bump `version` in `.claude-plugin/plugin.json`. Change nothing else in that commit.
4. Commit it as `Release X.Y.Z`. In the body, say why the release is minor or patch, and summarize what changed.
5. Make an annotated tag: `git tag -a perl-slop--vX.Y.Z -m "perl-slop X.Y.Z"`.
6. Push `master` and the tag: `git push origin master perl-slop--vX.Y.Z`.
7. In a clone of the marketplace, bump the perl-slop `version` in `.claude-plugin/marketplace.json`.
8. Commit it as `perl-slop X.Y.Z`, and push it to `master`.
9. Refresh the marketplace: `claude plugin marketplace update troglodyne-marketplace </dev/null`.
10. Update the plugin: `claude plugin update perl-slop@troglodyne-marketplace </dev/null`.
11. Restart Claude Code to load the new version.

Close standard input on both of those. If you run step 9 from inside a Claude Code session with stdin open, it hangs. It looks like a slow clone until something kills it. With `</dev/null` it finishes in seconds. Step 10 has not hung, and takes the redirect for the same reason.

If a release adds a skill or a gate, or widens what a gate refuses, use a minor version. For fixes and wording, use a patch version.
