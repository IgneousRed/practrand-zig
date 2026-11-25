# Publication boundaries

The public source and independent private records have separate repositories.
Neither may contain `.local`, `.vendor`, `.work`, nested `.private` material,
symlinks, submodules or unclassified paths. Public source also excludes fetched
`vendor` trees and historical private planning/research records. Durable expected
fixtures, original capture provenance, licences and portable acquisition recipes
remain public.

`AGENTS.md`, at the root or any nested path, is always private. Keep active
working copies ignored locally and version instructions only in the private
companion's `instructions/` directory. Public documentation must not depend on
them. Public source exports, packages and outgoing history exclude them.

The independent `.private/` repository holds maintained private records;
`.local/` holds necessary unique machine-only evidence/recovery; `.vendor/`
holds reproducible immutable dependency views; `.work/` is disposable scratch.
Neither repository uploads the other reserved directories. No crucial record
may remain only in `.work/` after a task finishes.

The reviewed `.publication-files` inventory identifies publishable paths.
`.publication-denied-blobs` rejects known fetched/reclassified content even if
copied to another approved path. The guard examines every ancestor tree of the
outgoing ref, not only the current checkout or its latest diff. Changes to this
inventory require classification review; the list is not a substitute for review
of modified content and dependencies.

```sh
scripts/dev scripts/check-publication main
```

The pre-push hook permits only explicit `refs/heads/main` to
`refs/heads/main`. Mirror pushes, backups, application-owned refs, tags and other
branches are not implicitly approved. A shallow clone cannot establish complete
ancestry and is rejected. Enable the hooks after a normal clone with
`git config core.hooksPath .githooks`.

Reclassification includes older published/publishable history. Preserve needed
records at the approved visibility before sanitizing owned outgoing ancestry.
Machine-only recovery and application-owned local history are never publication
inputs and are not rewritten by this process. Remote replacement must first
account for affected owned refs, archives and pinned consumers. Repository
verification does not establish erasure of host caches, pull-request refs, forks
or other clones.
