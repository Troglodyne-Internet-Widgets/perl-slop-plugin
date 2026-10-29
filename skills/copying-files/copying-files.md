---
name: copying-files
trigger: A command is about to copy a tree with rsync, cp -r, cp -R, cp -a, scp -r or dd.  Or a command is about to extract an archive with tar.  Or you need a scratch copy of a checkout or a site.
description: |
  Measure a copy, and the free space where it goes, before you run it.  A
  copy that does not fit fills the filesystem, and while a disk is full,
  every write to it by any other process fails.  A scratch copy of a
  checkout once filled the root filesystem of a host, because it took a
  media directory of 20 GB.  The copy that the work needed was 9.5 MB.
---

# Copying files without filling the disk

The hooks of this plugin ask for this skill before a Bash command that copies
a tree.  These commands count: `rsync`, `dd`, `scp -r`, a `tar` that extracts,
and `cp` with `-r`, `-R` or `-a`.

A copy of a tree moves everything under it, and the size of a tree is not in
its name.  A checkout of a web application can hold media, uploads or a cache.
Those can be a thousand times the size of the code.
When the copy is bigger than the free space, it fills the filesystem.  Then
every write to that filesystem fails, for every process on the host, until
something deletes files.  Logs, databases and other sessions fail with you.

This happened in one session.  The agent needed a scratch copy of a checkout,
and ran this:

```sh
rsync -a --exclude .git --exclude www/static "$checkout/" "$scratch/"
```

The checkout held a media directory of about 20 GB, under a path that the
excludes did not name.  The filesystem of `$scratch` had about 20 GB free.
rsync stopped with this error:

```
rsync: [receiver] write failed on "$scratch/www/assets/$file.m4v": No space left on device (28)
```

The agent deleted the partial copy at once, and the free space came back.
The copy that the work needed was 9.5 MB, with the media excluded.

## Before the copy

1. Measure what the copy will move, with the same excludes that the copy
   uses.  For rsync, run the same command with `--dry-run --stats`, and read
   "Total transferred file size".  For `cp`, `scp` and `dd`, use `du -sh` on
   the source.  For `tar`, use `tar -tvf` and add the sizes, or use the size
   of the archive as a lower limit.
2. Run `df -h` on the destination, and find the free space of its
   filesystem.  The destination can be on a different filesystem than its
   parent, so run `df` on the directory itself, or on its nearest parent
   that exists.
3. If the copy does not fit with a margin, stop.  Exclude more, or choose a
   different destination.  A margin of half the free space is a good start,
   because other processes write to the same filesystem while the copy runs.

For rsync, the measurement is the same command with two more flags:

```sh
rsync -a --dry-run --stats --exclude .git "$src/" "$dst/" | grep 'Total transferred file size'
df -h "$dst"
```

If the dry run lists a directory that you did not expect, read
`du -sh "$src"/*` to find what is big.

## A scratch copy needs the code, not the data

A scratch copy of a site or of a checkout seldom needs its media, its
uploads, its caches or its build output.  So exclude those directories by
default.  If the work needs them, add them back one at a time.

Before you copy a checkout, look at what it holds:

```sh
du -sh "$src"/* "$src"/.[!.]* 2>/dev/null | sort -h | tail
```

If you need only the files that git tracks, copy those, and nothing else:

```sh
git -C "$src" ls-files -z | rsync -a --from0 --files-from=- "$src/" "$dst/"
```

A `git worktree add` or a `git clone` of the checkout also gives you the
tracked files only, without a copy of the rest.

## If the disk fills

Delete the partial copy at once.  Then run `df -h` again, and make sure that
the free space came back.  Tell the user that the disk was full, and for how
long.  Other processes on the host can fail while the disk is full.
