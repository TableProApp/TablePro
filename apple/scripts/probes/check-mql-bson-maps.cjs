// Run with NODE_PATH naming a bson 6.10.4 installation.
const assert = require('node:assert/strict');
const { serialize, deserialize, EJSON, Code } = require('bson');

const keys = ['z', '10', '2', '__proto__', '01'];
const document = new Map(keys.map(key => [key, EJSON.parse('{"$numberLong":"42"}', { relaxed: false })]));
const bytes = serialize(document);
const stored = [];
let offset = 4;
while (bytes[offset]) {
  assert.equal(bytes[offset++], 18);
  const end = bytes.indexOf(0, offset);
  stored.push(bytes.toString('utf8', offset, end));
  offset = end + 1 + 8;
}
assert.deepEqual(stored, keys);
const command = serialize({ insert: 'sample', documents: [document], ordered: true });
const restored = deserialize(command, { promoteLongs: false });
assert.equal(Object.hasOwn(restored.documents[0], '__proto__'), true);
assert.equal(restored.documents[0].__proto__.toString(), '42');
const scope = new Map([['10', EJSON.parse('{"$numberLong":"5"}', { relaxed: false })], ['2', null]]);
const code = serialize({ code: new Code('return x', scope) });
assert.ok(code.indexOf(Buffer.from('10\0')) < code.indexOf(Buffer.from('2\0')));
console.log('PASS: BSON stores Map fields in order, including nested command documents and code scopes.');
