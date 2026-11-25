"""Compile and validate the Vulkan C8 shader, then embed its SPIR-V in C."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

compiler, validator, source, destination = sys.argv[1:]
destination = Path(destination)
destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='shader-', dir=destination.parent) as directory:
    binary = Path(directory) / 'classification.spv'
    subprocess.run([compiler, '--target-env=vulkan1.1', source, '-o', str(binary)], check=True)
    subprocess.run([validator, '--target-env', 'vulkan1.1', str(binary)], check=True)
    data = binary.read_bytes()
words = struct.unpack('<' + 'I' * (len(data) // 4), data)
lines = [f'/* Generated from {Path(source).name}; do not edit. */',
         f'static const uint32_t {Path(source).stem}_spv[] = {{']
for offset in range(0, len(words), 8):
    lines.append('    ' + ', '.join(f'0x{word:08x}u' for word in words[offset:offset + 8]) + ',')
lines.append('};')
destination.write_text('\n'.join(lines) + '\n')
