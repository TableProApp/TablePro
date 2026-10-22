#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.request


REPOSITORY = 'cozyGarage/BookiE'
MANIFEST = 'ci/forgejo-train.json'
REQUIRED_CHECKS = {
    'Linux regression gate', 'harness', 'workflow-lint', 'Security (security-policy)',
    'Security (supply-chain)', 'flatpak-builder (default)',
    'Preflight and sandbox tier (no GTK app)', 'Fast checks (GTK)',
}


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def manifest_members(manifest):
    require(isinstance(manifest, dict), 'train manifest must be an object')
    require(type(manifest.get('version')) is int and manifest['version'] == 1, 'unsupported train manifest version')
    require(isinstance(manifest.get('base'), str) and re.fullmatch(r'[0-9a-f]{40}', manifest['base']),
            'invalid train base SHA')
    members = manifest.get('members', [])
    require(isinstance(members, list) and len(members) >= 2, 'a train needs at least two constituent PRs')
    for member in members:
        require(isinstance(member, dict), 'invalid train member')
        require(type(member.get('number')) is int and member['number'] > 0, 'invalid constituent PR number')
        require(isinstance(member.get('sha'), str) and re.fullmatch(r'[0-9a-f]{40}', member['sha']),
                'invalid constituent head SHA')
    require(len({m['number'] for m in members}) == len(members), 'duplicate constituent PR')
    require(len({m['sha'] for m in members}) == len(members), 'duplicate constituent head')
    return members


def check_results(checks):
    successful = {c['name'] for c in checks if c['state'] == 'SUCCESS'}
    require(REQUIRED_CHECKS <= successful, 'missing or unsuccessful required GitHub checks: '
            + ', '.join(sorted(REQUIRED_CHECKS - successful)))
    for check in checks:
        reference = check['name'] == 'SonarCloud Code Analysis' or check.get('workflow') in {'Sonar Rust', 'CodeQL'}
        require(reference or check['state'] in {'SUCCESS', 'SKIPPED'},
                f"GitHub check has not passed: {check['name']} ({check['state']})")


def check_gate(run, run_id, head):
    require(run.get('id') == run_id and run.get('commit_sha') == head, 'Forgejo run does not match train head')
    require(run.get('workflow_id') == 'ci.yml', 'Forgejo run is not the merge-tier workflow')
    require(run.get('status') == 'success', 'Forgejo train run has not passed')


def pull_request(number):
    return json.loads(command('gh', 'pr', 'view', str(number), '--repo', REPOSITORY, '--json',
                              'number,headRefOid,baseRefName,state,isDraft,reviewDecision,mergeCommit,mergeable'))


def github_checks(number, head):
    result = subprocess.run(['gh', 'pr', 'checks', str(number), '--repo', REPOSITORY,
                             '--json', 'name,state,workflow'], text=True, capture_output=True)
    require(result.returncode in {0, 1, 8}, 'could not read GitHub checks')
    checks = json.loads(result.stdout)
    present = {check['name'] for check in checks}
    if REQUIRED_CHECKS <= present:
        return checks
    endpoint = f'repos/{REPOSITORY}/commits/{head}/check-runs?filter=latest&per_page=100'
    pages = json.loads(command('gh', 'api', '--paginate', '--slurp', endpoint))
    runs = [run for page in pages for run in page['check_runs']]
    for run in sorted(runs, key=lambda item: item['id'], reverse=True):
        name = run['name']
        if name in present or name not in REQUIRED_CHECKS or run.get('app', {}).get('slug') != 'github-actions':
            continue
        require(run.get('head_sha') == head, 'commit check does not match pinned PR head')
        state = (run.get('conclusion') or 'pending').upper() if run['status'] == 'completed' else 'PENDING'
        checks.append({'name': name, 'state': state, 'workflow': 'GitHub Actions'})
        present.add(name)
    return checks


def fetch_head(remote, pr):
    command('git', 'fetch', '--quiet', remote, f"pull/{pr['number']}/head")
    require(command('git', 'rev-parse', 'FETCH_HEAD') == pr['headRefOid'], 'PR head moved while fetching')


