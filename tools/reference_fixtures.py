"""Concatenate original-reference JSON records without changing their contents."""
import argparse
import json
from pathlib import Path


def json_bytes(value):
    # This is also the original checkpoint publication format. Reconstructing
    # each record with it preserves the hashes in the accepted summary.
    return (json.dumps(value, indent=2, allow_nan=False) + '\n').encode()


def concatenate(directory, output):
    records = {}
    for path in sorted(directory.rglob('*.json')):
        data = path.read_bytes()
        value = json.loads(data)
        if json_bytes(value) != data:
            raise ValueError(f'reference record is not in the original JSON format: {path}')
        records[path.relative_to(directory).as_posix()] = value
    if not records:
        raise ValueError('reference directory contains no JSON records')
    # Exclusive creation keeps reproduction from replacing an accepted reference.
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('xb') as stream:
        stream.write(json_bytes({'format_version': 1, 'records': records}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    concatenate(args.directory, args.output)


if __name__ == '__main__':
    main()
