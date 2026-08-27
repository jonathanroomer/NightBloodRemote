import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const output = resolve(import.meta.dirname, "..", "dist-ios-direct");
const source = resolve(output, "ios-direct.html");
const target = resolve(output, "ios-direct-bundled.html");

let html = await readFile(source, "utf8");
const stylesheet = html.match(/<link rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/);
if (!stylesheet) throw new Error("Direct iOS build contains no stylesheet link");
const css = await readFile(resolve(output, stylesheet[1]), "utf8");
html = html.replace(stylesheet[0], () => `<style>${css}</style>`);

const moduleScript = html.match(/<script type="module"[^>]*src="([^"]+)"[^>]*><\/script>/);
if (!moduleScript) throw new Error("Direct iOS build contains no module script");
const escapedScriptClose = "<" + String.fromCharCode(92) + "/script";
const javascript = (await readFile(resolve(output, moduleScript[1]), "utf8"))
  .replaceAll("</script", escapedScriptClose);
html = html.replace(moduleScript[0], () => `<script type="module">${javascript}</script>`);

await writeFile(target, html, "utf8");
