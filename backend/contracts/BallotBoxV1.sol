// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Enclave, Result, autoswitch} from "@oasisprotocol/sapphire-contracts/contracts/OPL.sol";

import "./Types.sol"; // solhint-disable-line no-global-import

contract BallotBoxV1 is Enclave {
    using TerminationLib for Termination;

    error NotPublishingVotes();
    error AlreadyVoted();
    error NoVoteWeight();
    error UnknownChoice();

    struct Ballot {
        bool active;
        ProposalParams params;
        /// voter -> choice id
        mapping(address => Choice) votes;
        uint256 accumulatedVoteWeight;
        /// choice id -> vote weight, but suitable for gas-efficient iteration.
        uint256[32] weightedVoteCounts;
    }

    struct Choice {
        bool exists;
        uint8 choice;
    }

    struct Snapshot {
        uint256 totalWeight;
        mapping(address => uint256) weights;
    }

    event BallotClosed(ProposalId indexed id, uint256 topChoice);

    mapping(uint256 => Snapshot) public _snapshots;
    mapping(ProposalId => Ballot) private _ballots;

    constructor(address dao) Enclave(dao, autoswitch("bsc")) {
        registerEndpoint("createBallot", _oplCreateBallot);
        registerEndpoint("voteWeight", _oplReceiveVoteWeights);
    }

    function castVote(
        ProposalId proposalId,
        uint256 choiceIdBig
    ) external payable returns (bool ended) {
        Ballot storage ballot = _ballots[proposalId];
        if (!ballot.active) revert NotActive();
        uint256 voteWeight = _snapshots[ballot.params.snapshotId].weights[_msgSender()];
        uint8 choiceId = uint8(choiceIdBig & 0xff);
        if (choiceId >= ballot.params.numChoices) revert UnknownChoice();
        Choice memory existingVote = ballot.votes[_msgSender()];
        if (voteWeight == 0) revert NoVoteWeight();
        for (uint256 i; i < ballot.params.numChoices; ++i) {
            // read-modify-write all counts to make it harder to determine which one is chosen.
            ballot.weightedVoteCounts[i] ^= 1 << 255; // flip the top bit to constify gas usage a bit
            // Arithmetic is not guaranteed to be constant time, so this might still leak the choice to a highly motivated observer.
            ballot.weightedVoteCounts[i] += i == choiceId ? voteWeight : 0;
            ballot.weightedVoteCounts[i] -= existingVote.exists && existingVote.choice == i
                ? voteWeight
                : 0;
        }
        ballot.votes[_msgSender()].exists = true;
        ballot.votes[_msgSender()].choice = choiceId;
        ballot.accumulatedVoteWeight += voteWeight;
        if (_canCloseBallot(ballot)) {
            _closeBallot(proposalId, ballot);
            return true;
        }
        return false;
    }

    function closeBallot(ProposalId proposalId) external {
        Ballot storage ballot = _ballots[proposalId];
        if (!ballot.params.termination.isTerminated(ballot.accumulatedVoteWeight))
            revert NotTerminated();
        if (!ballot.active) revert NotActive();
        _closeBallot(proposalId, ballot);
    }

    function hasPushedVoteWeight(address voter, uint256 snapshotId) external view returns (bool) {
        return _snapshots[snapshotId].weights[voter] > 0;
    }

    function getVoteOf(ProposalId proposalId, address voter) external view returns (Choice memory) {
        Ballot storage ballot = _ballots[proposalId];
        if (voter == msg.sender) return ballot.votes[msg.sender];
        if (ballot.active) revert NotTerminated();
        if (!ballot.params.publishVotes) revert NotPublishingVotes();
        return ballot.votes[voter];
    }

    function _oplCreateBallot(bytes calldata args) internal returns (Result) {
        (ProposalId id, ProposalParams memory params) = abi.decode(
            args,
            (ProposalId, ProposalParams)
        );
        Ballot storage ballot = _ballots[id];
        ballot.params = params;
        ballot.active = true;
        for (uint256 i; i < params.numChoices; ++i) ballot.weightedVoteCounts[i] = 1 << 255; // gas usage side-channel resistance.
        return Result.Success;
    }

    /// @dev This function receives vote weights from the home chain. If you're using an oracle to push this data, or a voting token on Sapphire, you don't need this method.
    function _oplReceiveVoteWeights(bytes calldata args) internal returns (Result) {
        (uint256 snapshotId, address whom, uint256 votingPower, uint256 totalVotingPower) = abi
            .decode(args, (uint256, address, uint256, uint256));
        _snapshots[snapshotId].weights[whom] = votingPower;
        _snapshots[snapshotId].totalWeight = totalVotingPower;
        return Result.Success;
    }

    function _closeBallot(ProposalId _proposalId, Ballot storage _ballot) internal {
        if (!_canCloseBallot(_ballot)) revert NotTerminated();
        uint256 topChoice;
        uint256 topChoiceCount;
        for (uint8 i; i < _ballot.params.numChoices; ++i) {
            uint256 choiceVoteCount = _ballot.weightedVoteCounts[i] & (type(uint256).max >> 1);
            if (choiceVoteCount > topChoiceCount) {
                topChoice = i;
                topChoiceCount = choiceVoteCount;
            }
        }
        postMessage("ballotClosed", abi.encode(_proposalId, topChoice));
        emit BallotClosed(_proposalId, topChoice);
        delete _ballots[_proposalId];
    }

    function _canCloseBallot(Ballot storage _ballot) internal view returns (bool) {
        return
            _ballot.active &&
            _ballot.params.termination.isTerminated(_ballot.accumulatedVoteWeight);
    }
}
