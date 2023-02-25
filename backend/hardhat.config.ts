import { promises as fs } from 'fs';
import path from 'path';

import canonicalize from 'canonicalize';
import { TASK_COMPILE } from 'hardhat/builtin-tasks/task-names';
import { HardhatUserConfig, task } from 'hardhat/config';

import '@oasisprotocol/sapphire-hardhat';
import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import 'hardhat-watcher';
import 'solidity-coverage';

const TASK_EXPORT_ABIS = 'export-abis';

task(TASK_COMPILE, async (_args, hre, runSuper) => {
  await runSuper();
  await hre.run(TASK_EXPORT_ABIS);
});

task(TASK_EXPORT_ABIS, async (_args, hre) => {
  const srcDir = path.basename(hre.config.paths.sources);
  const outDir = path.join(hre.config.paths.root, 'abis');

  const [artifactNames] = await Promise.all([
    hre.artifacts.getAllFullyQualifiedNames(),
    fs.mkdir(outDir, { recursive: true }),
  ]);

  await Promise.all(
    artifactNames.map(async (fqn) => {
      const { abi, contractName, sourceName } = await hre.artifacts.readArtifact(fqn);
      if (abi.length === 0 || !sourceName.startsWith(srcDir) || contractName.endsWith('Test'))
        return;
      await fs.writeFile(`${path.join(outDir, contractName)}.json`, `${canonicalize(abi)}\n`);
    }),
  );
});

task('deploy')
  .addOptionalParam('host')
  .setAction(async (args, hre) => {
    await hre.run('compile');
    const ethers = hre.ethers;
    const [BallotBoxV1, DAOv1, VoteToken] = await Promise.all([
      ethers.getContractFactory('BallotBoxV1'),
      ethers.getContractFactory('DAOv1'),
      ethers.getContractFactory('VoteToken'),
    ]);
    const signer = ethers.provider.getSigner();
    const signerAddr = await signer.getAddress();

    // 1. Deploy the VoteToken
    const voteToken = await VoteToken.deploy();
    await voteToken.deployed();
    console.log('VoteToken', voteToken.address);
    await (await voteToken.mint(100)).wait();
    await (await voteToken.snapshot()).wait();

    // 2. Deploy the BallotBox
    // Start by predicting the address of the DAO contract.
    let nonce = 0;
    if (args.host) {
      const hostConfig = hre.config.networks[args.host];
      if (!('url' in hostConfig)) throw new Error(`${args.host} not configured`);
      const provider = new ethers.providers.JsonRpcProvider(hostConfig.url);
      nonce = await provider.getTransactionCount(signerAddr);
    } else {
      nonce = (await signer.getTransactionCount()) + 1;
    }
    const daoAddr = ethers.utils.getContractAddress({ from: signerAddr, nonce });
    const ballotBox = await BallotBoxV1.deploy(daoAddr);
    await ballotBox.deployed();
    console.log('BallotBox', ballotBox.address);

    // 3. Deploy the DAO
    const dao = await DAOv1.deploy(ballotBox.address, voteToken.address);
    await dao.deployed();
    console.log('DAO', dao.address);

    if (daoAddr !== dao.address) throw new Error('BallotBox has the wrong DAO address :(');

    // Populate a poll
    const poll = {
      name: 'A serious poll about serious matters',
      description:
        'This poll seeks to determine the community sentiment about an issue that is very near to our hearts and minds.',
      choices: ['It is acceptable', 'It is tolerable', 'I will not stand for it'],
      snapshot: '0x01',
      termination: { conjunction: 'any', quorum: '0x42' },
      options: { publishVotes: false },
    };
    const proposalParams = {
        ipfsHash: 'bafybeidrh5rz32qzqjd7aupfzymnfdyle37f6acwhyebngfxx25fbp6jsi',
        numChoices: poll.choices.length,
        snapshotId: poll.snapshot,
        termination: {
          ...poll.termination,
          conjunction: poll.termination.conjunction === 'any' ? 1 : 2,
          time: 0,
        },
        publishVotes: poll.options.publishVotes,
    };
    console.log(proposalParams);
    await (await dao.createProposal(proposalParams)).wait();
    await (await ballotBox.createBallot(proposalParams)).wait();
    await (await dao.pushVoteWeight(signerAddr, poll.snapshot)).wait();
  });

const accounts = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];

const config: HardhatUserConfig = {
  networks: {
    hardhat: {
      chainId: 1337, // @see https://hardhat.org/metamask-issue.html
    },
    local: {
      url: 'http://127.0.0.1:8545',
    },
    goerli: {
      url: 'https://goerli.infura.io/v3/813e377eac3a4e74b1f7262b3b20b3c6',
      chainId: 5,
      accounts,
    },
    sepolia: {
      url: 'https://rpc.sepolia.org',
      chainId: 11155111,
      accounts,
    },
    'bsc-testnet': {
      url: 'https://data-seed-prebsc-1-s1.binance.org:8545',
      chainId: 0x61,
      accounts,
    },
    'sapphire-testnet': {
      url: 'https://testnet.sapphire.oasis.dev',
      chainId: 0x5aff,
      accounts,
    },
  },
  solidity: {
    version: '0.8.16',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  watcher: {
    compile: {
      tasks: ['compile'],
      files: ['./contracts/'],
    },
    test: {
      tasks: ['test'],
      files: ['./contracts/', './test'],
    },
    coverage: {
      tasks: ['coverage'],
      files: ['./contracts/', './test'],
    },
  },
  mocha: {
    require: ['ts-node/register/files'],
    timeout: 20_000,
  },
};

export default config;
