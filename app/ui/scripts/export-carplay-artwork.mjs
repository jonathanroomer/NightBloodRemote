/** Run with the UI's Vite server on 127.0.0.1:5197.
 * Uses the repo's existing Playwright tooling, or PLAYWRIGHT_MODULE pointing
 * at an installed @playwright/test package. No generated image edits by hand.
 */
import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE ?? '@playwright/test');
const output = new URL('../../../ios/NightBloodRemote/CarPlayArtwork/', import.meta.url);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const states = process.argv.slice(2);
  for (const state of states.length ? states : ['ready', 'welcoming', 'unavailable', 'listening', 'working', 'speaking']) {
    await page.goto(`http://127.0.0.1:5197/carplay-nightblood-atlas.html?state=${state}`);
    await page.waitForFunction(() => document.documentElement.dataset.exportReady === 'true');
    if (errors.length) throw new Error(errors.join('\n'));
    const png = await page.locator('#atlas').evaluate(canvas => canvas.toDataURL('image/png').split(',')[1]);
    await writeFile(new URL(`CarPlayFace-${state}.png`, output), Buffer.from(png, 'base64'));
    console.log(`Exported ${state}: 30 transparent 450px frames`);
  }
} finally {
  await browser.close();
}
