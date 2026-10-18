import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import { keccak256, stringToHex, createPublicClient, http } from 'viem';

const arg = name => process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : undefined;
const root = arg('--root') ?? fileURLToPath(new URL('../../', import.meta.url));
const expectedAbi = '0x704db1f4052e00f1a56022661009122fddefd3531acb6d932a7385bce63ba140';
const expectedRuntime = '0xa9c960870ecc1ed218a7e9dc888e089a18dbe9444b6e523241589786bbfcb355';
const address = '0x37cb0333a2fea358ae057bd85c4437803e5bcbfa';
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const hashAbi = abi => keccak256(stringToHex(JSON.stringify(canonical(abi))));
const inspect = name => JSON.parse(execFileSync('forge', ['inspect', name, 'abi', '--json'], { cwd: root, encoding: 'utf8' }));
const json = async path => JSON.parse(await readFile(resolve(root, path), 'utf8'));

// The immutable live deployment and the revised source deliberately have different ABIs and runtimes.
const legacy = inspect('test/legacy/LegacyIMDPot.sol:IMDPot');
assert.equal(hashAbi(legacy), expectedAbi);
assert.deepEqual(await json('frontend/IMDPot.abi.json'), legacy);
assert.ok((await readFile(resolve(root, 'frontend/src/abi.ts'), 'utf8')).includes(JSON.stringify(legacy) + ' as const;'));
assert.equal(keccak256((await json('out/LegacyIMDPot.sol/IMDPot.json')).deployedBytecode.object), expectedRuntime);
console.log('PASS: legacy ABI matches the deployment abiHash; its source snapshot reproduces the pinned runtime.');

const updated = inspect('src/IMDPot.sol:IMDPot');
assert.deepEqual(await json('frontend/IMDPot.blockhash.abi.json'), updated);
assert.ok((await readFile(resolve(root, 'frontend/src/blockhash-abi.ts'), 'utf8')).includes(JSON.stringify(updated) + ' as const;'));
const release = await readFile(resolve(root, 'frontend/src/blockhash-release.ts'), 'utf8');
const updatedRuntime = keccak256((await json('out/IMDPot.sol/IMDPot.json')).deployedBytecode.object);
assert.ok(release.includes(updatedRuntime));
assert.ok(release.includes(hashAbi(updated)));
assert.notEqual(updatedRuntime, expectedRuntime);
console.log(`PASS: future-blockhash ABI and runtime match compiled source (${updatedRuntime}).`);

if (!process.argv.includes('--offline')) {
  const client = createPublicClient({ transport: http(arg('--rpc') ?? 'https://ethereum-rpc.publicnode.com', { timeout: 15_000, retryCount: 1 }) });
  assert.equal(await client.getChainId(), 1);
  const code = await client.getCode({ address });
  assert.ok(code && code !== '0x');
  assert.equal(keccak256(code), expectedRuntime);
  const read = functionName => client.readContract({ address, abi: legacy, functionName });
  const [block, owner, configured, token, paused, roundId] = await Promise.all([client.getBlockNumber(), read('owner'), read('isConfigured'), read('token'), read('paused'), read('currentRoundId')]);
  console.log('PASS: live Ethereum code matches the LEGACY deployment. No source upgrade is implied.');
  console.log(JSON.stringify({ block: block.toString(), owner, configured, token, paused, roundId: roundId.toString(), mode: 'legacy-vrf' }, null, 2));
}
