import { test } from 'node:test';
import assert from 'node:assert/strict';
import { countdown, ticketCount, entryReason, amount, exactAmount, multiplier, readableError, type Round } from '../src/game';
import { potAbi } from '../src/abi';
import { keccak256, stringToHex } from 'viem';
import { ABI_HASH } from '../src/config';

const round: Round = { status: 0, startTime: 0n, endTime: 0n, randomnessRequestedAt: 0n, requestCount: 0, pool: 0n, totalTickets: 0n, participantCount: 0n, vrfRequestId: 0n, randomWord: 0n, winners: [], prizes: [], burned: 0n, treasuryFee: 0n, locked: 0n };
const canonical = (value: unknown): unknown => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical((value as Record<string, unknown>)[key])])) : value;

test('the complete generated ABI matches the pinned canonical keccak', () => {
  assert.equal(keccak256(stringToHex(JSON.stringify(canonical(potAbi)))), ABI_HASH);
});
test('an empty round never starts its timer, even days later', () => {
  assert.equal(countdown(round, 1_000_000).text, '15:00');
  assert.equal(countdown(round, 1_900_000).label, 'Starts with the first ticket');
});
test('an active timer closes at the contract deadline and never goes negative', () => {
  const active = { ...round, status: 1, startTime: 100n, endTime: 1000n };
  assert.equal(countdown(active, 100).text, '15:00');
  assert.equal(countdown(active, 939).text, '01:01');
  assert.equal(countdown(active, 999.9).text, '00:01');
  assert.equal(countdown(active, 1000).text, '00:00');
  assert.equal(countdown(active, 1100).seconds, 0);
  assert.match(entryReason(active, true, false, 1000)!, /Tickets are closed/);
});
test('the VRF state does not invent a new timer or permit late purchases', () => {
  const drawing = { ...round, status: 2, endTime: 1000n };
  assert.equal(countdown(drawing, 1100).label, 'Waiting for the draw');
  assert.match(entryReason(drawing, true, false, 1100)!, /draw is in progress/);
});
test('ticket inputs reject fractions, signs, exponents, empty values and out-of-range purchases', () => {
  for (const input of ['', '0', '-1', '0.1', '1.5', '1e6', '1000001', 'Infinity', 'ten', '1,000']) assert.ok(ticketCount(input).error, input);
  assert.equal(ticketCount('1').count, 1n);
  assert.equal(ticketCount('1000000').count, 1_000_000n);
  assert.equal(ticketCount(' 10 ').count, 10n);
});
test('setup and pause gates stay closed regardless of a plausible deadline', () => {
  assert.match(entryReason(round, false, false, 0)!, /owner configures/);
  assert.match(entryReason(round, true, true, 0)!, /paused/);
  assert.equal(entryReason(round, true, false, 0), undefined);
});
test('money uses bigint arithmetic and exposes exact values separately', () => {
  assert.equal(amount(10n ** 17n), '0.1');
  assert.equal(amount(123456789012345678901234567890n), '123,456,789,012.3456');
  assert.equal(exactAmount(1234567890123456789n), '1.234567890123456789');
  assert.equal(amount(1n), '< 0.0001');
  assert.equal(amount(undefined), '—');
  assert.equal(multiplier(2500n), '1.25×');
  assert.equal(multiplier(10000n), '2×');
});
test('wallet refusal and provider failure explain how to recover', () => {
  assert.match(readableError(new Error('User rejected request 4001')), /try again/);
  assert.match(readableError(new Error('HTTP request failed')), /connection/);
});
