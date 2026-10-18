import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { type Game } from './data';
import { amount, integer } from './game';
import { POT_ADDRESS, readClient } from './config';
import { potAbi } from './abi';
import { Icon } from './Icons';
import { useWallet } from './Wallet';
import type { useTransactions } from './transactions';

export function RoundTools({ game, now, disabled, tx }: { game?: Game; now: number; disabled: boolean; tx: ReturnType<typeof useTransactions> }) {
  const wallet = useWallet();
  const [input, setInput] = useState('');
  const [roundId, setRoundId] = useState<bigint>();
  const [error, setError] = useState('');
  const drawing = game?.round.status === 2;
  const canRetry = drawing && now >= Number(game.round.randomnessRequestedAt) + 3600 && game.round.requestCount < 4 && !game.paused;
  const canCancel = game && [1, 2].includes(game.round.status) && now >= Number(game.round.endTime) + 86400 && (!drawing || now >= Number(game.round.randomnessRequestedAt) + 86400);
  const refund = useQuery({ queryKey: ['refund', roundId?.toString(), wallet.address, game?.block.toString()], enabled: !!roundId && !!wallet.address && !!game, queryFn: async () => {
    const [round, tickets] = await Promise.all([
      readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'getRound', args: [roundId!] }),
      readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'ticketsOf', args: [roundId!, wallet.address!] }),
    ]);
    return { status: round.status, tickets };
  }, retry: 1 });
  return <section className="tools-section"><details>
    <summary>Round tools & refunds<Icon name="chevron" size={18}/></summary>
    <div className="tools-content">
      <p className="muted">If the draw is delayed, anyone may retry randomness after 1 hour (up to 4 requests), or request cancellation after 24 hours from both the scheduled end and the latest randomness request. An active round tries randomness first, so cancellation may start a draw instead.</p>
      <div className="tool-buttons">
        <button className="button secondary" disabled={!canRetry || disabled} onClick={() => void tx.action('retryRandomness', 'Retry randomness', 'An additional randomness request is confirmed. The first valid response settles the round.')}>Retry randomness</button>
        <button className="button secondary" disabled={!canCancel || disabled} onClick={() => void tx.action('cancelRound', 'Request cancellation', 'The action is confirmed. Check the round: it may be cancelled or drawing if randomness was available.')}>Request cancellation</button>
        <button className="button secondary" disabled={!game || game.pendingBurn + game.pendingTreasury === 0n || disabled} onClick={() => void tx.action('flushPendingFees', 'Send pending fees', 'The fee flush is confirmed. Refresh the pending totals to see whether each transfer was sent.')}>Send pending fees</button>
      </div>
      <p className="small muted">Pending burn: {amount(game?.pendingBurn, game?.decimals)} IMD · Pending house fee: {amount(game?.pendingTreasury, game?.decimals)} IMD · Locked forever: {amount(game?.locked, game?.decimals)} IMD</p>
      <form className="refund-form" onSubmit={event => { event.preventDefault(); if (!wallet.address) { wallet.openWallet(); return; } if (!/^\d+$/.test(input) || BigInt(input) < 1n || !game || BigInt(input) >= game.roundId) { setError('Enter a past round number, starting at 1.'); return; } setError(''); setRoundId(BigInt(input)); }}>
        <label htmlFor="refund-round">Check a cancelled round for a refund</label>
        <div><input id="refund-round" name="refundRound" inputMode="numeric" type="text" placeholder="Round number" value={input} onChange={event => { setInput(event.target.value); setError(''); setRoundId(undefined); }} aria-describedby="refund-error" aria-invalid={!!error}/><button className="button secondary" type="submit" disabled={refund.isFetching || !game}>Check refund</button></div>
        <p id="refund-error" className="inline-error" role="alert">{error}</p>
      </form>
      {roundId && <div className="refund-result" role="status">{refund.isPending ? 'Checking your tickets…' : refund.isError ? <><span>Refund check failed.</span><button className="button secondary" onClick={() => void refund.refetch()}>Retry refund check</button></> : refund.data?.status === 4 && refund.data.tickets > 0n ? <><span>Round #{integer(roundId)}: {amount(refund.data.tickets * (game?.ticketPrice ?? 0n), game?.decimals)} IMD refundable.</span><button className="button secondary" disabled={disabled} onClick={() => void tx.action('refund', 'Claim refund', 'Your refund is confirmed. Your IMD has been returned.', [roundId])}>Claim refund</button></> : `No refund available for your wallet in round #${integer(roundId)}.`}</div>}
    </div>
  </details></section>;
}
