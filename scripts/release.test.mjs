import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const validator = fileURLToPath(new URL('./validate-release.sh', import.meta.url));
const releaseScript = fileURLToPath(new URL('./release.sh', import.meta.url));
const validate = (...args) => spawnSync('/bin/bash', [validator, ...args], { encoding: 'utf8' });

test('accepts stable and prerelease labels with numeric build numbers', () => {
  for (const label of ['1.0.0', '2.12.3', '1.0.0-beta', '1.0.0-beta.6', '2.0.0-rc.1']) {
    for (const build of ['7', '100', '1.2.3']) {
      const result = validate(label, build);
      assert.equal(result.status, 0, `${label} (${build}): ${result.stderr}`);
    }
  }
});

test('rejects malformed labels and build numbers', () => {
  for (const label of ['', 'v1.0.0', '1.0', '1.0.0-', '1.0.0-beta..1', '1.0.0-beta.', '../1.0.0', '1.0.0 beta']) {
    assert.equal(validate(label, '7').status, 2, label);
  }
  for (const build of ['-1', 'build7', '1..2', '1.']) {
    assert.equal(validate('1.0.0', build).status, 2, build);
  }
});

test('release entrypoint rejects bad input before signing or building', () => {
  const result = spawnSync('/bin/bash', [releaseScript, 'invalid', '7'], { encoding: 'utf8' });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /Usage: scripts\/release.sh/);
  assert.equal(result.stdout, '');
});
