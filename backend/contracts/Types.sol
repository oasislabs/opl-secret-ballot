// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type ProposalId is bytes32;

struct ProposalParams {
    bytes32 ipfsHash;
    address ballotBox;
    address treasuryToken;
    Outcome[] outcomes;
    Termination termination;
    bool publishVotes;
}

library ParamsLib {
    function maxPayment(ProposalParams memory params) internal pure returns (uint256 payment) {
        for (uint256 i; i < params.outcomes.length; ++i)
            if (params.outcomes[i].payment > payment) payment = params.outcomes[i].payment;
    }
}

struct Outcome {
    address payable payee;
    uint128 payment;
}

struct Termination {
    Quantifier quantifier;
    uint32 quorum;
    uint64 expiry;
}

library TerminationLib {
    function isTerminated(Termination memory t, uint256 totalVotes) internal view returns (bool) {
        return
            (t.quantifier == Quantifier.All &&
                block.timestamp > t.expiry &&
                totalVotes >= t.quorum) ||
            (t.quantifier == Quantifier.Any &&
                (block.timestamp > t.expiry || totalVotes >= t.quorum));
    }
}

enum Quantifier {
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

    function context()
        external
        view
        returns (
            address from,
            uint256 fromChainID,
            uint256 nonce
        );

    function executor() external view returns (address executor);
}
