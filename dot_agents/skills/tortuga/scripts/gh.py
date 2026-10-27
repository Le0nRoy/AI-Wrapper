#!/usr/bin/env python3
"""Use Tortuga's existing App token for gh, without storing credentials.

Usage: gh.py [--repo OWNER/REPO] issue|pr|run|repo ...
The default target is the current directory's GitHub origin, never Tortuga itself.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

DEFAULT_HOME = Path('/Data/Everything/ProgrammingWorkspace/Tortuga-Infra/Tortuga-AI')


def validate_repo(value):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value):
        raise ValueError('Expected explicit OWNER/REPO')
    if any(part in {'.', '..'} for part in value.split('/')):
        raise ValueError('Invalid repository identity')
    return value


def repo_from_remote(remote):
    remote = remote.strip()
    if remote.startswith('git@github.com:'):
        value = remote[len('git@github.com:'):]
    else:
        parsed = urlsplit(remote)
        if parsed.hostname != 'github.com' or parsed.scheme not in {'https', 'ssh'}:
            raise ValueError('Not a supported GitHub origin; pass --repo OWNER/REPO')
        value = parsed.path.lstrip('/')
    if value.endswith('.git'):
        value = value[:-4]
    return validate_repo(value)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', help='Explicit OWNER/REPO; otherwise resolve current Git origin')
    parser.add_argument('command', choices=['issue', 'pr', 'run', 'repo'])
    parser.add_argument('args', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.repo:
            repo = validate_repo(args.repo)
        else:
            result = subprocess.run(['git', 'remote', 'get-url', 'origin'], capture_output=True, text=True, timeout=10)
            if result.returncode:
                raise ValueError('No Git origin here; pass --repo OWNER/REPO')
            repo = repo_from_remote(result.stdout)
        # One target only: prevent overrides hidden among forwarded gh arguments.
        if any(a in {'-R', '--repo'} or a.startswith('--repo=') or a.startswith('-R') for a in args.args):
            raise ValueError('Set the target using this wrapper\'s leading --repo only')
        if args.command == 'repo' and args.args:
            raise ValueError('repo only shows the resolved target; use issue/pr/run for operations')
        home = Path(os.environ.get('TORTUGA_HOME', str(DEFAULT_HOME))).expanduser()
        token = subprocess.run(['make', '-s', 'get-github-token', 'REPO=' + repo], cwd=home,
                               capture_output=True, text=True, timeout=45)
        if token.returncode:
            print('Tortuga App token unavailable for ' + repo + '; check App installation and local setup.', file=sys.stderr)
            return 1
        value = token.stdout.strip()
        if not value or any(ch.isspace() for ch in value):
            raise ValueError('Token target returned an invalid single credential; value withheld')
        env = os.environ.copy()
        env.update(GH_TOKEN=value, GH_PROMPT_DISABLED='1')
        if args.command == 'repo':
            command = ['gh', 'repo', 'view', repo, '--json', 'nameWithOwner,url,isArchived']
        else:
            if not args.args:
                raise ValueError('Specify a gh subcommand, e.g. issue list')
            command = ['gh', args.command, *args.args, '--repo', repo]
        return subprocess.run(command, env=env).returncode
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        # Never include captured token stdout or subprocess argv with credentials.
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
