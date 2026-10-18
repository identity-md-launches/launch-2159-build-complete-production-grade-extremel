import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useGame, usePlayer } from './data';
import { amount, exactAmount, countdown, entryReason, integer, multiplier, readableError, shortAddress, ticketCount } from './game';
import { EXPLORER, POT_ADDRESS } from './config';
import { Chip, Icon } from './Icons';
import { WalletButton, useWallet } from './Wallet';
import { Modal } from './Modal';
import { useTransactions } from './transactions';
import { Fees, Winners } from './History';
import { RoundTools } from './RoundTools';

const navItems = [
  { href: '#jackpot', label: 'Jackpot', icon: 'jackpot' },
  { href: '#dashboard', label: 'My dashboard', icon: 'dashboard' },
  { href: '#activity', label: 'Activity', icon: 'activity' },
  { href: '#how-to-play', label: 'How to play', icon: 'help' },
] as const;

export default function App() {
  const wallet = useWallet();
  const gameQuery = useGame();
  const game = gameQuery.data;
  const playerQuery = usePlayer(wallet.address, game);
  const player = playerQuery.data;
  const tx = useTransactions();
  const [clock, setClock] = useState(Date.now());
  const [quantity, setQuantity] = useState('1');
  const [fieldError, setFieldError] = useState('');
  const [review, setReview] = useState<{ count: bigint; cost: bigint; roundId: bigint }>();
  const [hash, setHash] = useState(location.hash || '#jackpot');
  const quantityRef = useRef<HTMLInputElement>(null);
  useEffect(() => { const id = setInterval(() => setClock(Date.now()), 1_000); return () => clearInterval(id); }, []);
  useEffect(() => { const listener = () => setHash(location.hash || '#jackpot'); window.addEventListener('hashchange', listener); return () => window.removeEventListener('hashchange', listener); }, []);
  const now = game ? game.chainTime + Math.max(0, Math.floor((clock - game.fetchedAt) / 1_000)) : clock / 1_000;
  const timer = countdown(game?.round, now);
  const stale = !game || gameQuery.isError || clock - game.fetchedAt > 60_000;
  const wrongChain = !!wallet.address && wallet.chainId !== 1;
  const blocked = !!game && entryReason(game.round, game.configured, game.paused, now);
  const countResult = ticketCount(quantity);
  const cost = countResult.count && game?.ticketPrice ? countResult.count * game.ticketPrice : undefined;
  const finalized = game?.round.status === 1 && timer.seconds === 0;
  const active = game?.round.status === 1 && timer.seconds > 0;
  const drawing = game?.round.status === 2;
  const launchPending = !!game && !game.configured;
  const actionDisabled = tx.busy || stale || wrongChain;
  const statusLabel = !game ? 'Connecting' : stale ? 'Read unavailable' : launchPending ? 'Awaiting setup' : game.paused ? 'Entries paused' : drawing ? 'Drawing winners' : finalized ? 'Ready to draw' : active ? 'Round live' : 'Table open';
  const canClaim = !!player && player.claimable > 0n && !actionDisabled;
  const buyLabel = tx.busy ? 'Transaction in progress…' : !wallet.address ? 'Buy tickets' : wrongChain ? 'Switch to Ethereum' : launchPending ? 'Awaiting game setup' : game?.paused ? 'Entries paused' : blocked ? 'Tickets closed' : 'Buy tickets';

  function submitTickets(event: FormEvent) {
    event.preventDefault();
    const parsed = ticketCount(quantity);
    if (parsed.error) { setFieldError(parsed.error); quantityRef.current?.focus(); return; }
    setFieldError('');
    if (!wallet.address) { wallet.openWallet(); return; }
    if (wrongChain) { void wallet.switchNetwork(); return; }
    if (!game || stale) { setFieldError('Live round data is unavailable. Refresh the round and try again.'); return; }
    if (blocked) { setFieldError(blocked); return; }
    if (!player || player.balance === undefined) { setFieldError('Your IMD balance could not be read. Retry your balance below.'); return; }
    const nextCost = parsed.count! * game.ticketPrice;
    if (player.balance < nextCost) { setFieldError('Not enough IMD. Choose fewer tickets or add IMD to your wallet.'); return; }
    setReview({ count: parsed.count!, cost: nextCost, roundId: game.roundId });
  }
  const changeCount = (next: string) => { setQuantity(next); setFieldError(''); };
  const closeTransaction = () => {
    tx.setVisible(false);
    requestAnimationFrame(() => document.querySelector<HTMLButtonElement>('.transaction-banner')?.focus());
  };

  return <>
    <a className="skip-link" href="#main">Skip to content</a>
    <aside className="sidebar">
      <a href="#jackpot" className="brand" aria-label="IMDPot home"><Chip/><span>IMD<span className="brand-light">Pot</span><span className="brand-dot">.</span></span></a>
      <nav aria-label="Main navigation">{navItems.map(item => <a key={item.href} href={item.href} className={hash === item.href ? 'active' : ''} aria-current={hash === item.href ? 'location' : undefined}><Icon name={item.icon}/>{item.label}{item.href === '#jackpot' && <span className="nav-dot"/>}</a>)}</nav>
      <div className="sidebar-bottom"><div className="casino-mark" aria-hidden="true"><Chip/><span>Good luck<br/>at the table.</span></div><a href={`${EXPLORER}/address/${POT_ADDRESS}#code`} target="_blank" rel="noreferrer"><Icon name="shield" size={16}/>View contract<Icon name="external" size={14}/></a></div>
    </aside>
    <div className="app-shell">
      <header className="topbar">
        <a href="#jackpot" className="brand mobile-brand" aria-label="IMDPot home"><Chip/><span>IMDPot<span className="brand-dot">.</span></span></a>
        <span className="room-label"><span className="status-dot"/>The jackpot room</span>
        <div className="topbar-actions"><span className="network"><Icon name="ethereum" size={17}/>Ethereum</span><WalletButton/></div>
      </header>
      <nav className="mobile-nav" aria-label="Section navigation">{navItems.map(item => <a key={item.href} href={item.href} aria-current={hash === item.href ? 'location' : undefined}>{item.href === '#dashboard' ? 'Dashboard' : item.label}</a>)}</nav>
      <main id="main">
        <div className="page-heading" id="jackpot"><div><h1>A little IMD. Big possibility.</h1><p>15-minute jackpots. One ticket starts it all.</p></div><a href="#how-to-play" className="text-link"><Icon name="help" size={17}/>How it works</a></div>
        {(gameQuery.isError || (game && stale)) && <div className="notice error-notice" role="alert"><Icon name="info"/><div><strong>Live reads are unavailable</strong><p>{gameQuery.error ? readableError(gameQuery.error) : 'The last read is over a minute old. Transactions are disabled until data refreshes.'}</p></div><button className="button secondary" onClick={() => void gameQuery.refetch()} disabled={gameQuery.isFetching}>{gameQuery.isFetching ? 'Retrying…' : 'Retry connection'}</button></div>}
        {tx.state && !tx.visible && <button className={`transaction-banner ${tx.state.phase}`} onClick={() => tx.setVisible(true)}><Icon name={tx.state.phase === 'success' ? 'check' : 'info'}/><span>{tx.state.title}: {tx.state.phase === 'pending' ? 'in progress' : tx.state.phase === 'success' ? 'confirmed' : 'needs attention'}</span><Icon name="arrow" size={17}/></button>}

        <div className="play-grid">
          <section className="jackpot-panel panel" aria-labelledby="round-heading">
            <div className="round-heading"><h2 id="round-heading">Round {game ? `#${integer(game.roundId)}` : '…'}</h2><span className={`status-label ${active ? 'is-live' : ''}`}><span className="status-dot"/>{statusLabel}</span></div>
            <div className="pool-display"><div className="pool-data"><span className="pool-label">Total pool</span><div className="pool-amount"><span title={game ? exactAmount(game.round.pool, game.decimals) : undefined}>{amount(game?.round.pool, game?.decimals, 2)}</span><span className="pool-unit">IMD</span></div><span className="prize-caption"><Icon name="trophy" size={16}/>70% goes to winning tickets</span></div><div className="chip-art" aria-hidden="true"><div className="orbit orbit-one"/><div className="orbit orbit-two"/><Chip className="art-chip back-chip"/><Chip className="art-chip front-chip"/><svg className="art-spark spark-one" viewBox="0 0 20 20"><path d="m10 0 2 8 8 2-8 2-2 8-2-8-8-2 8-2Z" fill="currentColor"/></svg><svg className="art-spark spark-two" viewBox="0 0 20 20"><path d="m10 0 2 8 8 2-8 2-2 8-2-8-8-2 8-2Z" fill="currentColor"/></svg></div></div>
            <div className="round-bottom"><div className="timer-block"><span className="timer-icon"><Icon name="clock" size={22}/></span><div><span className="countdown" role="timer" aria-label={`${timer.text}, ${timer.label}`}>{timer.text}</span><span className="small muted timer-label">{timer.label}</span></div></div><dl className="round-stats"><div><dt><Icon name="ticket" size={15}/>Tickets</dt><dd>{integer(game?.round.totalTickets)}</dd></div><div><dt><Icon name="people" size={15}/>Players</dt><dd>{integer(game?.round.participantCount)}</dd></div></dl></div>
            <div className="round-progress" role="progressbar" aria-label="Round time remaining" aria-valuemin={0} aria-valuemax={900} aria-valuenow={timer.seconds} aria-valuetext={timer.label}><span style={{ width: `${Math.min(timer.seconds / 900 * 100, 100)}%` }}/></div>
          </section>

          <section className="ticket-panel panel" aria-labelledby="ticket-heading">
            <div className="section-head"><h2 id="ticket-heading">Take your seat</h2><Icon name="ticket" className="muted" size={22}/></div>
            <form onSubmit={submitTickets} noValidate>
              <div className="field-label"><label htmlFor="ticket-quantity">Number of tickets</label><span className="small muted">0.1 IMD each</span></div>
              <div className={`quantity-control ${fieldError ? 'invalid' : ''}`}><button type="button" aria-label="Remove one ticket" disabled={!countResult.count || countResult.count <= 1n || tx.busy} onClick={() => changeCount((countResult.count! - 1n).toString())}><Icon name="minus" size={18}/></button><input ref={quantityRef} id="ticket-quantity" name="tickets" type="text" maxLength={12} inputMode="numeric" autoComplete="off" value={quantity} onChange={event => changeCount(event.target.value)} aria-invalid={!!fieldError} aria-describedby="quantity-hint ticket-error" disabled={tx.busy}/><button type="button" aria-label="Add one ticket" disabled={tx.busy || !!countResult.count && countResult.count >= 1_000_000n} onClick={() => changeCount((countResult.count ? countResult.count + 1n : 1n).toString())}><Icon name="plus" size={18}/></button></div>
              <div className="quick-picks" aria-label="Ticket presets">{[1, 10, 50, 100].map(count => <button type="button" key={count} aria-pressed={quantity === String(count)} aria-label={`${count} ${count === 1 ? 'ticket' : 'tickets'}`} onClick={() => changeCount(String(count))} disabled={tx.busy}>{count}</button>)}</div>
              <div className="cost-row"><span>Total entry</span><strong title={cost !== undefined ? exactAmount(cost, game?.decimals) : undefined}>{cost !== undefined ? amount(cost, game?.decimals) : launchPending ? amount((countResult.count ?? 1n) * 10n ** 17n) : '—'} <span>IMD</span></strong></div>
              <button className="button primary buy-button" type="submit" disabled={tx.busy || !!wallet.address && !wrongChain && (!!blocked || stale)}><Icon name="ticket" size={18}/>{buyLabel}<Icon name="arrow" size={18}/></button>
              <p id="quantity-hint" className="small muted ticket-hint">{!wallet.address ? 'Connect your wallet to play. Minimum 0.1 IMD.' : player?.balance !== undefined ? `Balance: ${amount(player.balance, game?.decimals)} IMD · ETH gas extra` : launchPending ? 'IMD is not configured on the game yet.' : 'Reading your IMD balance…'}</p>
              <p className="small muted my-tickets">{wallet.address && player ? `Your tickets this round: ${integer(player.tickets)}` : ''}</p><p id="ticket-error" className="inline-error" role="alert">{fieldError}</p>
              {wallet.address && playerQuery.isError && <button type="button" className="text-button" onClick={() => void playerQuery.refetch()}>Retry your balance</button>}
            </form>
          </section>
        </div>
        {launchPending && <div className="launch-note"><Icon name="info" size={17}/><p>The table is getting ready. Entries open once the owner configures IMD and randomness.</p></div>}
        {game?.paused && <div className="notice" role="status"><Icon name="info"/><p>New entries and finalization are paused. Claims and eligible refunds remain available.</p></div>}

        <section className="payout-section" aria-label="Pool distribution"><div className="payout-title"><Icon name="trophy" size={20}/><span>Every IMD has a destination.</span></div><div className="payout-items"><div><span className="podium first">1</span><span>1st prize<strong>40%</strong></span></div><div><span className="podium second">2</span><span>2nd prize<strong>20%</strong></span></div><div><span className="podium third">3</span><span>3rd prize<strong>10%</strong></span></div><div><Icon name="flame" className="burn"/><span>Burned<strong>10%</strong></span></div><div><Icon name="lock"/><span>Locked<strong>15%</strong></span></div><div><Icon name="wallet"/><span>House<strong>5%</strong></span></div></div></section>
        <section className="finalize-strip" aria-label="Finalize the current round"><span className="finalize-icon"><Icon name={drawing ? 'clock' : 'shield'} size={23}/></span><div><h2>{drawing ? 'The draw is in motion' : finalized ? 'Time’s up. Call the draw.' : 'Anyone can finalize a closed round'}</h2><p>{drawing ? 'Chainlink VRF has been requested. Settlement opens the next round.' : 'Finalize requests randomness. The callback selects winners and releases prizes.'}</p></div><button className="button secondary" disabled={!finalized || game?.paused || actionDisabled} onClick={() => void tx.action('finalizeRound', 'Finalize round', 'Randomness requested. Prizes become claimable after the draw settles.')}><Icon name="bolt" size={17}/>Finalize round</button></section>

        <div className="dashboard-grid" id="dashboard">
          <section className="panel player-panel" aria-labelledby="dashboard-heading">
            <div className="section-head"><h2 id="dashboard-heading">Your dashboard</h2><span className="small muted">{wallet.address ? shortAddress(wallet.address) : 'A seat with benefits'}</span></div>
            <dl className="player-stats"><div><dt>Rounds played</dt><dd>{integer(player?.roundsPlayed)}</dd></div><div><dt>Loyalty points</dt><dd>{integer(player?.points)}</dd></div><div><dt>Active multiplier</dt><dd>{multiplier(player ? player.tickets > 0n ? player.boost : 0n : undefined)}</dd></div></dl>
            <div className="loyalty-row"><span className="loyalty-icon"><Icon name="bolt" size={23}/></span><div><h3>Make your next round count</h3><p>{wallet.address ? `Queued multiplier: ${multiplier(player?.pendingBoost)}. Redeem 100 points for +25% ticket weight.` : 'Connect to see your points and multiplier.'}</p></div></div>
            <div className="loyalty-footer"><span className="small muted">Unlocks after 10 settled rounds. Caps at 2×.</span>{wallet.address ? <button className="button secondary" disabled={!player?.canRedeem || actionDisabled} onClick={() => void tx.action('redeemMultiplier', 'Redeem multiplier', '100 loyalty points redeemed for +25% weight on the next round you enter.')}>Redeem 100 points<Icon name="arrow" size={15}/></button> : <button className="button secondary" onClick={wallet.openWallet}>View my dashboard<Icon name="arrow" size={15}/></button>}</div>
            {playerQuery.isError && <p className="inline-error" role="alert">Your dashboard could not be loaded. <button className="text-button" onClick={() => void playerQuery.refetch()}>Retry dashboard</button></p>}
          </section>
          <section className="panel claim-panel" aria-labelledby="claim-heading"><div className="section-head"><h2 id="claim-heading">Your winnings</h2><Icon name="trophy" size={22}/></div><p className="muted">Claimable prizes</p><div className="claim-amount" title={player ? exactAmount(player.claimable, game?.decimals) : undefined}>{amount(player?.claimable, game?.decimals)}<span>IMD</span></div><p className="small muted">{wallet.address ? player && player.claimable > 0n ? 'A good day at the table. Your prize is ready.' : 'All your unclaimed prizes appear here.' : 'Connect your wallet to check your prizes.'}</p><button className="button secondary full" onClick={wallet.address ? () => void tx.action('claim', 'Claim prizes', 'Your claim is confirmed. IMD has been sent to your wallet.') : wallet.openWallet} disabled={!!wallet.address && !canClaim}><Icon name="wallet" size={17}/>{wallet.address ? 'Claim prizes' : 'Check my winnings'}<Icon name="arrow" size={16}/></button></section>
        </div>
        <div className="history-grid"><Winners game={game}/><Fees game={game}/></div>
        <section className="how-section" id="how-to-play" aria-labelledby="how-heading"><div className="how-heading"><h2 id="how-heading">How the game works</h2><span>No crying in the casino.</span></div><div className="how-grid"><div><span className="step-number">01</span><h3>Bring your IMD</h3><p>Each ticket costs 0.1 IMD. Buy whole tickets; the first purchase starts a 15-minute round. Later entries never reset the clock.</p></div><div><span className="step-number">02</span><h3>Let the round play out</h3><p>Once time is up, anyone can finalize. Chainlink VRF draws three tickets without replacement. The owner configures the coordinator.</p></div><div><span className="step-number">03</span><h3>Take your winnings</h3><p>Winners claim 40%, 20% and 10% of the pool. With fewer than three tickets, unfilled prizes roll into first place. Every settled ticket earns one loyalty point.</p></div></div><p className="game-note">Tickets remain in the contract until settlement or an eligible cancellation. The 15% locked share stays in the contract permanently. Network gas is paid in ETH.</p></section>
        <RoundTools game={game} now={now} disabled={actionDisabled} tx={tx}/>
        <footer><a className="footer-brand" href="#jackpot"><Chip/>IMDPot.</a><span className="small muted">{game && !stale ? `Read at Ethereum block ${integer(game.block)}` : 'Ethereum · live contract data'}</span><a className="text-link" href={`${EXPLORER}/address/${POT_ADDRESS}`} target="_blank" rel="noreferrer">View game contract<Icon name="external" size={14}/></a></footer>
      </main>
    </div>
    {review && <Modal title="Review your tickets" onClose={() => setReview(undefined)}><p className="muted">Round #{integer(review.roundId)} · Ethereum</p><dl className="review-details"><div><dt>Tickets</dt><dd>{integer(review.count)}</dd></div><div><dt>Entry total</dt><dd>{exactAmount(review.cost, game?.decimals)} IMD</dd></div><div><dt>Game contract</dt><dd><a href={`${EXPLORER}/address/${POT_ADDRESS}`} target="_blank" rel="noreferrer">{shortAddress(POT_ADDRESS)}<Icon name="external" size={14}/></a></dd></div></dl><p className="small muted">{player?.allowance !== undefined && player.allowance >= review.cost ? 'Your IMD allowance covers this entry. Confirm one purchase transaction.' : 'First approve this exact IMD amount, then confirm your ticket purchase. Approval alone does not enter the round.'} ETH network gas is extra.</p><p className="small muted">70% funds prizes; 10% is burned, 5% goes to the house and 15% is locked forever. Tickets cannot be withdrawn during a round.</p><button className="button primary full" disabled={tx.busy || actionDisabled} onClick={() => { const purchase = review; setReview(undefined); void tx.buy(purchase.count, purchase.roundId, purchase.cost); }}>{player?.allowance !== undefined && player.allowance >= review.cost ? 'Buy tickets' : 'Approve & buy tickets'}<Icon name="arrow" size={18}/></button></Modal>}
    {tx.visible && tx.state && <Modal title={tx.state.title} onClose={closeTransaction}><div className={`transaction-result ${tx.state.phase}`}><span className="result-icon"><Icon name={tx.state.phase === 'success' ? 'check' : tx.state.phase === 'error' ? 'info' : 'clock'} size={28}/></span><h3>{tx.state.phase === 'pending' ? 'Your play is in progress' : tx.state.phase === 'success' ? 'Confirmed on Ethereum' : 'Action not completed'}</h3><p role={tx.state.phase === 'error' ? 'alert' : 'status'}>{tx.state.message}</p></div>{tx.state.hashes.map((txHash, index) => <a className="transaction-link" key={`${txHash}-${index}`} href={`${EXPLORER}/tx/${txHash}`} target="_blank" rel="noreferrer">View transaction {index + 1}<Icon name="external" size={16}/></a>)}{tx.state.phase !== 'pending' && <button className="button secondary full" onClick={closeTransaction}>Back to the table</button>}</Modal>}
  </>;
}
