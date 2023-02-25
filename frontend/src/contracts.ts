import type { ComputedRef } from 'vue';
import { computed } from 'vue';

import type { BallotBoxV1, DAOv1, VoteToken } from '@oasislabs/secret-ballot-backend';
import {
  BallotBoxV1__factory,
  DAOv1__factory,
  VoteToken__factory,
} from '@oasislabs/secret-ballot-backend';

import { useEthereumStore } from './stores/ethereum';

export type { BallotBoxV1, DAOv1, VoteToken } from '@oasislabs/secret-ballot-backend';

export function useBallotBoxV1(): ComputedRef<{
  read: BallotBoxV1;
  write?: BallotBoxV1;
}> {
  const eth = useEthereumStore();
  const addr = import.meta.env.VITE_BALLOT_BOX_V1_ADDR!;
  return computed(() => {
    const read = BallotBoxV1__factory.connect(addr, eth.provider);
    const write = eth.signer ? BallotBoxV1__factory.connect(addr, eth.signer) : undefined;
    return { read, write };
  });
}

export function useDAOv1(): ComputedRef<{
  read: DAOv1;
  write?: DAOv1;
}> {
  const eth = useEthereumStore();
  const addr = import.meta.env.VITE_DAO_V1_ADDR!;
  return computed(() => {
    const read = DAOv1__factory.connect(addr, eth.provider);
    const write = eth.signer ? DAOv1__factory.connect(addr, eth.signer) : undefined;
    return { read, write };
  });
}

export function useVoteToken(): ComputedRef<{
  read: VoteToken;
  write?: VoteToken;
}> {
  const eth = useEthereumStore();
  const addr = import.meta.env.VITE_VOTE_TOKEN_ADDR!;
  return computed(() => {
    const read = VoteToken__factory.connect(addr, eth.provider);
    const write = eth.signer ? VoteToken__factory.connect(addr, eth.signer) : undefined;
    return { read, write };
  });
}
