#!/usr/bin/env node

import { readFile, rename, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const SAFE_ANCILLARY = new Set(["cHRM", "gAMA", "sRGB", "tRNS"]);

const target = process.argv[2];
if (!target) {
  throw new Error("usage: node scripts/strip-png-metadata.mjs <image.png>");
}

const path = resolve(target);
const input = await readFile(path);
if (input.length < PNG_SIGNATURE.length
    || !input.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) {
  throw new Error(`${path} is not a PNG file`);
}

const chunks = [PNG_SIGNATURE];
const removed = [];
let offset = PNG_SIGNATURE.length;
let sawEnd = false;

while (offset < input.length) {
  if (offset + 12 > input.length) throw new Error("truncated PNG chunk");
  const length = input.readUInt32BE(offset);
  const end = offset + 12 + length;
  if (end > input.length) throw new Error("invalid PNG chunk length");

  const type = input.toString("ascii", offset + 4, offset + 8);
  const isCritical = (type.charCodeAt(0) & 0x20) === 0;
  if (isCritical || SAFE_ANCILLARY.has(type)) {
    chunks.push(input.subarray(offset, end));
  } else {
    removed.push(type);
  }
  offset = end;
  if (type === "IEND") {
    sawEnd = true;
    break;
  }
}

if (!sawEnd || offset !== input.length) {
  throw new Error("invalid data after PNG end chunk");
}

const temporary = `${path}.metadata-tmp`;
await writeFile(temporary, Buffer.concat(chunks), { mode: 0o644 });
await rename(temporary, path);
console.log(`Removed PNG metadata chunks: ${removed.join(", ") || "none"}`);
