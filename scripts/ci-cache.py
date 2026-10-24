#!/usr/bin/env python3
import argparse
import fcntl
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def open_directory(name, parent=None):
    return os.open(name, DIRECTORY_FLAGS, dir_fd=parent)


def metadata(name, directory):
    try:
        return os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return None


def mark_used(root):
    target = os.environ.get('CARGO_TARGET_DIR')
    if not target:
        return
    target = Path(target)
    if not target.is_absolute() or target.parent != root or target.name in ('.', '..'):
        raise ValueError('CARGO_TARGET_DIR must be a direct child of the cache root')
    with_directory = open_directory(root)
    try:
        try:
            os.mkdir(target.name, dir_fd=with_directory)
        except FileExistsError:
            pass
        job = open_directory(target.name, with_directory)
        try:
            marker = os.open('.bookie-last-used', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=job)
            try:
                if not stat.S_ISREG(os.fstat(marker).st_mode):
                    raise ValueError('cache usage marker must be a regular file')
                os.utime(marker, None)
            finally:
                os.close(marker)
        finally:
            os.close(job)
    finally:
        os.close(with_directory)


def prune_job(job, cutoff):
    marker = metadata('.bookie-last-used', job)
    if marker is None or not stat.S_ISREG(marker.st_mode) or marker.st_mtime >= cutoff:
        return
    for profile in ('debug', 'release', 'ci'):
        entry = metadata(profile, job)
        if entry is None or not stat.S_ISDIR(entry.st_mode):
            continue
        directory = open_directory(profile, job)
        try:
            cargo_lock = metadata('.cargo-lock', directory)
            deps = metadata('deps', directory)
            generated = cargo_lock and stat.S_ISREG(cargo_lock.st_mode) and deps and stat.S_ISDIR(deps.st_mode)
        finally:
            os.close(directory)
        if generated:
            shutil.rmtree(profile, dir_fd=job)
            print(f'removed generated {profile} artifacts', flush=True)


def prune(root, cutoff, reserve=None, least_recent_first=False):
    directory = open_directory(root)
    try:
        names = os.listdir(directory)
        if least_recent_first:
            marked = []
            for name in names:
                entry = metadata(name, directory)
                if entry is None or not stat.S_ISDIR(entry.st_mode):
                    continue
                job = open_directory(name, directory)
                try:
                    marker = metadata('.bookie-last-used', job)
                    if marker is not None and stat.S_ISREG(marker.st_mode):
                        marked.append((marker.st_mtime, name))
                finally:
                    os.close(job)
            names = [name for _, name in sorted(marked)]
        else:
            names.sort()
        for name in names:
            if reserve is not None and shutil.disk_usage(root).free >= reserve:
                return
            entry = metadata(name, directory)
            if entry is None or not stat.S_ISDIR(entry.st_mode):
                continue
            job = open_directory(name, directory)
            try:
                prune_job(job, cutoff)
            finally:
                os.close(job)
    finally:
        os.close(directory)


def cleanup(root, reserve):
    before = shutil.disk_usage(root).free
    print(f'free before cleanup: {before} bytes', flush=True)
    now = time.time()
    prune(root, now - 5 * 86400)
    if shutil.disk_usage(root).free < reserve:
        prune(root, now - 86400, reserve)
    if shutil.disk_usage(root).free < reserve:
        prune(root, float('inf'), reserve, least_recent_first=True)
    after = shutil.disk_usage(root).free
    print(f'free after cleanup: {after} bytes; required reserve: {reserve} bytes', flush=True)
    if after < reserve:
        print('cache cleanup could not recover the required reserve', file=sys.stderr)
        return 1
    return 0


def run_script(script):
    child = subprocess.Popen(
        ['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', script],
        start_new_session=True,
    )

    def forward_signal(signum, _frame):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    handlers = {signum: signal.signal(signum, forward_signal) for signum in signals}
    try:
        returncode = child.wait()
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
    return 128 - returncode if returncode < 0 else returncode


def main():
    parser = argparse.ArgumentParser(description='Coordinate Forgejo cache use and generated-artifact cleanup')
    parser.add_argument('--root', type=Path, default=Path('/var/cache/ci/target'))
    parser.add_argument('--lock', type=Path, default=Path('/run/bookie-ci/cache.lock'))
    commands = parser.add_subparsers(dest='command', required=True)
    run = commands.add_parser('run')
    run.add_argument('script')
    checkout = commands.add_parser('checkout')
    checkout.add_argument('script')
    checkout.add_argument('--min-free-gib', type=int, default=45)
    maintenance = commands.add_parser('cleanup')
    maintenance.add_argument('--min-free-gib', type=int, default=45)
    args = parser.parse_args()
    root = Path(os.path.abspath(args.root))
    lock = os.open(args.lock, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(lock).st_mode):
            raise ValueError('cache lock must be a regular file')
        if args.command == 'run':
            fcntl.flock(lock, fcntl.LOCK_SH)
            mark_used(root)
            return run_script(args.script)
        if args.min_free_gib < 0:
            raise ValueError('minimum free space cannot be negative')
        if args.command == 'checkout':
            reserve = args.min_free_gib * 1024**3
            fcntl.flock(lock, fcntl.LOCK_SH)
            if shutil.disk_usage(root).free >= reserve:
                mark_used(root)
                return run_script(args.script)
            fcntl.flock(lock, fcntl.LOCK_UN)
            fcntl.flock(lock, fcntl.LOCK_EX)
            status = cleanup(root, reserve)
            if status:
                return status
            fcntl.flock(lock, fcntl.LOCK_SH)
            mark_used(root)
            return run_script(args.script)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('cache busy; cleanup skipped')
            return 0
        return cleanup(root, args.min_free_gib * 1024**3)
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f'cache maintenance failed: {error}', file=sys.stderr)
        sys.exit(1)
