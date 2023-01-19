// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./Types.sol";

contract DAOv1 {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using TerminationLib for Termination;

    event ProposalClosed(ProposalId id, uint256 topChoice);

    struct Proposal {
        bool active;
        ProposalParams params;
    }

    address public immutable _callProxy;
    uint256 public immutable _ballotBoxChainId;
    mapping(ProposalId => Proposal) public _proposals;
    EnumerableSet.Bytes32Set private _activeProposals;

    constructor(
        address callProxy,
        uint256 ballotBoxChainId
    ) {
        require(callProxy != address(0), "wrong call proxy");
        require(ballotBoxChainId == 0x5aff || ballotBoxChainId == 0x5afe, "wrong ballot box chain");
        _callProxy = callProxy;
        _ballotBoxChainId = ballotBoxChainId;
    }

    function createProposal(ProposalParams calldata params) external returns (ProposalId) {
        bytes32 proposalHash = keccak256(abi.encode(msg.sender, params));
        ProposalId proposalId = ProposalId.wrap(proposalHash);
        require(params.numChoices > 0, "no choices");
        require(!_proposals[proposalId].active, "proposal already exists");
        require(!params.termination.isTerminated(0), "already terminated");
        Proposal storage proposal = _proposals[proposalId];
        proposal.params = params;
        proposal.active = true;
        _activeProposals.add(proposalHash);
        return proposalId;
    }

    function anyExecute(bytes calldata data) external returns (bool success, bytes memory result) {
        (ProposalId proposalId, uint256 topChoice) = abi.decode(data, (ProposalId, uint256));
        (address from, uint256 fromChainId, ) = CallProxy(_callProxy).context();
        require(from == _proposals[proposalId].params.ballotBox, "wrong caller");
        require(fromChainId == _ballotBoxChainId, "wrong chain id");
        delete _proposals[proposalId];
        _activeProposals.remove(ProposalId.unwrap(proposalId));
        success = true;
        result = "";
        emit ProposalClosed(proposalId, topChoice);
    }

    function getActiveProposals(uint256 offset, uint256 count)
        external
        view
        returns (ProposalId[] memory)
    {
        ProposalId[] memory ids = new ProposalId[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = ProposalId.wrap(_activeProposals.at(offset + i));
        }
        return ids;
    }
}
