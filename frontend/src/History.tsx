import { useState, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { isAddressEqual, zeroAddress } from 'viem';
import { fetchFees, useRecentRounds, type Game } from './data';
import { amount, exactAmount, integer, shortAddress } from './game';
import { DEPLOYMENT_BLOCK, EXPLORER, POT_ADDRESS, readClient } from './config';
import { Icon } from './Icons';

function Empty({ icon, title, children }: { icon: 'flame' | 'wallet' | 'trophy'; title: string; children: ReactNode }) {
  return <div className="empty-state"><span className="empty-icon"><Icon name={icon} size={25}/></span><h3>{title}</h3><p>{children}</p></div>;
}

export function Fees({ game }: { game: Game | undefined }) {
  const [filter, setFilter] = useState<'all' | 'burn' | 'house'>('all');
  const [end, setEnd] = useState<bigint>();
  const fees = useQuery({ queryKey: ['fees', end?.toString()], enabled: !!game,
    queryFn: async () => fetchFees(end ?? await readClient.getBlockNumber({ cacheTime: 0 })),
    staleTime: 30_000, refetchInterval: end ? false : 30_000, retry: 1 });
  const events = fees.data?.events.filter(log => filter === 'all' || (filter === 'burn' ? isAddressEqual(log.args.to!, game!.burnAddress) : isAddressEqual(log.args.to!, game!.treasury)));
  return <section className="panel activity-panel" id="activity" aria-labelledby="activity-title">
    <div className="section-head"><h2 id="activity-title">Onchain activity</h2><a className="text-link" href={`${EXPLORER}/address/${POT_ADDRESS}#events`} target="_blank" rel="noreferrer">Etherscan<Icon name="external" size={15}/></a></div>
    <div className="filter-group" aria-label="Filter transactions">{(['all', 'burn', 'house'] as const).map(value => <button key={value} aria-pressed={filter === value} onClick={() => setFilter(value)}>{value === 'all' ? 'All transfers' : value === 'burn' ? 'Burns' : 'House fees'}</button>)}</div>
    {fees.isPending ? <p className="loading-row" role="status">Reading recent transfers…</p> : fees.isError ? <div className="error-state"><p>Recent transfers could not be loaded.</p><button className="button secondary" onClick={() => void fees.refetch()}>Retry transfers</button></div> : events?.length ? <ul className="activity-list">{events.slice(0, 20).map(log => {
      const burn = isAddressEqual(log.args.to!, game!.burnAddress);
      return <li key={`${log.transactionHash}-${log.logIndex}`}>
        <span className={`event-icon ${burn ? 'burn' : 'house'}`}><Icon name={burn ? 'flame' : 'wallet'} size={20}/></span>
        <div className="event-description"><strong>{burn ? 'IMD burn' : 'House fee'}{log.deferred ? ' deferred' : ' sent'}</strong><a href={`${EXPLORER}/tx/${log.transactionHash}`} target="_blank" rel="noreferrer">Block {integer(log.blockNumber)}<Icon name="external" size={13}/></a></div>
        <span className="event-amount" title={exactAmount(log.args.amount!, game?.decimals)}>{amount(log.args.amount!, game?.decimals)} IMD</span>
      </li>;
    })}</ul> : <Empty icon={filter === 'house' ? 'wallet' : 'flame'} title={filter === 'burn' ? 'No burns in this window' : filter === 'house' ? 'No house fees in this window' : 'The table is quiet'}>Burns and house fees appear here when rounds settle.</Empty>}
    {fees.data && <div className="history-footer"><span className="small muted">Blocks {integer(fees.data.fromBlock)}–{integer(fees.data.toBlock)}{events && events.length > 20 ? ' · showing 20 newest' : ''}</span><div className="history-actions">{end && <button onClick={() => setEnd(undefined)}>Latest</button>}<button disabled={fees.data.fromBlock <= DEPLOYMENT_BLOCK || fees.isFetching} onClick={() => setEnd(fees.data!.fromBlock - 1n)}>Earlier blocks<Icon name="arrow" size={14}/></button></div></div>}
    <p className="small muted activity-note">Deferred transfers are owed by the contract; they have not been sent.</p>
  </section>;
}

export function Winners({ game }: { game: Game | undefined }) {
  const rounds = useRecentRounds(game);
  const winners = rounds.data?.filter(item => item.round.status === 3).slice(0, 3);
  return <section className="panel winners-panel" aria-labelledby="winners-heading">
    <div className="section-head"><h2 id="winners-heading">Recent winners</h2><span className="small muted">40 / 20 / 10%</span></div>
    {rounds.isPending ? <p className="loading-row">Reading past rounds…</p> : rounds.isError ? <div className="error-state"><p>Past rounds could not be loaded.</p><button className="button secondary" onClick={() => void rounds.refetch()}>Retry winners</button></div> : winners?.length ? <div className="winner-rounds">{winners.map(item => <div className="winner-round" key={item.id.toString()}><h3>Round #{integer(item.id)}</h3><ol>{item.round.winners.map((address, index) => !isAddressEqual(address, zeroAddress) && <li key={index}><span className={`podium ${['first', 'second', 'third'][index]}`}>{index + 1}</span><a href={`${EXPLORER}/address/${address}`} target="_blank" rel="noreferrer" title={address}>{shortAddress(address)}<Icon name="external" size={13}/></a><strong title={exactAmount(item.round.prizes[index], game?.decimals)}>{amount(item.round.prizes[index], game?.decimals)} IMD</strong></li>)}</ol></div>)}</div> : <Empty icon="trophy" title="The podium is waiting">Winning tickets appear after the first round settles.</Empty>}
    <p className="small muted history-note">Up to 10 recent rounds. A player can win more than one place.</p>
  </section>;
}
