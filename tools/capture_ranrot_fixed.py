"""Create new fixed-Ranrot controls from original seed states and Python integers.

Build test/reference_ranrot_state.cpp with tools/build_reference.py first.
Never run this as a test or overwrite an existing fixture.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def words(state, width, fixed=True):
    """Independent mathematical model: width-bounded integers, zero rot = identity."""
    buffer = list(state[:45])
    position, low, high = state[45:]
    mask = (1 << width) - 1
    shift = {32: 13, 64: 29}[width]
    while True:
        if position == 0:
            newest = buffer[-1] ^ low
            low = (low + 1) & mask
            for index in range(45):
                if index == 24:
                    high = (high + (low == 0)) & mask
                    newest ^= high
                if fixed:
                    middle = buffer[(index + 21) % 45]
                    rotated = ((newest << shift) | (newest >> (width - shift))) & mask
                    newest = buffer[index] = ((buffer[index] ^ middle) + rotated) & mask
            position = 45
        position -= 1
        yield buffer[position]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('refusing to overwrite an existing fixture')
    cases = []
    count = 65539
    for width in (32, 64):
        for seed in ('0', 'fedcba98765432100123456789abcdef'):
            number = int(seed, 16)
            captured = subprocess.check_output([str(args.reference.resolve()), str(width),
                                               f'{number & ((1 << 64) - 1):x}', f'{number >> 64:x}'])
            state = [int(word) for word in captured.decode().strip().split(',')]
            assert len(state) == 48
            stream = words(state, width)
            output = b''.join(next(stream).to_bytes(width // 8, 'little')
                              for _ in range((count + width // 8 - 1) // (width // 8)))[:count]
            cases.append(dict(expression=f'ranrot_var{width}_fixed', seed=seed,
                              name=f'ranrot_variant{width}_fixed', width=width,
                              initial_state=state, sha256=hashlib.sha256(output).hexdigest()))
    driver = Path('test/reference_ranrot_state.cpp').read_bytes()
    model = Path(__file__).read_bytes()
    fixture = dict(format_version=1, reference_version='0.96', bytes=count,
                   provenance=dict(reference_archive_sha256='e4caf7fda98b2c597bbda3b576753cf5a0f6047aab837c82be370ab798a672e1',
                                   driver_sha256=hashlib.sha256(driver).hexdigest(), driver_source=driver.decode(),
                                   model_sha256=hashlib.sha256(model).hexdigest(), model_source=model.decode(),
                                   description='Original seed states only; expected stream computed independently with Python integers.'),
                   cases=cases)
    args.output.write_text(json.dumps(fixture, indent=2) + '\n')


if __name__ == '__main__':
    main()
