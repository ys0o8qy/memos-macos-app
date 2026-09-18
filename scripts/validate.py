#!/usr/bin/env python3
"""Layered validation with per-stage timings, sharing the same commands with CI."""
import argparse
import ast
import datetime
import json
import os
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent


def preflight():
    subprocess.run(['git', 'diff', '--check'], cwd=ROOT, check=True)
    for script in (ROOT / 'scripts').glob('*.sh'):
        subprocess.run(['bash', '-n', str(script)], check=True)
    for script in (ROOT / 'scripts').rglob('*.py'):
        ast.parse(script.read_text(), filename=str(script))
    subprocess.run(['plutil', '-lint', str(ROOT / 'Resources/Info.plist')], check=True)
    subprocess.run(['/usr/bin/ruby', '-e', 'require "yaml"; YAML.load_file(ARGV[0]); puts "Workflow YAML OK"',
                    str(ROOT / '.github/workflows/package-dmg.yml')], check=True)
    subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'scripts/tests'], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['quick', 'test', 'package'], nargs='?', default='test')
    args = parser.parse_args()
    os.chdir(ROOT)
    folder = ROOT / '.build' / 'validation'
    folder.mkdir(parents=True, exist_ok=True)
    report = {'mode': args.mode, 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'head_sha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()), 'stages': []}
    commands = [('preflight', None)]
    if args.mode in ('test', 'package'):
        commands.append(('tests', ['bash', 'scripts/test.sh']))
    if args.mode == 'package':
        commands.extend([('build', ['bash', 'scripts/build-app.sh']), ('dmg', ['bash', 'scripts/package-dmg.sh'])])
    exit_code = 0
    for name, command in commands:
        print(f'::group::{name}' if os.environ.get('GITHUB_ACTIONS') else f'[{name}]', flush=True)
        start = time.monotonic()
        try:
            if command is None:
                preflight()
            else:
                environment = dict(os.environ)
                if name == 'dmg':
                    environment['SKIP_BUILD'] = '1'
                subprocess.run(command, env=environment, check=True)
        except (OSError, ValueError, SyntaxError, subprocess.CalledProcessError) as error:
            print(f'{name} failed: {error}', flush=True)
            exit_code = 1
        stage = {'name': name, 'seconds': round(time.monotonic() - start, 2), 'success': exit_code == 0}
        report['stages'].append(stage)
        (folder / 'latest.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{name}: {stage['seconds']}s", flush=True)
        if os.environ.get('GITHUB_ACTIONS'):
            print('::endgroup::', flush=True)
        if exit_code:
            break
    if not exit_code and args.mode == 'package':
        (ROOT / 'dist/BUILD_TIMINGS.json').write_text(json.dumps(report, indent=2) + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            output.write('\n| Validation stage | Seconds | Passed |\n|---|---:|---|\n')
            for stage in report['stages']:
                output.write(f"| {stage['name']} | {stage['seconds']} | {stage['success']} |\n")
    print(f'Report: {folder / "latest.json"}', flush=True)
    raise SystemExit(exit_code)


if __name__ == '__main__':
    main()