def check_open(pr):
    require(pr['state'] == 'OPEN' and not pr['isDraft'], f"PR #{pr['number']} is not an open ready PR")
    require(pr['baseRefName'] == 'linux', 'constituent and aggregate PRs must target linux')
    require(pr['reviewDecision'] != 'CHANGES_REQUESTED', f"PR #{pr['number']} has requested changes")
    require(pr['mergeable'] == 'MERGEABLE', f"PR #{pr['number']} is not confirmed mergeable")
    check_results(github_checks(pr['number'], pr['headRefOid']))


def check_integration(base, head, members):
    commits = command('git', 'rev-list', '--first-parent', '--reverse', f'{base}..{head}').splitlines()
    require(commits and command('git', 'rev-parse', f'{commits[0]}^1') == base,
            'train must start at the pinned linux base')
    integrated = []
    for commit in commits:
        parents = command('git', 'show', '-s', '--format=%P', commit).split()
        require(len(parents) <= 2, 'octopus train merges are unsupported')
        if len(parents) == 2:
            integrated.append(parents[1])
    require(integrated == [m['sha'] for m in members], 'train merge order or constituent heads differ from manifest')


def linux_head():
    return command('gh', 'api', f'repos/{REPOSITORY}/git/ref/heads/linux', '--jq', '.object.sha')


def check_merged_tree(merged, head):
    require(command('git', 'rev-parse', f'{merged}^{{tree}}') == command('git', 'rev-parse', f'{head}^{{tree}}'),
            'merged source tree differs from the tested train; investigate before accepting further changes')


def forgejo_run(run_id):
    remote = command('git', 'remote', 'get-url', 'forgejo')
    match = re.fullmatch(r'(https?://[^/]+)/(.+?)(?:\.git)?', remote)
    require(match is not None, 'Forgejo remote must have an HTTP(S) URL')
    token = Path.home().joinpath('.config/forgejo/token').read_text().strip()
    url = f'{match[1]}/api/v1/repos/{match[2]}/actions/runs/{run_id}'
    request = urllib.request.Request(url, headers={'Authorization': 'token ' + token})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description='Verify immutable aggregate train inputs and acceptance')
    parser.add_argument('pr', type=int)
    parser.add_argument('--phase', choices=('gate', 'merge', 'merged'), default='gate')
    parser.add_argument('--run', type=int)
    parser.add_argument('--remote', default='origin')
    args = parser.parse_args()
    aggregate = pull_request(args.pr)
    head = aggregate['headRefOid']
    fetch_head(args.remote, aggregate)
    if args.phase != 'merged':
        require(command('git', 'rev-parse', 'HEAD') == head, 'checkout is not at the aggregate PR head')
        require(not command('git', 'status', '--porcelain'), 'checkout has uncommitted changes')
    manifest = json.loads(command('git', 'show', f'{head}:{MANIFEST}'))
    members = manifest_members(manifest)
    require(args.pr not in {m['number'] for m in members}, 'aggregate PR cannot contain itself')
    check_integration(manifest['base'], head, members)
    if args.phase != 'gate':
        require(args.run is not None, 'a Forgejo run ID is required')
        check_gate(forgejo_run(args.run), args.run, head)
    if args.phase == 'merged':
        require(aggregate['state'] == 'MERGED', 'aggregate PR has not merged')
        command('git', 'fetch', '--quiet', args.remote, 'linux')
        merged = aggregate['mergeCommit']['oid']
        check_merged_tree(merged, head)
        print(f'train #{args.pr}: merged tree matches gated head {head}')
        return
    require(linux_head() == manifest['base'], 'linux moved; rebuild and gate a new train')
    check_open(aggregate)
    for member in members:
        pr = pull_request(member['number'])
        require(pr['headRefOid'] == member['sha'], f"constituent #{member['number']} moved")
        check_open(pr)
    for member in members:
        current = pull_request(member['number'])
        require(current['headRefOid'] == member['sha'] and current['state'] == 'OPEN'
                and current['reviewDecision'] != 'CHANGES_REQUESTED' and not current['isDraft'],
                f"constituent #{member['number']} changed during verification")
    require(pull_request(args.pr)['headRefOid'] == head and linux_head() == manifest['base'],
            'aggregate head or linux moved during verification')
    print(f'train #{args.pr}: ready for {args.phase} at {head}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'train verification failed: {error}', file=sys.stderr)
        sys.exit(1)
