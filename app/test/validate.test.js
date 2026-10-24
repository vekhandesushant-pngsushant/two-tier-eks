const test = require('node:test');
const assert = require('node:assert');
const { validateTitle } = require('../src/validate');

test('accepts and trims a valid title', () => {
  assert.deepStrictEqual(validateTitle('  Buy milk  '), { ok: true, value: 'Buy milk' });
});
test('rejects empty title', () => {
  assert.strictEqual(validateTitle('   ').ok, false);
});
test('rejects non-string', () => {
  assert.strictEqual(validateTitle(42).ok, false);
});
test('rejects >255 chars', () => {
  assert.strictEqual(validateTitle('a'.repeat(256)).ok, false);
});
