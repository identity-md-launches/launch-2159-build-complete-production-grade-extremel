import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { readRound, type Game } from './data';
import { amount, drawState, integer } from './game';
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
  const future = game?.mode === 'future-blockhash';
  const expired = game && drawState(game.round, game.block, game.mode).expired;
  const canCancel = game && (future ? expired || game.round.status === 1 && game.paused && now >= Number(game.round.endTime) + 86400 : [1, 2].includes(game.round.status) && now >= Number(game.round.endTime) + 86400 && (drawing ? now >= Number(game.round.randomnessRequestedAt ?? 0n) + 86400 : game.paused));
  const refund = useQuery({ queryKey: ['refund', roundId?.toString(), wallet.address, game?.block.toString()], enabled: !!roundId && !!wallet.address && !!game, queryFn: async () => {
    const [round, tickets] = await Promise.all([
      readRound(roundId!, game!.mode),
      readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'ticketsOf', args: [roundId!, wallet.address!] }),
    ]);
    return { status: round.status, tickets };
  }, retry: 1 });
  return <section className="tools-section"><details>
    <summary>Round tools & refunds<Icon name="chevron" size={18}/></summary>
    <div className="tools-content">
      <p className="muted">{future ? 'A draw must settle after its target block, within 256 blocks. If that window expires, anyone can cancel the round for full refunds. A round paused before commitment can be cancelled 24 hours after its scheduled end. The target block cannot be changed or re-rolled.' : 'This is the previous deployment. A drawing round can be cancelled 24 hours after both its scheduled end and its latest randomness request. A paused active round can be cancelled 24 hours after its end. Claims and refunds do not need a new draw.'}</p>
      <div className="tool-buttons">
        <button className="button secondary" disabled={!canCancel || disabled} onClick={() => void tx.action('cancelRound', 'Cancel round for refunds', 'The round is cancelled. Participants can check this round number below to claim their IMD back.')}>Cancel round for refunds</button>
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
