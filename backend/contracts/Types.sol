// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

error NotTerminated();
error NotActive();

type ProposalId is bytes32;

struct ProposalParams {
    string ipfsHash;
    uint16 numChoices;
    uint32 snapshotId;
    Termination termination;
    bool publishVotes;
}

struct Outcome {
    address payable payee;
    uint128 payment;
}

struct Termination {
    Conjunction conjunction;
    uint32 quorum;
    uint64 time;
}

library TerminationLib {
    function isTerminated(Termination memory t, uint256 totalVotes) internal view returns (bool) {
        bool hasQuorum = t.quorum != 0 && totalVotes >= t.quorum;
        bool hasTimedOut = t.time != 0 && block.timestamp > t.time;
        return
            (t.conjunction == Conjunction.Any && (hasTimedOut || hasQuorum)) ||
            (t.conjunction == Conjunction.All && hasTimedOut && hasQuorum) ||
            t.conjunction == Conjunction.Unknown;
    }
}

enum Conjunction {
    Unknown,
    Any,
    All
}

interface CallProxy {
    function anyCall(
        address _to,
        bytes calldata _data,
        uint256 _toChainID,
        uint256 _flags,
        bytes calldata _extdata
    ) external payable;

    function context() external view returns (address from, uint256 fromChainID, uint256 nonce);

    function executor() external view returns (address executor);
}
