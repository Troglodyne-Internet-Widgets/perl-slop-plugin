# CLAUDE.md

This is the `perl-slop` Claude Code plugin. It provides Perl
development skills, not application code. The deliverables are markdown
skill files, not compiled binaries.

## What This Project Produces

Markdown skill files in `skills/` and command files in `commands/` that
Claude Code loads as a plugin. Each skill teaches Claude how to perform
a specific Perl development task correctly.

## Conventions

- Every skill file starts with YAML frontmatter (`name`, `description`)
- Skills announce themselves: "I'm using the perl:<name> skill..."
- Runtime skills include `perl:require-toolchain` as a prerequisite
- Writing skills are version-specific — the `write-perl.md` command dispatches
