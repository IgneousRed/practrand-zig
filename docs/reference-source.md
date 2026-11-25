# Official PractRand reference source

The public acquisition declaration is [nix/practrand.json](../nix/practrand.json).
It pins PractRand **0.96** by Chris Doty-Humphrey (orz):

1. Archive: `PractRand_0.96.zip`.
2. URL: <https://downloads.sourceforge.net/project/pracrand/PractRand_0.96.zip>.
3. Archive SHA-256: `e4caf7fda98b2c597bbda3b576753cf5a0f6047aab837c82be370ab798a672e1`.
4. Normalized source NAR: `sha256-QzW59QGHIM2G08Ne+WuESxJtglEPdRTGb4YBcAW2vgY=`.
5. Licence: [unchanged PractRand licence](../LICENSES/PractRand.txt).

The [Nix recipe](../nix/practrand.nix) verifies the archive and the complete
source output. It preserves all 136 release files byte-for-byte. Empty Visual C
build-output directories, which Git did not retain, are omitted from the view.
No official release source is patched in place.

Builds, full tests and explicit reference tools acquire this source when they
need it. `scripts/dev --eval`, dependency version checks and commands that do not
use reference source do not acquire it. To obtain the source explicitly:

```sh
scripts/dev python3 -B tools/acquire_reference.py
```

The helper registers `.vendor/PractRand` as a persistent GC-rooted view into the
immutable Nix source output. This directory is ignored by both repositories.
Deleting `.work` does not remove the source root. If the view is removed, the
next consumer recreates it using the same hashes. An unexpected or mutable tree
at that path is rejected rather than overwritten. Source output identity is
shared across the declared systems and across fresh checkout/export locations.

Mutable diagnostic copies, objects and executables belong in `.work`. The
reference builder copies compiler inputs before building; capture instrumentation
changes only its isolated copy. The native generator adapter includes unchanged
official RNG implementations and defines approved local remedies separately.

Existing expected fixtures and their provenance remain tracked under `test/`.
Historical provenance keys beginning `vendor/PractRand/` describe the capture's
original path; resolve that prefix to `.vendor/PractRand/` when inspecting the
same pinned bytes now. Acquisition does not regenerate or rewrite expectations.
A different upstream release requires a separate explicit compatibility decision.
