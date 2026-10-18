import { formatUnits, type Address } from 'viem';

export type Round = {
  status: number;
  startTime: bigint;
  endTime: bigint;
  randomnessRequestedAt: bigint;
  requestCount: number;
  pool: bigint;
  totalTickets: bigint;
  participantCount: bigint;
  vrfRequestId: bigint;
  randomWord: bigint;
  winners: readonly Address[];
  prizes: readonly bigint[];
  burned: bigint;
  treasuryFee: bigint;
  locked: bigint;
};

export function countdown(round: Round | undefined, now: number) {
  if (!round) return { text: '--:--', seconds: 0, label: 'Reading the round' };
  if (round.status === 0) return { text: '15:00', seconds: 900, label: 'Starts with the first ticket' };
  if (round.status === 2) return { text: '00:00', seconds: 0, label: 'Waiting for the draw' };
  const seconds = Math.max(0, Number(round.endTime) - Math.floor(now));
  return {
    text: `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`,
    seconds,
    label: seconds > 0 ? 'Until tickets close' : 'Ready to finalize',
  };
}

export function ticketCount(value: string): { count: bigint; error?: never } | { error: string; count?: never } {
  if (!/^\d+$/.test(value.trim())) return { error: 'Enter a whole number of tickets.' };
  const count = BigInt(value.trim());
  if (count < 1n || count > 1_000_000n) return { error: 'Choose between 1 and 1,000,000 tickets.' };
  return { count };
}

export function entryReason(round: Round, configured: boolean, paused: boolean, now: number): string | undefined {
  if (!configured) return 'Entries open after the owner configures IMD and randomness.';
  if (paused) return 'Entries are paused. Claims and eligible refunds remain available.';
  if (round.status === 2) return 'The draw is in progress. Entries reopen in the next round.';
  if (round.status === 1 && now >= Number(round.endTime)) return 'Tickets are closed. Anyone can finalize this round.';
  if (round.status > 2) return 'This round has ended. Refresh to load the next round.';
}

export function amount(value: bigint | undefined, decimals = 18, maximumFractionDigits = 4): string {
  if (value === undefined) return '—';
  const [whole, fraction = ''] = formatUnits(value, decimals).split('.');
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const trimmed = fraction.slice(0, maximumFractionDigits).replace(/0+$/, '');
  if (value > 0n && whole === '0' && !trimmed) return `< ${maximumFractionDigits === 0 ? '1' : `0.${'0'.repeat(maximumFractionDigits - 1)}1`}`;
  return `${grouped}${trimmed ? `.${trimmed}` : ''}`;
}

export const exactAmount = (value: bigint, decimals = 18) => formatUnits(value, decimals);
export const shortAddress = (address: string) => `${address.slice(0, 6)}…${address.slice(-4)}`;
export const integer = (value: bigint | undefined) => value === undefined ? '—' : value.toLocaleString('en-US');
export const multiplier = (boost: bigint | undefined) => boost === undefined ? '—' : `${Number(10_000n + boost) / 10_000}×`;

export function readableError(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error);
  if (/reject|denied|4001/i.test(text)) return 'Request declined in your wallet. You can try again.';
  if (/insufficient funds/i.test(text)) return 'Not enough ETH for network gas. Add ETH to your wallet and try again.';
  if (/insufficient.*balance|exceeds balance/i.test(text)) return 'Not enough IMD for this purchase. Choose fewer tickets.';
  if (/RoundClosed|RoundNotEnded/i.test(text)) return 'The round changed while you were here. Refresh and try again.';
  if (/TokenNotConfigured|VrfNotConfigured/i.test(text)) return 'The game owner still needs to configure IMD and randomness.';
  if (/EnforcedPause/i.test(text)) return 'The game is paused. Try again after the owner resumes entries.';
  if (/timeout|fetch|network|HTTP|RPC/i.test(text)) return 'Ethereum could not be reached. Check your connection and try again.';
  if (/revert/i.test(text)) return 'The contract did not accept this action. Refresh the round and check your balance before trying again.';
  return text.length > 190 ? 'The wallet could not complete this request. Refresh and try again.' : text;
}
