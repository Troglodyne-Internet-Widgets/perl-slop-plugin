#!/bin/bash
# Copy the fixture into the workspace of the run, as one commit of a
# repository, so that the run has a history to read and a branch to commit to.
set -euo pipefail
cp -a "$(dirname "$0")/fixture/." .
git init -q -b sweep-quiet-dryrun
git config user.name 'Jane Doe'
git config user.email 'jane@test.test'
git add -A
git commit -q -m 'Add Scratch::Sweep, which removes a file or says that it would'
