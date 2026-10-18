import { useState } from 'react';
import { getAddress } from 'viem';
import type { Game } from './data';
import { amount, isOwnerWallet, shortAddress } from './game';
import { EXPLORER, IMD_ADDRESS, POT_ADDRESS } from './config';
import { Icon } from './Icons';
import { Modal } from './Modal';
import { useWallet } from './Wallet';
import type { useTransactions } from './transactions';

type AdminAction = 'pause' | 'unpause' | 'setToken';
export function OwnerPanel({ game, disabled, tx }: { game?: Game; disabled: boolean; tx: ReturnType<typeof useTransactions> }) {
  const wallet = useWallet();
  const [review, setReview] = useState<AdminAction>();
  if (!game || !wallet.isConnected || !isOwnerWallet(wallet.address, game.owner)) return null;
  const future = game.mode === 'future-blockhash';
  const title = review === 'setToken' ? 'Configure IMD permanently' : review === 'pause' ? 'Pause new entries' : 'Resume new entries';
  const addressLink = (address: string) => <a href={`${EXPLORER}/address/${address}`} target="_blank" rel="noreferrer" title={getAddress(address)}>{shortAddress(getAddress(address))}<Icon name="external" size={14}/></a>;
  return <section className="panel owner-panel" id="owner" aria-labelledby="owner-heading">
    <div className="section-head"><div><h2 id="owner-heading">Owner controls</h2><p className="small muted">Connected as the current contract owner.</p></div><Icon name="shield" size={22}/></div>
    <div className="owner-status"><span className="status-label"><span className="status-dot"/>{game.paused ? 'Entries paused' : 'Entries unpaused'}</span><button className="button secondary" disabled={disabled} onClick={() => setReview(game.paused ? 'unpause' : 'pause')}>{game.paused ? 'Unpause contract' : 'Pause contract'}</button></div>
    <dl className="owner-settings">
      <div><dt>Owner</dt><dd>{addressLink(game.owner)}</dd></div>
      <div><dt>Game contract</dt><dd>{addressLink(POT_ADDRESS)}</dd></div>
      <div><dt>IMD token</dt><dd>{game.token ? addressLink(game.token) : 'Not configured'}</dd></div>
      <div><dt>Ticket price</dt><dd>{game.token ? `${amount(game.ticketPrice, game.decimals)} IMD` : '0.1 IMD after setup'}</dd></div>
      <div><dt>Round duration</dt><dd>15 minutes after first ticket</dd></div>
      <div><dt>House fee</dt><dd>5% · {addressLink(game.treasury)}</dd></div>
      <div><dt>Randomness</dt><dd>{future ? 'Future blockhash · 3 blocks ahead' : 'Previous contract · update required'}</dd></div>
      <div><dt>Settlement window</dt><dd>{future ? '256 blocks after target' : 'Unavailable in this version'}</dd></div>
      <div><dt>Game obligations</dt><dd>{amount(game.obligations, game.decimals)} IMD</dd></div>
      <div><dt>Permanently locked</dt><dd>{amount(game.locked, game.decimals)} IMD</dd></div>
    </dl>
    {future ? <div className="owner-setup"><h3>{game.token ? 'Game setup is complete' : 'Set the IMD token'}</h3><p className="small muted">{game.token ? 'No oracle, LINK or subscription is needed. Fees and the draw delay are fixed in the contract.' : 'Set the verified Ethereum IMD token once. This setting cannot be changed.'}</p>{!game.token && <><p className="owner-token-address">{getAddress(IMD_ADDRESS)}</p><button className="button primary" disabled={disabled} onClick={() => setReview('setToken')}>Configure IMD token<Icon name="arrow" size={16}/></button></>}</div> : <div className="owner-setup"><h3>Future-blockhash deployment required</h3><p className="small muted">The live contract cannot be upgraded. The replacement source is ready for a separate deployment; its verified deployment details must be connected before new play opens. Pause, claims and eligible refunds remain available here.</p></div>}
    {review && <Modal title={title} onClose={() => setReview(undefined)}>
      <p className="muted">{review === 'setToken' ? 'This permanently selects the verified Ethereum IMD token for this game. Confirm only after reviewing the token and game addresses.' : review === 'pause' ? `New purchases and new draws will pause.${future ? ' A committed draw can still settle.' : ''} Claims and eligible refunds remain available.` : 'New purchases and draw commitments will resume once the game is configured.'}</p>
      <dl className="review-details"><div><dt>Game</dt><dd>{addressLink(POT_ADDRESS)}</dd></div>{review === 'setToken' && <div><dt>IMD token</dt><dd>{addressLink(IMD_ADDRESS)}</dd></div>}<div><dt>Network</dt><dd>Ethereum</dd></div></dl>
      <button className="button primary full" disabled={disabled} onClick={() => { const action = review; setReview(undefined); void tx.admin(action); }}>{review === 'setToken' ? 'Set IMD token permanently' : review === 'pause' ? 'Pause contract' : 'Unpause contract'}</button>
    </Modal>}
  </section>;
}
