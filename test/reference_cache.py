"""Reconstructible successful reference captures, published as one atomic file."""
import hashlib
import json
from pathlib import Path
import platform
import tempfile

from reports import checkpoints

CACHE_VERSION = 1


def identity(reference, arguments, generator, first_exponent, last_exponent):
    return {'version': CACHE_VERSION,
            'reference_sha256': hashlib.sha256(Path(reference).read_bytes()).hexdigest(),
            'reference_arguments': arguments,
            'generator_sha256': hashlib.sha256(Path(generator[0]).read_bytes()).hexdigest(),
            'generator_arguments': generator[1:],
            'first_exponent': first_exponent, 'last_exponent': last_exponent,
            'platform': [platform.system(), platform.release(), platform.version()],
            'machine': platform.machine()}


def key(identity):
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()


def load(directory, identity):
    try:
        record = json.loads((Path(directory) / (key(identity) + '.json')).read_text())
        report = record['report']
        expected = list(range(identity['first_exponent'], identity['last_exponent'] + 1))
        if (record['identity'] != identity or record['exit_code'] != 0 or record['stderr']
                or record['bytes_sent'] != 1 << identity['last_exponent']
                or checkpoints(report) != expected
                or hashlib.sha256(report.encode()).hexdigest() != record['report_sha256']
                or len(record['input_sha256']) != 64
                or bytes.fromhex(record['input_sha256']).hex() != record['input_sha256']):
            return None
        return record
    except (OSError, ValueError, KeyError, TypeError):
        return None


def publish(directory, identity, report, input_sha256):
    if checkpoints(report) != list(range(identity['first_exponent'], identity['last_exponent'] + 1)):
        raise ValueError('cannot cache an incomplete reference report')
    if len(input_sha256) != 64 or bytes.fromhex(input_sha256).hex() != input_sha256:
        raise ValueError('reference input checksum must be SHA-256')
    record = {'identity': identity, 'report': report,
              'report_sha256': hashlib.sha256(report.encode()).hexdigest(),
              'input_sha256': input_sha256, 'exit_code': 0, 'stderr': '',
              'bytes_sent': 1 << identity['last_exponent']}
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    # A same-filesystem rename preserves the previous complete capture on failure.
    with tempfile.TemporaryDirectory(prefix='publish-', dir=directory) as staging:
        path = Path(staging) / 'capture.json'
        path.write_text(json.dumps(record, indent=2) + '\n')
        path.replace(directory / (key(identity) + '.json'))
