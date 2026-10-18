// Bounded production-export check against a disposable, local EVM. Never broadcasts to Ethereum.
// Optional tools: --playwright /path/to/playwright/index.mjs --axe /path/to/@axe-core/playwright/dist/index.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createPublicClient, createWalletClient, http, toHex, erc20Abi, parseEther } from 'viem';
import { mainnet } from 'viem/chains';

const option = name => process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : undefined;
const root = resolve(option('--root') ?? fileURLToPath(new URL('../../', import.meta.url)));
const output = resolve(root, option('--out') ?? 'test/scratch/browser-check');
const { chromium } = await import(option('--playwright') ? pathToFileURL(option('--playwright')).href : 'playwright');
const POT = '0x37cb0333a2fea358ae057bd85c4437803e5bcbfa';
const IMD = '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7';
const load = async name => JSON.parse(await readFile(resolve(root, name), 'utf8'));
const source = await load('out/IMDPot.sol/IMDPot.json');
const legacy = await load('out/LegacyIMDPot.sol/IMDPot.json');
const mock = await load('out/MockIMDToken.sol/MockIMDToken.json');
const passed = [];
const check = name => { passed.push(name); console.log(`PASS: ${name}`); };
const pause = ms => new Promise(done => setTimeout(done, ms));
async function until(fn, accept = Boolean, ms = 15_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { const value = await fn(); if (accept(value)) return value; } catch { /* wait for the UI or local node */ }
    await pause(100);
  }
  throw new Error('Timed out waiting for the expected local test state');
}
const freePort = async () => {
  const server = createServer(); await new Promise(done => server.listen(0, '127.0.0.1', done));
  const port = server.address().port; await new Promise(done => server.close(done)); return port;
};
const port = await freePort();
const anvil = spawn('anvil', ['--silent', '--port', String(port), '--chain-id', '1', '--number', '26219034', '--hardfork', 'cancun'], { stdio: 'ignore' });
const rpcUrl = `http://127.0.0.1:${port}`;
const rpc = async (method, params = []) => {
  const response = await fetch(rpcUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const body = await response.json(); if (body.error) throw new Error(body.error.message); return body.result;
};
let browser;
let server;
let page;
try {
  await until(() => rpc('eth_chainId'));
  const accounts = await rpc('eth_accounts');
  const [owner, player, successor] = accounts;
  const client = createPublicClient({ chain: mainnet, transport: http(rpcUrl) });
  const wallet = createWalletClient({ account: owner, chain: mainnet, transport: http(rpcUrl) });
  const write = async (address, abi, functionName, args = [], account = owner) => {
    const hash = await wallet.writeContract({ account, address, abi, functionName, args });
    const receipt = await client.waitForTransactionReceipt({ hash }); assert.equal(receipt.status, 'success');
  };
  const clone = async (artifact, target, args) => {
    const hash = await wallet.deployContract({ abi: artifact.abi, bytecode: artifact.bytecode.object, args });
    const receipt = await client.waitForTransactionReceipt({ hash });
    const code = await client.getCode({ address: receipt.contractAddress });
    await rpc('anvil_setCode', [target, code]);
    for (let slot = 0; slot < 24; slot++) {
      const key = toHex(slot, { size: 32 });
      const value = await client.getStorageAt({ address: receipt.contractAddress, slot: key });
      await rpc('anvil_setStorageAt', [target, key, value ?? toHex(0, { size: 32 })]);
    }
    return code;
  };
  const initial = await rpc('evm_snapshot');
  const sourceCode = await clone(source, POT, [owner]);
  await clone(mock, IMD, [18]);
  await write(IMD, mock.abi, 'mint', [player, parseEther('1000')]);
  await mkdir(output, { recursive: true });
  server = createServer(async (req, res) => {
    if (req.url === '/__rpc' && req.method === 'POST') {
      let body = ''; for await (const chunk of req) body += chunk;
      const response = await fetch(rpcUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(await response.text()); return;
    }
    const path = resolve(root, 'dist', decodeURIComponent((req.url ?? '').split('?')[0].replace(/^\/preview\/?/, '') || 'index.html'));
    if (!path.startsWith(resolve(root, 'dist') + '/')) { res.writeHead(404); res.end(); return; }
    try {
      const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' };
      res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream' }); res.end(await readFile(path));
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  const site = `http://127.0.0.1:${server.address().port}/preview/`;
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const errors = [];
  let failReads = false;
  await context.route(/https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)/, async route => {
    if (failReads) { await route.abort('failed'); return; }
    const response = await fetch(rpcUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: route.request().postData() });
    await route.fulfill({ status: 200, contentType: 'application/json', body: await response.text() });
  });
  await context.addInitScript(({ owner }) => {
    const handlers = new Map();
    const state = { account: sessionStorage.getItem('test:account') ?? owner, authorized: sessionStorage.getItem('test:authorized') === 'yes', chain: '0x1', reject: false, sent: [], emit(name, data) { for (const cb of handlers.get(name) ?? []) cb(data); }, select(account) { this.account = account; sessionStorage.setItem('test:account', account); this.emit('accountsChanged', [account]); } };
    window.testWallet = state;
    const provider = {
      on(name, cb) { handlers.set(name, [...handlers.get(name) ?? [], cb]); },
      removeListener(name, cb) { handlers.set(name, (handlers.get(name) ?? []).filter(item => item !== cb)); },
      async request({ method, params = [] }) {
        if (method === 'eth_requestAccounts') { state.authorized = true; sessionStorage.setItem('test:authorized', 'yes'); return [state.account]; }
        if (method === 'eth_accounts') return state.authorized ? [state.account] : [];
        if (method === 'eth_chainId') return state.chain;
        if (method === 'wallet_switchEthereumChain') { state.chain = params[0].chainId; state.emit('chainChanged', state.chain); return null; }
        if (method === 'wallet_addEthereumChain') return null;
        if (method === 'wallet_getCapabilities') return {};
        if (method === 'eth_sendTransaction') {
          if (state.reject) throw Object.assign(new Error('User rejected request'), { code: 4001 });
          state.sent.push(params[0]);
        }
        const response = await fetch('/__rpc', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
        const body = await response.json(); if (body.error) throw Object.assign(new Error(body.error.message), body.error); return body.result;
      },
    };
    window.ethereum = provider;
    const announce = () => dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: { provider, info: { uuid: '7194ec52-77f7-4e8e-a57a-987866f36eb3', name: 'Local test wallet', rdns: 'test.imdpot', icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg"/>' } } }));
    addEventListener('eip6963:requestProvider', announce); announce();
  }, { owner });
  page = await context.newPage();
  page.on('pageerror', error => errors.push(error.message));
  page.on('response', response => { if (response.url().startsWith(site) && response.status() >= 400) errors.push(`${response.status()}: ${response.url()}`); });
  const button = name => page.getByRole('button', { name: name === 'Continue with Privy' ? /^Continue with Privy/ : name, exact: name !== 'Continue with Privy' });
  const ready = () => page.locator('#round-heading').filter({ hasText: /Round #/ }).waitFor();
  const refresh = async () => { await page.reload(); await ready(); };
  const done = async (success = true) => {
    await page.getByRole('heading', { name: success ? 'Confirmed on Ethereum' : 'Action not completed' }).waitFor({ timeout: 30_000 });
    await button('Back to the table').click();
    await until(() => page.locator('.transaction-result').count(), count => count === 0);
  };
  const select = async account => { await page.evaluate(account => window.testWallet.select(account), account); };
  const read = (functionName, args = []) => client.readContract({ address: POT, abi: source.abi, functionName, args });
  await page.goto(site); await ready();
  assert.equal(await page.locator('#owner').count(), 0);
  const buyBox = await button('Buy tickets').boundingBox(); assert.ok(buyBox.y + buyBox.height < 844);
  assert.equal(await page.title(), 'IMDPot — The IMD jackpot room');
  for (const selector of ['meta[name="description"]', 'meta[property="og:title"]', 'meta[property="og:image"]', 'link[rel="icon"]']) assert.equal(await page.locator(selector).count(), 1);
  await page.screenshot({ path: resolve(output, 'mobile.webp'), type: 'webp', quality: 85 });
  check('390px first screen includes product, wallet connection and primary ticket action; share metadata exists');
  await button('Connect wallet').click();
  await button('Continue with Privy').waitFor(); assert.equal(await button('Continue with Privy').isDisabled(), false);
  await page.keyboard.press('Escape');
  assert.equal(await page.evaluate(() => document.activeElement?.textContent), 'Connect wallet');
  await page.screenshot({ path: resolve(output, 'keyboard-focus.webp'), type: 'webp', quality: 85 });
  await page.keyboard.press('Enter');
  await button('Local test wallet').click();
  await page.locator('#owner').waitFor();
  check('wallet picker supports keyboard open/close, focus return, Privy availability and EIP-6963 connection');
  await button('Configure IMD token').click();
  assert.ok((await page.locator('dialog').innerText()).includes('permanently'));
  await button('Set IMD token permanently').click(); await done();
  assert.equal((await read('token')).toLowerCase(), IMD.toLowerCase()); assert.equal(await read('isConfigured'), true);
  check('owner alone sees the panel and configures the pinned IMD token through a reviewed transaction');
  await button('Pause contract').click(); await page.locator('dialog').getByRole('button', { name: 'Pause contract', exact: true }).click(); await done();
  assert.equal(await read('paused'), true);
  await button('Unpause contract').click(); await page.locator('dialog').getByRole('button', { name: 'Unpause contract', exact: true }).click(); await done();
  assert.equal(await read('paused'), false);
  await page.locator('#owner').screenshot({ path: resolve(output, 'owner-mobile.webp'), type: 'webp', quality: 85 });
  check('pause and unpause require review, confirm on the local EVM and refresh settings');
  await select(player); await until(() => page.locator('#owner').count(), count => count === 0);
  await button('Buy tickets').waitFor();
  await page.locator('#ticket-quantity').fill('1.5'); await button('Buy tickets').click();
  await page.getByText('Enter a whole number of tickets.', { exact: true }).waitFor();
  assert.equal(await page.locator('#ticket-quantity').getAttribute('aria-invalid'), 'true');
  assert.equal(await page.evaluate(() => document.activeElement?.id), 'ticket-quantity');
  check('switching to a non-owner removes the panel; invalid ticket input is announced and focused');
  await page.getByRole('button', { name: '10 tickets', exact: true }).click();
  await page.evaluate(() => { window.testWallet.reject = true; });
  await button('Buy tickets').click(); await button('Approve & buy tickets').click(); await done(false);
  assert.equal(await read('ticketsOf', [1n, player]), 0n);
  await page.evaluate(() => { window.testWallet.reject = false; });
  check('wallet refusal recovers without claiming tickets were purchased');
  await button('Buy tickets').click(); await button('Approve & buy tickets').click(); await done();
  assert.equal(await read('ticketsOf', [1n, player]), 10n);
  const sent = await page.evaluate(() => window.testWallet.sent);
  const lastTwo = sent.slice(-2); assert.equal(lastTwo[0].to.toLowerCase(), IMD); assert.equal(lastTwo[1].to.toLowerCase(), POT);
  assert.equal(await client.readContract({ address: IMD, abi: erc20Abi, functionName: 'allowance', args: [player, POT] }), 0n);
  check('real approve-then-buy flow uses an exact allowance and produces ten onchain tickets');
  const round = await read('getRound', [1n]);
  await write(IMD, erc20Abi, 'approve', [POT, parseEther('0.1')], player);
  await refresh(); await page.getByRole('button', { name: '1 ticket', exact: true }).click();
  await button('Buy tickets').click(); await page.locator('dialog').getByRole('button', { name: 'Buy tickets', exact: true }).click(); await done();
  assert.equal(await read('ticketsOf', [1n, player]), 11n);
  assert.equal((await read('getRound', [1n])).endTime, round.endTime);
  check('existing allowance skips approval; later tickets preserve the original deadline');
  await rpc('evm_setNextBlockTimestamp', [Number(round.endTime)]); await rpc('evm_mine'); await refresh();
  await button('Finalize round').click(); await done();
  let drawing = await read('getRound', [1n]); assert.equal(drawing.status, 2); assert.equal(await read('totalClaimable'), 0n);
  assert.equal(await button('Waiting for target block').isDisabled(), true);
  await rpc('anvil_mine', ['0x3']); await refresh();
  assert.equal(await button('Waiting for target block').isDisabled(), true);
  await rpc('evm_mine'); await refresh();
  assert.equal(await button('Settle winners').isDisabled(), false);
  check('finalize commits an immutable future block and waits until strictly after that block');
  await select(owner); await page.locator('#owner').waitFor();
  await button('Pause contract').click(); await page.locator('dialog').getByRole('button', { name: 'Pause contract', exact: true }).click(); await done();
  assert.equal(await button('Settle winners').isDisabled(), false);
  await button('Settle winners').click(); await done();
  assert.equal(await read('currentRoundId'), 2n); assert.equal(await read('totalClaimable'), parseEther('0.77'));
  assert.equal(await read('totalLocked'), parseEther('0.165'));
  check('a committed draw settles while paused and accounts for prizes, permanent lock and fees');
  await select(player); await until(() => button('Claim prizes').isDisabled(), value => value === false);
  await button('Claim prizes').click(); await done(); assert.equal(await read('claimable', [player]), 0n);
  await page.getByRole('button', { name: 'Burns', exact: true }).click(); await page.getByText('IMD burn sent', { exact: true }).waitFor();
  assert.equal(await page.getByText('House fee sent', { exact: true }).count(), 0);
  await button('House fees').click(); await page.getByText('House fee sent', { exact: true }).waitFor();
  check('winners claim while paused; activity filters display actual emitted burn and treasury transfers');
  await select(owner); await page.locator('#owner').waitFor();
  await button('Unpause contract').click(); await page.locator('dialog').getByRole('button', { name: 'Unpause contract', exact: true }).click(); await done();
  await select(player); await until(() => button('Buy tickets').isDisabled(), value => value === false);
  await button('Buy tickets').click(); await button('Approve & buy tickets').click(); await done();
  const round2 = await read('getRound', [2n]);
  await rpc('evm_setNextBlockTimestamp', [Number(round2.endTime)]); await rpc('evm_mine'); await refresh();
  await button('Finalize round').click(); await done();
  drawing = await read('getRound', [2n]);
  await rpc('anvil_mine', [toHex(drawing.drawBlock + 257n - await client.getBlockNumber({ cacheTime: 0 }))]); await refresh();
  await page.getByText('Round tools & refunds', { exact: true }).click();
  await button('Cancel round for refunds').click(); await done();
  await page.locator('#refund-round').fill('2'); await button('Check refund').click();
  await button('Claim refund').click(); await done();
  assert.equal(await read('ticketsOf', [2n, player]), 0n); assert.equal(await read('totalRefundable'), 0n);
  check('expired draw offers cancellation and an actual full refund with no re-roll');
  await page.evaluate(() => { window.testWallet.chain = '0xa'; window.testWallet.emit('chainChanged', '0xa'); });
  await button('Switch to Ethereum').first().click(); await until(() => page.evaluate(() => window.testWallet.chain), value => value === '0x1');
  check('wrong-chain connection switches to the verified Ethereum parameters');
  for (const width of [320, 390, 620, 760, 980, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `overflow at ${width}`);
  }
  await page.goto(site); await ready();
  await page.screenshot({ path: resolve(output, 'desktop.webp'), type: 'webp', quality: 85 });
  check('production export and responsive reflow work at 320, 390, 620, 760, 980 and 1440px under /preview/');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  check('200% text enlargement wraps mobile navigation without horizontal overflow');
  await page.setViewportSize({ width: 1440, height: 900 });
  if (option('--axe')) {
    const { default: AxeBuilder } = await import(pathToFileURL(option('--axe')).href);
    const result = await new AxeBuilder({ page }).analyze();
    await writeFile(resolve(output, 'axe.json'), JSON.stringify(result.violations, null, 2));
    assert.equal(result.violations.length, 0); check('axe reports zero violations in the checked desktop state');
  }
  await rpc('anvil_setCode', [POT, '0x60006000fd']); await page.reload();
  await page.getByText('Live reads are unavailable', { exact: true }).waitFor();
  assert.equal(await button('Buy tickets').isDisabled(), true);
  await rpc('anvil_setCode', [POT, sourceCode]); await button('Retry connection').click(); await ready();
  check('unrecognized runtime disables signed actions and Retry connection restores verified reads');
  failReads = true; await page.reload(); await page.getByText('Live reads are unavailable', { exact: true }).waitFor({ timeout: 45_000 });
  failReads = false; await button('Retry connection').click(); await ready();
  check('RPC failure exposes a recoverable error and disables stale transactions');
  await rpc('evm_revert', [initial]);
  await clone(legacy, POT, [owner]); await refresh();
  await page.getByText('New game deployment required', { exact: true }).waitFor();
  assert.equal(await button('Contract update required').isDisabled(), true);
  assert.equal(await page.locator('#owner').count(), 0);
  await select(owner); await page.locator('#owner').waitFor();
  assert.equal(await button('Configure IMD token').count(), 0);
  check('legacy runtime is recognized honestly; new entries and source-only setup are unavailable');
  const mobileContext = await browser.newContext({ viewport: { width: 390, height: 844 }, userAgent: 'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36' });
  await mobileContext.route(/https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)/, async route => {
    const response = await fetch(rpcUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: route.request().postData() });
    await route.fulfill({ status: 200, contentType: 'application/json', body: await response.text() });
  });
  const mobilePage = await mobileContext.newPage();
  await mobilePage.goto(site);
  await mobilePage.getByRole('button', { name: 'Connect wallet', exact: true }).click();
  for (const name of ['MetaMask', 'Coinbase Wallet', 'Rabby', 'Phantom']) {
    assert.ok(await mobilePage.getByRole('link', { name: `Open in ${name}`, exact: true }).getAttribute('href'));
  }
  assert.equal(await mobilePage.getByRole('button', { name: 'Coinbase Smart Wallet', exact: true }).count(), 1);
  await mobilePage.screenshot({ path: resolve(output, 'mobile-wallet.webp'), type: 'webp', quality: 85 });
  check('phone picker provides four wallet-app links and Coinbase Smart Wallet without a relay');
  if (process.argv.includes('--live-privy')) {
    let appStatus;
    mobilePage.on('response', response => { if (response.url().includes('/api/v1/apps/cmve43hs901uf0gl1dqj33sqc')) appStatus = response.status(); });
    await mobilePage.getByRole('button', { name: /^Continue with Privy/ }).click();
    await mobilePage.locator('input[type="email"]').waitFor({ timeout: 45_000 });
    assert.equal(appStatus, 200);
    await mobilePage.screenshot({ path: resolve(output, 'privy-login.webp'), type: 'webp', quality: 85 });
    await writeFile(resolve(output, 'privy-body.txt'), await mobilePage.locator('body').innerText());
    check('real Privy SDK accepts the exact app ID and opens its email sign-in form (no OTP sent)');
    await mobilePage.reload();
    await mobilePage.locator('input[type="email"]').waitFor({ timeout: 45_000 });
    check('Privy sign-in attempt resumes after reload for redirect and session recovery');
  }
  await mobileContext.close();
  assert.deepEqual(errors, []); check('no uncaught page errors or missing local production resources');
  await writeFile(resolve(output, 'results.json'), JSON.stringify({ passed, errors, mode: 'local EVM; no mainnet transactions' }, null, 2));
  console.log(`Completed ${passed.length} browser checks.`);
} catch (error) {
  await mkdir(output, { recursive: true });
  await writeFile(resolve(output, 'failure.txt'), String(error.stack ?? error));
  if (page && !page.isClosed()) { await page.screenshot({ path: resolve(output, 'failure.webp'), type: 'webp' }).catch(() => {}); await writeFile(resolve(output, 'failure-body.txt'), await page.locator('body').innerText().catch(() => 'Page unavailable')); }
  console.error(error); process.exitCode = 1;
} finally {
  await browser?.close();
  if (server) { server.closeAllConnections(); await new Promise(done => server.close(done)); }
  anvil.kill('SIGTERM');
}
