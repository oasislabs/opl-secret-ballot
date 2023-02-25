<script setup lang="ts">
import { BigNumber } from 'ethers';
import { ref } from 'vue';
import { useRouter } from 'vue-router';

import { useDAOv1, useBallotBoxV1, useVoteToken } from '../contracts';
import { Network, useEthereumStore } from '../stores/ethereum';
import type { Poll } from '../types';

const router = useRouter();
const eth = useEthereumStore();
const dao = useDAOv1();
const voteToken = useVoteToken();
const ballotBox = useBallotBoxV1();

const errors = ref<string[]>([]);
const pollName = ref('A serious poll about serious matters');
const pollDesc = ref(
  'This poll seeks to determine the community sentiment about an issue that is very near to our hearts and minds.',
);
const choices = ref(['It is acceptable', 'It is tolerable', 'I will not stand for it']);
const terminationConjunction = ref('any');
const terminationDurationFlag = ref(false);
const terminationDuration = ref<number | undefined>();
const terminationQuorumFlag = ref(true);
const terminationQuorum = ref<number | undefined>(66);
const hasTerminationConditionErr = ref(false);
const publishVotes = ref(false);
const creating = ref(false);

const removeChoice = (i: number) => choices.value.splice(i, 1);
const addChoice = () => choices.value.push('');

async function createPoll(e: Event): Promise<void> {
  if (e.target instanceof HTMLFormElement) {
    e.target.checkValidity();
    if (!e.target.reportValidity()) return;
  }
  e.preventDefault();
  try {
    errors.value.splice(0, errors.value.length);
    creating.value = true;
    const proposalId = await doCreatePoll();
    if (!proposalId) return;
    router.push({ name: 'poll', params: { id: proposalId } });
  } catch (e: any) {
    errors.value.push(`Failed to create poll: ${e.message ?? JSON.stringify(e)}`);
    console.error(e);
  } finally {
    creating.value = false;
  }
}

async function doCreatePoll(): Promise<string> {
  if (!terminationDurationFlag.value && !terminationQuorumFlag.value) {
    errors.value.push('At least one termination condition must be selected.');
    hasTerminationConditionErr.value = true;
  }
  if (terminationDurationFlag.value) {
    if (!terminationDuration.value || new Date(terminationDuration.value).getMinutes()) {
      errors.value.push('Termination time must be ≥1.');
      hasTerminationConditionErr.value = true;
    }
  }
  if (terminationQuorumFlag.value) {
    if (!terminationQuorum.value || terminationQuorum.value <= 0 || terminationQuorum.value > 100) {
      errors.value.push('Termination quorum must be a percentage.');
      hasTerminationConditionErr.value = true;
    }
  }
  if (errors.value.length > 0) return '';
  await eth.connect();

  let terminationTime: number | undefined;
  let terminationVoteWeight: BigNumber | undefined;
  if (terminationDurationFlag.value) {
    terminationTime = Math.round(Date.now() / 1000) + terminationDuration.value! * 60 * 60;
  }
  const snapshotId = await voteToken.value.read.callStatic.getCurrentSnapshotId();
  if (terminationQuorum.value) {
    const totalVoteWeight = await voteToken.value.read.callStatic.totalSupplyAt(snapshotId);
    const quorum = BigNumber.from(terminationQuorum.value);
    terminationVoteWeight = totalVoteWeight.mul(quorum).div(BigNumber.from(100));
  }
  const poll: Poll = {
    creator: eth.address,
    name: pollName.value,
    description: pollDesc.value,
    choices: choices.value,
    snapshot: snapshotId.toHexString(),
    termination: {
      conjunction: terminationConjunction.value,
      time: terminationTime,
      quorum: terminationVoteWeight?.toHexString(),
    },
    options: {
      publishVotes: publishVotes.value,
    },
  };
  const res = await fetch('http://localhost:8788/api/polls', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ poll }),
  });
  const resJson = await res.json();
  if (res.status !== 201) throw new Error(resJson.error);
  const ipfsHash = resJson.ipfsHash;
  const proposalParams = {
    ipfsHash,
    numChoices: choices.value.length,
    snapshotId: poll.snapshot,
    termination: {
      conjunction: poll.termination.conjunction === 'any' ? 1 : 2,
      quorum: terminationVoteWeight ?? 0,
      time: terminationTime ?? 0,
    },
    publishVotes: poll.options.publishVotes,
  };
  // TODO: check if proposal already exists on the host chain and continue if so (idempotence)
  const proposalId = (await dao.value.read.callStatic.createProposal(proposalParams)).slice(2);
  const createProposalTx = await dao.value.write!.createProposal(proposalParams);
  if ((await createProposalTx.wait()).status !== 1)
    throw new Error('createProposal tx receipt reported failure.');
  await eth.switchNetwork(Network.Enclave);
  const createBallotTx = await ballotBox.value.write!.createBallot(proposalParams);
  if ((await createBallotTx.wait()).status !== 1)
    throw new Error('createBallot tx receipt reported failure.');
  return proposalId;
}
</script>

