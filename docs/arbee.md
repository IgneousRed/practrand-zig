# Arbee generator

[`Arbee` in auxiliary.zig](../src/auxiliary.zig) implements PractRand 0.96's
deterministic Arbee operations. The classification transform uses this same type.
Every `[C8]` stream initializes it with the fixed OddPhi low seed word
`0x9e3779b97f4a7c15` and a zero high word, on both CPU and GPU. The seed is defined
by `classification_seed` in `expanded.zig` and is independent of stdin's `-seed`
report label. See [the seeding departure](departures-from-upstream.md#d017--fixed-c8-seed).

```zig
const Arbee = @import("auxiliary.zig").Arbee;

var random = Arbee.init(42);
const word = random.next(); // Same as raw64().
_ = word;

random.seed(42, 123); // Both 64-bit seed words; discards eight outputs.
random.addEntropy64(0x0123456789abcdef);
random.addEntropy("additional input");
random.flushBuffers(); // Discards seven outputs.
```

`init(seed)` uses a zero high seed word. `initSeeded(low, high)` accepts both
seed words. `initEntropy()` and `resetEntropy()` select upstream's fixed initial
entropy-accumulator state; these operations are deterministic and do not acquire
system entropy. A raw `Arbee{}` retains the existing zero-state field defaults.
Call an initializer for the corresponding upstream constructor behavior.

`raw8`, `raw16`, and `raw32` return the low bits of a fresh 64-bit output,
consuming a complete generator step per call. `raw64` and `next` return the
complete word. Arithmetic and the counter wrap modulo 2^64.

`[C8]` uses `TieBits` in `classification.zig` to consume all 64 bits of each
Arbee output, lowest bit first. Each 16-byte input block reserves eight bits for
its eight classification decisions, even when no count is tied. One Arbee word
therefore supplies eight classifications (128 input bytes), independently of the
input values. Unconsumed bits remain available across calls, checkpoints, and
CPU/GPU handoffs. Scalar CPU work takes one tie byte, vector CPU work takes four,
and GPU staging takes two; all read the same consecutive byte stream.
See [the consumption departure](departures-from-upstream.md#d018--c8-uses-every-arbee-output-bit).

The scalar entropy methods are `addEntropy8`, `addEntropy16`, `addEntropy32`,
and `addEntropy64`. `addEntropy(bytes)` matches upstream's `add_entropy_N`: it
reads little-endian 64-bit words followed by an optional 32-bit word, 16-bit
word, and byte. Input alignment does not matter. Call boundaries do matter:
mixing two slices separately can differ from mixing their concatenation.

Seeds and entropy are explicit inputs. OS entropy acquisition and upstream's
polymorphic RNG/state-walker framework are outside this module. This implements
the generator API; the CLI's supported inputs remain documented in
[the feature-subset record](departures-from-upstream.md#d001--supported-feature-subset).

## Reference checks

Tests in `auxiliary.zig` use four-word vectors captured from the unchanged
vendored `Raw::arbee`. Regenerate the reference output with:

```sh
python3 -B tools/build_reference.py --driver test/arbee_vectors.cpp \
  --output .work/arbee/vectors
.work/arbee/vectors
```

The driver covers zero, one, all-one and distinct low/high seeds, default reset,
byte inputs of every length from 0 through 32, a scalar entropy sequence,
flushing, and an all-one raw state including the counter. Zig checks also cover
every byte alignment modulo eight and narrow-output consumption.

Run the isolated tests with `python3 -B tools/zig_run.py test src/auxiliary.zig`.
They also run through the project's [unit and full test commands](testing.md).
