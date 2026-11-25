"""Select the optional locked Vulkan environment without changing frozen jobs."""
from pathlib import Path
import os
import subprocess
import sys

from job_runtime import active_environment

ROOT = Path(__file__).resolve().parents[1]


def required(arguments):
    """Use only Zig build options, respecting repeated flags and runtime args."""
    enabled, explicit_sdk = False, False
    for argument in arguments:
        if argument == '--':
            break
        if argument == '-Dvulkan' or argument.startswith('-Dvulkan='):
            enabled = argument in ('-Dvulkan', '-Dvulkan=true')
        if argument.startswith('-Dvulkan-sdk='):
            explicit_sdk = True
    return enabled and not explicit_sdk


def run(command):
    active_environment()
    if os.environ.get('VULKAN_SDK'):
        # An active or explicitly recorded SDK is already part of this caller's
        # contract. Never replace it with a newly selected environment.
        return subprocess.run(command, cwd=ROOT).returncode
    return subprocess.run([
        str(ROOT / 'scripts/dev'), '--profile', 'vulkan', *command,
    ], cwd=ROOT).returncode


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('usage: scripts/vulkan COMMAND [ARG ...]')
    sys.exit(run(sys.argv[1:]))
