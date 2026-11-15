/** Types + helpers for the reflection-driven answer-file schema (ARCHITECTURE.md "Answer file"). */

export interface Param {
  name: string;
  type: string;
  nullable?: boolean;
  collection?: null | 'list' | 'set' | 'dict';
  keyType?: string;
  default?: unknown;
  label?: string;
  help?: string;
}

export type SchemaType =
  | { kind: 'record'; params: Param[] }
  | { kind: 'interface'; implementations: string[] }
  | { kind: 'enum'; values: string[]; flags?: boolean }
  | { kind: 'keyed'; options: { id: string; label?: string }[] };

export interface Schema {
  root: string;
  types: Record<string, SchemaType>;
  groups?: { id: string; label: string; params: string[] }[];
}

export type Obj = Record<string, unknown>;

/** "TimeZoneSettings" -> "Time zone settings" when the schema has no label. */
export function humanize(name: string): string {
  const s = name.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z])([A-Z][a-z])/g, '$1 $2');
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}

/** Readable label for an interface implementation ("UnattendedLanguageSettings" -> "Unattended"). */
export function implLabel(iface: string, impl: string): string {
  const base = iface.replace(/^I(?=[A-Z])/, '');
  const stripped = impl.endsWith(base) ? impl.slice(0, -base.length) : impl;
  return humanize(stripped || impl);
}

/** A starting value for a fresh field of this type. */
export function initialValue(schema: Schema, type: string, collection?: Param['collection']): unknown {
  if (collection === 'list' || collection === 'set' || collection === 'dict') return [];
  switch (type) {
    case 'bool': return false;
    case 'int': return 0;
    case 'string': return '';
    case 'bytes': return null;
  }
  const t = schema.types[type];
  if (!t) return null;
  if (t.kind === 'enum') return t.flags ? '' : (t.values[0] ?? '');
  if (t.kind === 'keyed') return t.options[0]?.id ?? '';
  if (t.kind === 'interface') return newImpl(schema, t.implementations[0]);
  if (t.kind === 'record') return newRecord(schema, type);
  return null;
}

export function newRecord(schema: Schema, type: string, seen = new Set<string>()): Obj {
  const t = schema.types[type];
  const o: Obj = {};
  if (t?.kind === 'record' && !seen.has(type)) {
    seen.add(type);
    for (const p of t.params) {
      if (p.default !== undefined) o[p.name] = structuredClone(p.default);
      else if (!p.nullable) o[p.name] = initialValue(schema, p.type, p.collection);
    }
  }
  return o;
}

export function newImpl(schema: Schema, impl: string | undefined): Obj | null {
  if (!impl) return null;
  return { $type: impl, ...newRecord(schema, impl) };
}

export function isLongText(p: Param, v: unknown): boolean {
  return (typeof v === 'string' && v.includes('\n')) || /script|xml|content|command|json|code|text$/i.test(p.name);
}
