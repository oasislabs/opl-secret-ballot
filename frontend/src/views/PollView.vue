<script setup lang="ts">
import { BigNumber } from 'ethers';
import { computed, ref, watchEffect } from 'vue';
import { ContentLoader } from 'vue-content-loader';

import type { Poll } from '../../functions/api/types';
import type { DAOv1 } from '../contracts';
import { useDAOv1, useBallotBoxV1, useVoteToken } from '../contracts';
import { useEthereumStore } from '../stores/ethereum';

const props = defineProps<{ id: string }>();
const proposalId = `0x${props.id}`;

const daoV1 = useDAOv1();
const ballotBoxV1 = useBallotBoxV1();
const voteToken = useVoteToken();
const eth = useEthereumStore();

const poll = ref<{ proposal: DAOv1.ProposalWithIdStructOutput; ipfsParams: Poll } | undefined>(
  undefined,
);
const winningChoice = ref<number | undefined>(undefined);
(async () => {
  const [active, topChoice, params] = await daoV1.value.read.callStatic.proposals(proposalId);
  const proposal = { id: proposalId, active, topChoice, params };
  const ipfsParamsRes = await fetch(`https://w3s.link/ipfs/${params.ipfsHash}/poll.json`);
  const ipfsParams = await ipfsParamsRes.json();
  // TODO: redirect to 404
  poll.value = { proposal, ipfsParams } as any;
  if (!proposal.active) winningChoice.value = proposal.topChoice;
})();

const existingVote = ref<number | undefined>(undefined);
watchEffect(async () => {
  if (!eth.address) return;
  const { exists, choice } = await ballotBoxV1.value.write!.callStatic.getVoteOf(
    proposalId,
    eth.address!,
  );
  if (exists) existingVote.value = choice;
});

const voteTokenHoldings = ref<BigNumber | undefined>(undefined);
watchEffect(async () => {
  if (!eth.address) return;
  if (!poll.value) return;
  const snapshot = poll.value.ipfsParams.snapshot;
  const balanceAt = await voteToken.value.read.callStatic.balanceOfAt(eth.address, snapshot);
  console.log('balat', balanceAt);
  voteTokenHoldings.value = balanceAt;
});

const canVote = computed(() => {
  if (!eth.address) return false;
  if (winningChoice.value !== undefined) return false;
  if (selectedChoice.value === undefined) return false;
  if ((voteTokenHoldings.value?.toNumber() ?? 0) === 0) return false;
  if (existingVote.value !== undefined) return false;
  return true;
});
const canSelect = computed(() => {
  if (winningChoice.value !== undefined) return false;
  if (eth.address === undefined) return true;
  if ((voteTokenHoldings.value?.toNumber() ?? 0) === 0) return false;
  if (existingVote.value !== undefined) return false;
  return true;
});

const error = ref('');
const selectedChoice = ref<number | undefined>();
const isVoting = ref(false);

async function vote(e: Event): Promise<void> {
  e.preventDefault();
  try {
    error.value = '';
    isVoting.value = true;
    await doVote();
  } catch (e: any) {
    error.value = e.reason ?? e.message;
    // TODO: set current vote
  } finally {
    isVoting.value = false;
  }
}

async function doVote(): Promise<void> {
  await eth.connect();
  if (!ballotBoxV1.value.write) throw new Error('signer not connected');
  if (selectedChoice.value === undefined) throw new Error('no choice selected');
  if (voteTokenHoldings.value?.eq(0) ?? true) throw new Error('insufficient VOTE balance');
  const snapshot = poll.value!.ipfsParams.snapshot;
  const hasPushedVoteWeight = async () =>
    ballotBoxV1.value.read.callStatic.hasPushedVoteWeight(eth.address!, snapshot);
  if (!(await hasPushedVoteWeight())) {
    console.log('pushing vote weight');
    const tx = await daoV1.value.write?.pushVoteWeight(eth.address!, snapshot);
    console.log('submitting pushVoteWeight tx to host in', tx);
    const receipt = await tx?.wait();
    if (receipt?.status !== 1) throw new Error('push vote weight tx failed');
    let hasPushed = false;
    let times = 0;
    while (!hasPushed) {
      console.log('checking if vote weight has been pushed');
      if (times >= 5) throw new Error('failed to push vote weight');
      await new Promise((resolve) => setTimeout(resolve, 5000));
      hasPushed = await hasPushedVoteWeight();
      times++;
    }
    console.log('successfully pushed vote weight');
  }
  const choice = selectedChoice.value;
  const tx = await ballotBoxV1.value.write.castVote(proposalId, choice);
  const receipt = await tx.wait();
  if (receipt.status != 1) throw new Error('cast vote tx failed');
  existingVote.value = choice;

  let topChoice = undefined;
  for (const event of receipt.events ?? []) {
    if (
      event.address == import.meta.env.VITE_BALLOT_BOX_V1_ADDR &&
      event.event === 'BallotClosed'
    ) {
      topChoice = BigNumber.from(event.data).toNumber();
    }
  }
  if (topChoice === undefined) return;
  winningChoice.value = topChoice;
}

