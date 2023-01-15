// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./Types.sol";

contract DAOv1 {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;

    using ParamsLib for ProposalParams;
    using TerminationLib for Termination;

    struct Proposal {
        bool active;
        ProposalParams params;
    }

    address public immutable _callProxy;
    uint256 public immutable _ballotBoxChainId;
    address public immutable _votingToken;
    address public immutable _treasuryToken;
    mapping(ProposalId => Proposal) public _proposals;
    EnumerableSet.Bytes32Set private _activeProposals;
    uint256 private _lockedTreasuryTokens;

    constructor(
        address callProxy,
        uint256 ballotBoxChainId,
        address votingToken,
        address treasuryToken
    ) {
        require(callProxy != address(0), "wrong call proxy");
        require(ballotBoxChainId == 0x5aff || ballotBoxChainId == 0x5afe, "wrong ballot box chain");
        require(votingToken != address(0), "wrong voting token");
        require(treasuryToken != address(0), "wrong payment token");
        _callProxy = callProxy;
        _ballotBoxChainId = ballotBoxChainId;
        _votingToken = votingToken;
        _treasuryToken = treasuryToken;
    }

    function createProposal(ProposalParams calldata params) external returns (ProposalId) {
        bytes32 proposalHash = keccak256(abi.encode(msg.sender, params));
        ProposalId proposalId = ProposalId.wrap(proposalHash);
        require(params.outcomes.length > 0, "no choices");
        require(!_proposals[proposalId].active, "proposal already exists");
        require(!params.termination.isTerminated(0), "already terminated");
        uint256 maxPayment = params.maxPayment();
        require(
            IERC20(_treasuryToken).balanceOf(address(this)) - _lockedTreasuryTokens >= maxPayment,
            "insolvent"
        );
        _lockedTreasuryTokens += maxPayment;
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
        ProposalParams memory params = _proposals[proposalId].params;
        Outcome memory outcome = params.outcomes[topChoice];
        if (outcome.payment > 0) {
            IERC20(_treasuryToken).safeTransfer(outcome.payee, outcome.payment);
        }
        _lockedTreasuryTokens -= params.maxPayment();
        delete _proposals[proposalId];
        _activeProposals.remove(ProposalId.unwrap(proposalId));
        success = true;
        result = "";
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
