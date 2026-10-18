import test from 'node:test';
import assert from 'node:assert/strict';
import { selectRelease } from './releases.mjs';
const release = (tag, date, extra = {}) => ({ tag_name: tag, published_at: date, assets: [{name: `gitacre-${tag}.dmg`, browser_download_url: `https://github.com/shivamx96/gitacre/releases/download/${tag}/gitacre-${tag}.dmg`}], ...extra });
test('includes betas and orders by publication', () => {
  assert.equal(selectRelease([release('v1', '2026-01-01'), release('v2-beta', '2026-02-01', { prerelease: true })]).version, 'v2-beta');
});
test('skips drafts, local artifacts, and missing DMGs', () => {
  assert.equal(selectRelease([release('draft', '2026-03-01', { draft: true }), release('test-local', '2026-02-01'), release('empty', '2026-02-01', { assets: [] }), release('good', '2026-01-01')]).version, 'good');
});
test('invalid responses and foreign download URLs preserve fallback', () => {
  for (const value of [null, {}, [], [null], [release('bad', '', { assets: [{name:'gitacre-bad.dmg', browser_download_url:'https://example.com/app.dmg'}] })]]) assert.equal(selectRelease(value), null);
});