<template>
  <main style="max-width: 60ch" class="py-5 m-auto w-4/5">
    <h2>New Poll</h2>
    <form @submit="createPoll">
      <fieldset>
        <legend>Name</legend>
        <input class="w-3/4" type="text" v-model="pollName" required />
      </fieldset>
      <fieldset>
        <legend>Description</legend>
        <textarea class="p-2 bg-transparent w-full h-full" v-model="pollDesc" required />
      </fieldset>
      <fieldset>
        <legend>Choices</legend>
        <ol class="ml-8 list-decimal">
          <li class="choice-item" v-for="(choice, i) in choices" :key="choice">
            <input type="text" required v-model="choices[i]" />
            <button
              v-if="choices.length > 1"
              class="inline-block text-lg text-gray-500 pl-1"
              :data-ix="i"
              @click.prevent="removeChoice(i)"
            >
              Ⓧ
            </button>
          </li>
        </ol>
        <button class="underline ml-3 my-2 text-gray-700" @click.prevent="addChoice">
          ＋Add choice
        </button>
      </fieldset>
      <fieldset>
        <legend :class="{ error: hasTerminationConditionErr }">Termination Conditions</legend>
        <div class="px-1 mb-3">
          <label>
            Voting will end once
            <select v-model="terminationConjunction">
              <option value="any">any</option>
              <option value="all">all</option>
            </select>
            of the selected conditions are met.
          </label>
        </div>
        <div class="px-3 my-3">
          <input
            id="termination-time"
            type="checkbox"
            value="time"
            v-model="terminationDurationFlag"
          />
          <label class="inline-block mx-3" for="termination-time">Elapsed Time:</label>
          <input
            type="number"
            min="1"
            inputmode="numeric"
            class="w-12"
            placeholder="24"
            v-model="terminationDuration"
          />&nbsp;hour(s)
        </div>
        <div class="px-3 my-3">
          <input
            id="termination-quorum"
            type="checkbox"
            value="quorum"
            v-model="terminationQuorumFlag"
          />
          <label class="inline-block mx-3" for="termination-quorum">Quorum:</label>
          <span
            ><input
              type="number"
              min="1"
              max="100"
              inputmode="numeric"
              class="w-11"
              placeholder="33"
              v-model="terminationQuorum"
            />% of voting power</span
          >
        </div>
      </fieldset>
      <fieldset>
        <legend>Additional Options</legend>
        <ul class="px-3">
          <li class="my-3">
            <input id="publish-votes" type="checkbox" v-model="publishVotes" />
            <label class="inline-block mx-3" for="publish-votes"
              >Publish individual votes after voting has ended.</label
            >
          </li>
        </ul>
      </fieldset>
      <div v-if="errors.length > 0" class="text-red-500 px-3 mt-5 rounded-sm">
        <span class="font-bold">Errors:</span>
        <ul class="list-disc px-8">
          <li v-for="error in errors" :key="error">{{ error }}</li>
        </ul>
      </div>
      <button
        class="my-3 border-2 border-blue-700 text-blue-900 rounded-md p-2"
        :disabled="creating"
      >
        <span v-if="creating">Creating…</span>
        <span v-else>Create Poll</span>
      </button>
    </form>
  </main>
</template>

<style scoped lang="postcss">
.choice-item:first-of-type {
  @apply mt-0;
}

input[type='text'] {
  @apply inline-block text-lg mx-3 bg-transparent;
  border-bottom: 1px solid black;
}

fieldset {
  @apply border-2 p-4 border-gray-800 rounded-sm bg-transparent my-6;
}

legend {
  @apply px-1 font-medium;
}

h2 {
  @apply font-bold text-2xl my-2;
}
</style>
