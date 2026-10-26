import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { ContractError } from './client.mts';
import { allShapes, commentShape, issueShape, labelShape } from './shapes.mts';

interface DefinitionNode {
  type?: string;
  $ref?: string;
  properties?: Record<string, DefinitionNode>;
}
const schema = JSON.parse(readFileSync(new URL('./schema.json', import.meta.url), 'utf8')) as { definitions: Record<string, DefinitionNode>; info: { version: string } };

describe('the validators against api/schema.json', () => {
  it('read the swagger of Forgejo 17.0.0', () => {
    assert.match(schema.info.version, /^17\.0\.0\+/);
  });

  for (const shape of allShapes) {
    it(`${shape.definition}: every field it reads is a property of the definition, of the same JSON type`, () => {
      const definition = schema.definitions[shape.definition];
      assert.ok(definition?.properties, `api/schema.json has no definition ${shape.definition}`);
      for (const [name, field] of Object.entries(shape.spec)) {
        const property: DefinitionNode | undefined = definition.properties[name];
        assert.ok(property, `${shape.definition} has no property ${name}`);
        const target: DefinitionNode = property.$ref === undefined ? property : (schema.definitions[property.$ref.replace('#/definitions/', '')] ?? property);
        const expected = target.type ?? 'object';
        assert.equal(field.type.wire, expected, `${shape.definition}.${name}`);
      }
    });
  }
});

const validIssue = {
  number: 3,
  title: 'A title, so that it is complete',
  body: '',
  state: 'open',
  labels: [{ id: 1, name: 'status/ready', color: 'aaaaaa' }],
  assignees: null,
  comments: 0,
  created_at: '2026-01-01T00:00:00Z',
  html_url: 'https://forge.example.test/o/r/issues/3',
};

describe('the validators', () => {
  it('accept a complete answer and ignore fields they do not read (innocent case)', () => {
    const issue = issueShape.type.read({ ...validIssue, unrelated: { deep: true } }, 'test');
    assert.equal(issue.number, 3);
    assert.equal(issue.assignees, null);
    assert.equal(issue.labels?.[0]?.name, 'status/ready');
  });

  for (const field of Object.keys(validIssue)) {
    it(`refuse an Issue that lacks ${field}`, () => {
      const broken: Record<string, unknown> = { ...validIssue };
      delete broken[field];
      assert.throws(() => issueShape.type.read(broken, 'test'), (error: unknown) => error instanceof ContractError && error.message.includes(field));
    });
  }

  it('refuse a field of the wrong type, and say where', () => {
    assert.throws(() => issueShape.type.read({ ...validIssue, labels: [{ id: 'one', name: 'x', color: 'a' }] }, 'read issue'), /read issue\.labels\[0\]\.id: an integer was expected, not a string/);
    assert.throws(() => commentShape.type.read({ id: 1, html_url: 'u', body: 'b', created_at: 'now', user: 5 }, 'comment'), ContractError);
  });

  it('read the archival of a label where Forgejo gives it, and take a label that says nothing for one that does not say', () => {
    assert.equal(labelShape.type.read({ id: 1, name: 'package/shop#5', color: 'aaaaaa', is_archived: true }, 'label').is_archived, true);
    assert.equal(labelShape.type.read({ id: 1, name: 'package/shop#5', color: 'aaaaaa', is_archived: false }, 'label').is_archived, false);
    assert.equal(labelShape.type.read({ id: 1, name: 'package/shop#5', color: 'aaaaaa' }, 'label').is_archived, undefined);
    assert.throws(() => labelShape.type.read({ id: 1, name: 'x', color: 'aaaaaa', is_archived: 'yes' }, 'label'), /label\.is_archived: true or false was expected, not a string/);
  });

  it('refuse something that is no object', () => {
    assert.throws(() => labelShape.type.read([], 'label'), ContractError);
    assert.throws(() => labelShape.type.read(null, 'label'), ContractError);
  });
});
