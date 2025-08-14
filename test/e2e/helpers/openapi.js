import fs from 'fs';
import path from 'path';
import YAML from 'yaml';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SPEC_PATH = process.env.OAS_PATH || path.resolve(__dirname, '..', '..', 'openapi', 'ticketing.yaml');

const spec = YAML.parse(fs.readFileSync(SPEC_PATH, 'utf8'));
const ajv = new Ajv({ strict: false, allErrors: true });
addFormats(ajv);

function getJsonSchema(method, route, status) {
  const pathItem = spec.paths?.[route];
  const op = pathItem?.[method];
  const res = op?.responses?.[String(status)];
  const schema = res?.content?.['application/json']?.schema;
  if (!schema) throw new Error(`Schema not found for ${method.toUpperCase()} ${route} ${status}`);
  return ajv.compile(schema);
}

export function assertJson(method, route, status, body) {
  const validate = getJsonSchema(method, route, status);
  const ok = validate(body);
  if (!ok) {
    const errors = JSON.stringify(validate.errors, null, 2);
    throw new Error(`[OpenAPI] ${method.toUpperCase()} ${route} ${status} schema mismatch:\n${errors}`);
  }
}
