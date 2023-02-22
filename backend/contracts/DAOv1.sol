// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/opl/Host.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";

import "./Types.sol";

contract DAOv1 is Host {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using TerminationLib for Termination;

    event ProposalClosed(ProposalId id, uint256 topChoice);

    struct Proposal {
        bool active;
        ProposalParams params;
    }

    address public immutable _votingToken;
    mapping(ProposalId => Proposal) public _proposals;
    EnumerableSet.Bytes32Set private _activeProposals;

    constructor(address ballotBox, address votingToken) Host(ballotBox) {
        require(votingToken != address(0), "missing voting token");
        _votingToken = votingToken;
        registerEndpoint("ballotClosed", _oplBallotClosed);
    }

    function createProposal(ProposalParams calldata _params) external returns (ProposalId) {
        bytes32 proposalHash = keccak256(abi.encode(msg.sender, _params));
        ProposalId proposalId = ProposalId.wrap(proposalHash);
        require(_params.numChoices > 0, "no choices");
        require(!_proposals[proposalId].active, "proposal already exists");
        require(!_params.termination.isTerminated(0), "already terminated");
        Proposal storage proposal = _proposals[proposalId];
        proposal.params = _params;
        proposal.active = true;
        _activeProposals.add(proposalHash);
        return proposalId;
    }

    function pushVoteWeight(address whom, uint256 snapshotId) external {
        ERC20Snapshot snap = ERC20Snapshot(_votingToken);
        postMessage(
            "voteWeight",
            abi.encode(
                snapshotId,
                whom,
                snap.balanceOfAt(whom, snapshotId),
                snap.totalSupplyAt(snapshotId)
            )
        );
    }

    function getActiveProposals(uint256 _offset, uint256 _count)
        external
        view
        returns (ProposalId[] memory)
    {
        ProposalId[] memory ids = new ProposalId[](_count);
        for (uint256 i; i < _count; ++i) {
            ids[i] = ProposalId.wrap(_activeProposals.at(_offset + i));
        }
        return ids;
    }

    function _oplBallotClosed(bytes calldata _args) internal returns (Result) {
        (ProposalId proposalId, uint256 topChoice) = abi.decode(_args, (ProposalId, uint256));
        _activeProposals.remove(ProposalId.unwrap(proposalId));
        delete _proposals[proposalId];
        emit ProposalClosed(proposalId, topChoice);
        return Result.Success;
    }
}
