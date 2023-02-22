// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/opl/Enclave.sol";

import "./Types.sol";

contract BallotBoxV1 is Enclave {
    using TerminationLib for Termination;

    struct Ballot {
        bool active;
        ProposalParams params;
        /// voter -> choice id
        mapping(address => uint256) votes;
        uint256 accumulatedVoteWeight;
        /// choice id -> vote weight, but suitable for gas-efficient iteration.
        uint256[32] weightedVoteCounts;
    }

    struct Snapshot {
        uint256 totalWeight;
        mapping(address => uint256) weights;
    }

    mapping(uint256 => Snapshot) public _snapshots;
    mapping(ProposalId => Ballot) private _ballots;

    constructor(address dao) Enclave(dao, autoswitch("bsc")) {
        registerEndpoint("weights", _oplReceiveVoteWeights);
    }

    function createBallot(ProposalParams calldata params) external {
        ProposalId proposalId = ProposalId.wrap(keccak256(abi.encode(msg.sender, params)));
        require(!_ballots[proposalId].active, "ballot already exists");
        Ballot storage ballot = _ballots[proposalId];
        ballot.params = params;
        ballot.active = true;
        for (uint256 i; i < params.numChoices; ++i) ballot.weightedVoteCounts[i] = 1 << 255; // gas usage side-channel resistance.
    }

    function castVote(ProposalId proposalId, uint256 choiceIdBig) external {
        Ballot storage ballot = _ballots[proposalId];
        uint256 voteWeight = _snapshots[ballot.params.snapshotId].weights[_msgSender()];
        uint8 choiceId = uint8(choiceIdBig & 0xff);
        if (choiceId >= ballot.params.numChoices) revert UnknownChoice();
        if (!ballot.active) revert AlreadyTerminated();
        if (ballot.votes[_msgSender()] != 0) revert AlreadyVoted();
        if (voteWeight == 0) revert NoVoteWeight();
        for (uint256 i; i < ballot.params.numChoices; ++i) {
            // read-modify-write all counts to make it harder to determine which one is chosen.
            ballot.weightedVoteCounts[i] ^= 1 << 255; // flip the top bit to constify gas usage a bit
            ballot.weightedVoteCounts[i] += i == choiceId ? voteWeight : 0; // Addition is not guaranteed to be constant time, so this might still leak the choice to a highly motivated observer.
        }
        ballot.votes[_msgSender()] = choiceId;
        ballot.accumulatedVoteWeight += voteWeight;
    }

    function closeBallot(ProposalId proposalId) external {
        Ballot storage ballot = _ballots[proposalId];
        if (!ballot.params.termination.isTerminated(ballot.accumulatedVoteWeight))
            revert NotTerminated();
        if (!ballot.active) revert AlreadyTerminated();
        uint256 topChoice;
        uint256 topChoiceCount;
        for (uint8 i; i < ballot.params.numChoices; ++i) {
            uint256 choiceVoteCount = ballot.weightedVoteCounts[i] & (type(uint256).max >> 1);
            if (choiceVoteCount > topChoiceCount) {
                topChoice = i;
                topChoiceCount = choiceVoteCount;
            }
        }
        postMessage("ballotClosed", abi.encode(proposalId, topChoice));
        delete _ballots[proposalId];
    }

    function getVoteOf(ProposalId proposalId, address voter)
        external
        view
        returns (uint256 choiceId)
    {
        Ballot storage ballot = _ballots[proposalId];
        if (ballot.active) revert NotTerminated();
        if (ballot.params.publishVotes) revert NotPublishingVotes();
        return ballot.votes[voter];
    }

    /// @dev This function receives vote weights from the home chain. If you're using an oracle to push this data, or a voting token on Sapphire, you don't need this method.
    function _oplReceiveVoteWeights(bytes calldata args) internal returns (Result) {
        (uint256 snapshotId, address whom, uint256 votingPower, uint256 totalVotingPower) = abi
            .decode(args, (uint256, address, uint256, uint256));
        _snapshots[snapshotId].weights[whom] = votingPower;
        _snapshots[snapshotId].totalWeight = totalVotingPower;
        return Result.Success;
    }
}
