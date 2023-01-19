// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/metatx/ERC2771Context.sol";

import "./Types.sol";

contract BallotBoxV1 is ERC2771Context {
    using TerminationLib for Termination;

    struct Ballot {
        bool active;
        ProposalParams params;
        mapping(address => uint8) votes;
        mapping(uint8 => uint256) voteCounts;
    }

    address public immutable _callProxy;
    uint256 public immutable _daoChainId;
    address public immutable _dao;
    mapping(ProposalId => Ballot) private _ballots;

    constructor(
        address callProxy,
        address gasRelayer,
        uint256 daoChainId,
        address dao
    ) ERC2771Context(gasRelayer) {
        _callProxy = callProxy;
        _dao = dao;
        _daoChainId = daoChainId;
    }

    function createBallot(ProposalParams calldata params) external {
        ProposalId proposalId = ProposalId.wrap(keccak256(abi.encode(msg.sender, params)));
        require(!_ballots[proposalId].active, "ballot already exists");
        require(params.ballotBox == address(this), "wrong ballot box");
        Ballot storage ballot = _ballots[proposalId];
        ballot.params = params;
        ballot.active = true;
        for (uint8 i; i < params.numChoices; ++i) ballot.voteCounts[i + 1] = 1; // gas usage side-channel resistance:
    }

    function castVote(ProposalId proposalId, uint256 choiceIdBig) external {
        Ballot storage ballot = _ballots[proposalId];
        uint8 choiceId = uint8(choiceIdBig & 0xff);
        require(choiceId > 0 && choiceId < ballot.params.numChoices, "unknown choice");
        require(ballot.active, "not active");
        require(ballot.votes[_msgSender()] == 0, "already voted");
        ballot.voteCounts[choiceId] += 1;
    }

    function closeBallot(ProposalId proposalId) external {
        Ballot storage ballot = _ballots[proposalId];
        if (!ballot.active) return;
        uint256 topChoice;
        uint256 topChoiceCount;
        uint256 totalVotes;
        for (uint8 i; i < ballot.params.numChoices; ++i) {
            uint256 choiceVoteCount = ballot.voteCounts[i + 1] - 1;
            totalVotes += choiceVoteCount;
            if (choiceVoteCount > topChoiceCount) {
                topChoice = i;
                topChoiceCount = choiceVoteCount;
            }
        }
        require(ballot.params.termination.isTerminated(totalVotes), "not terminated");
        CallProxy(_callProxy).anyCall(
            _dao,
            abi.encode(proposalId, topChoice),
            _daoChainId,
            2, /* pay fee on destination chain */
            ""
        );
        delete _ballots[proposalId];
    }

    function getVoteOf(ProposalId proposalId, address voter)
        external
        view
        returns (uint8 choiceId)
    {
        Ballot storage ballot = _ballots[proposalId];
        require(ballot.active, "not closed");
        require(ballot.params.publishVotes, "not published");
        return ballot.votes[voter];
    }
}
