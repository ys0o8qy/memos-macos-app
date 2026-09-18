#!/usr/bin/env python3
"""Wait for the current commit's PR build, download once, and verify its DMG."""
import argparse
import json
import pathlib
import re
import subprocess
import time

from verify_dmg import verify

ROOT = pathlib.Path(__file__).resolve().parent.parent


def repository_from_origin(origin):
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?/?', origin.strip())
    if not match:
        raise ValueError('Cannot infer GitHub repository from origin; specify --repo OWNER/REPO')
    return match.group(1)


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def gh_json(*arguments):
    return json.loads(output('gh', *arguments))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo')
    parser.add_argument('--commit', help='Defaults to local HEAD; old builds are rejected')
    parser.add_argument('--run', type=int, help='Inspect a specific run, still requiring the expected commit')
    parser.add_argument('--wait', action='store_true')
    parser.add_argument('--timeout', type=int, default=1200)
    args = parser.parse_args()
    try:
        repo = args.repo or repository_from_origin(output('git', 'remote', 'get-url', 'origin'))
        if not re.fullmatch(r'[\w.-]+/[\w.-]+', repo):
            raise ValueError('Expected --repo OWNER/REPO')
        commit = output('git', 'rev-parse', args.commit or 'HEAD')
        deadline = time.monotonic() + args.timeout
        run_id = args.run
        previous = None
        while True:
            if run_id is None:
                runs = gh_json('run', 'list', '--repo', repo, '--commit', commit, '--event', 'pull_request',
                               '--limit', '30', '--json', 'databaseId,workflowName')
                candidates = [run for run in runs if run['workflowName'] == 'Build macOS DMG']
                if candidates:
                    run_id = candidates[0]['databaseId']
            run = None
            if run_id is not None:
                run = gh_json('run', 'view', str(run_id), '--repo', repo, '--json', 'status,conclusion,headSha,url,jobs')
                if run['headSha'] != commit:
                    raise ValueError('Workflow run does not match the requested commit')
                active = [step['name'] for job in run['jobs'] for step in job.get('steps', []) if step['status'] == 'in_progress']
                state = f"{run['status']}: {', '.join(active) or run['conclusion'] or 'waiting for runner'}"
            else:
                state = 'Waiting for a PR build for this commit'
            if state != previous:
                print(state, flush=True)
                previous = state
            if run and run['status'] == 'completed':
                if run['conclusion'] != 'success':
                    raise ValueError(f"Build {run['conclusion']}: {run['url']}")
                break
            if not args.wait:
                raise ValueError('Build is not ready; use --wait to follow it')
            if time.monotonic() >= deadline:
                raise ValueError('Timed out waiting for the build')
            time.sleep(min(15, max(0, deadline - time.monotonic())))

        artifacts = gh_json('api', f'repos/{repo}/actions/runs/{run_id}/artifacts')['artifacts']
        artifacts = [item for item in artifacts if item['name'].startswith('Memos-DMG-')]
        if len(artifacts) != 1:
            raise ValueError('Expected exactly one Memos DMG artifact')
        artifact = artifacts[0]
        destination = ROOT / '.build' / 'ci-artifacts' / str(run_id)
        marker = destination / 'download.json'
        if not marker.exists():
            if artifact['expired']:
                raise ValueError('Artifact has expired; rerun the workflow')
            if destination.exists():
                raise ValueError(f'Incomplete previous download at {destination}; move it aside before retrying')
            destination.mkdir(parents=True)
            subprocess.run(['gh', 'run', 'download', str(run_id), '--repo', repo, '--name', artifact['name'],
                            '--dir', str(destination)], cwd=ROOT, check=True)
            marker.write_text(json.dumps({'artifact_id': artifact['id']}) + '\n')
        elif json.loads(marker.read_text())['artifact_id'] != artifact['id']:
            raise ValueError('Cached download belongs to another artifact')
        dmgs = list(destination.glob('*.dmg'))
        if len(dmgs) != 1:
            raise ValueError('Expected exactly one DMG file')
        report = verify(dmgs[0], commit, run_id)
        report['artifact_url'] = f'https://github.com/{repo}/actions/runs/{run_id}/artifacts/{artifact["id"]}'
        (destination / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"Verified {commit}\nDMG: {dmgs[0]}\nDownload: {report['artifact_url']}\nReport: {destination / 'verification.json'}")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'CI artifact check failed: {error}\n')


if __name__ == '__main__':
    main()