eth.connect();
</script>

<template>
  <main style="max-width: 60ch" class="p-5 m-auto">
    <h1 class="font-medium text-3xl mb-4">
      <ContentLoader v-if="!poll?.ipfsParams.name" width="30ch" height="3em">
        <rect x="0" y="0.1em" rx="3" ry="3" width="30ch" height="1.3em" />
      </ContentLoader>
      <span v-else>{{ poll.ipfsParams.name }}</span>
    </h1>
    <p v-if="poll" class="text-gray-500 mb-10" style="height: 3em">
      {{ poll.ipfsParams.description }}
    </p>
    <ContentLoader v-else width="60ch" height="6em">
      <rect x="0" y="0.1em" rx="3" ry="3" width="50ch" height="1.1em" />
      <rect x="0" y="1.4em" rx="3" ry="3" width="45ch" height="1.1em" />
      <rect x="0" y="2.7em" rx="3" ry="3" width="47ch" height="1.1em" />
      <rect x="0" y="4.0em" rx="3" ry="3" width="28ch" height="1.1em" />
    </ContentLoader>
    <h2 class="text-lg font-medium underline">Choices</h2>
    <p v-if="poll?.ipfsParams.options.publishVotes" class="text-orange-600 my-2">
      Votes will be made public after voting has ended.
    </p>
    <form @submit="vote">
      <ul v-if="poll?.ipfsParams.choices">
        <li
          class="choice-input"
          v-for="(choice, choiceId) in poll.ipfsParams.choices"
          :key="choiceId"
          :class="{
            selected: selectedChoice == choiceId,
            won: choiceId === winningChoice,
            lost: winningChoice !== undefined && choiceId !== winningChoice,
          }"
        >
          <label class="inline-block py-6 px-3 pr-4 w-full">
            <input
              tabindex="1"
              name="choice"
              :value="choiceId"
              type="radio"
              :disabled="!canSelect"
              v-model="selectedChoice"
            />
            <span class="inline-block ml-2">{{ choice }}</span>
          </label>
        </li>
      </ul>
      <ContentLoader v-else width="50ch" height="6em">
        <rect x="0" y="0.1em" rx="3" ry="3" width="26ch" height="1.1em" />
        <rect x="0" y="1.4em" rx="3" ry="3" width="33ch" height="1.1em" />
        <rect x="0" y="2.7em" rx="3" ry="3" width="37ch" height="1.1em" />
        <rect x="0" y="4.0em" rx="3" ry="3" width="10ch" height="1.1em" />
      </ContentLoader>
      <p v-if="voteTokenHoldings?.gt(0) && poll?.ipfsParams.termination.quorum">
        You will vote with
        <span class="text-green-700"
          >{{
            voteTokenHoldings
              .mul(100)
              .div(BigNumber.from(poll.ipfsParams.termination.quorum))
              .toNumber()
          }}%
        </span>
        of quorum.
      </p>
      <p v-else-if="voteTokenHoldings?.eq(0)" width="60ch" height="2em" class="text-red-800">
        You may not vote, as you do not hold any VOTE.
      </p>
      <p v-if="error" class="error my-2">
        <span class="font-bold">Error:</span>&nbsp;<span>{{ error.replace('Error: ', '') }}</span>
      </p>
      <button
        tabindex="1"
        class="my-3 border-2 border-blue-800 text-gray-100 rounded-md p-2 bg-blue-600 disabled:border-gray-500 disabled:text-gray-500 disabled:cursor-default disabled:bg-white transition-colors font-bold text-xl"
        :disabled="!canVote || isVoting"
      >
        <span v-if="isVoting">Casting…</span>
        <span v-else>Vote!</span>
      </button>
    </form>
  </main>
</template>

<style lang="postcss" scoped>
.choice-input {
  @apply my-4 border-2 border-black rounded-sm;
}
.choice-input:not(.lost).selected {
  @apply bg-gradient-to-r from-secondary via-transparent;
}
.choice-input.lost {
  @apply bg-gray-300;
}
.choice-input.won {
  @apply bg-secondary;
}
.choice-input * {
  cursor: pointer;
}
</style>
