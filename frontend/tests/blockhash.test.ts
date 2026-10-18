import { test } from 'node:test';
import assert from 'node:assert/strict';
import { keccak256, stringToHex } from 'viem';
import { drawState, isOwnerWallet, type Round } from '../src/game';
import { blockhashAbi } from '../src/blockhash-abi';
import { BLOCKHASH_ABI_HASH } from '../src/blockhash-release';

const round: Round = { status: 2, startTime: 1n, endTime: 901n, drawBlock: 103n, drawBlockHash: `0x${'0'.repeat(64)}`, pool: 0n, totalTickets: 1n, participantCount: 1n, randomWord: 0n, winners: [], prizes: [], burned: 0n, treasuryFee: 0n, locked: 0n };
const canonical = (value: unknown): unknown => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical((value as Record<string, unknown>)[key])])) : value;

test('source ABI hash matches the release and has no oracle or retry functions', () => {
  assert.equal(keccak256(stringToHex(JSON.stringify(canonical(blockhashAbi)))), BLOCKHASH_ABI_HASH);
  const names = blockhashAbi.filter(item => item.type === 'function').map(item => item.name);
  for (const removed of ['setVrfConfig', 'setVrfRequestParams', 'retryRandomness', 'rawFulfillRandomWords']) assert.equal(names.includes(removed as typeof names[number]), false);
  assert.ok(names.includes('finalizeRound'));
});
test('the target block itself cannot be used; the next 256 blocks can settle', () => {
  assert.equal(drawState(round, 100n, 'future-blockhash').ready, false);
  assert.equal(drawState(round, 103n, 'future-blockhash').ready, false);
  assert.equal(drawState(round, 104n, 'future-blockhash').ready, true);
  assert.equal(drawState(round, 359n, 'future-blockhash').ready, true);
  assert.equal(drawState(round, 360n, 'future-blockhash').expired, true);
  assert.equal(drawState(round, 360n, 'future-blockhash').ready, false);
});
test('legacy deployments never offer a source-only blockhash action', () => {
  assert.equal(drawState(round, 104n, 'legacy-vrf').ready, false);
  assert.match(drawState(round, 104n, 'legacy-vrf').label, /update required/);
});
test('owner visibility requires both addresses and compares case insensitively', () => {
  assert.equal(isOwnerWallet(undefined, undefined), false);
  assert.equal(isOwnerWallet('0xAbC', undefined), false);
  assert.equal(isOwnerWallet(undefined, '0xAbC'), false);
  assert.equal(isOwnerWallet('0xAbC', '0xabc'), true);
  assert.equal(isOwnerWallet('0xAbC', '0xdef'), false);
});
