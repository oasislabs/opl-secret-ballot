// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VoteToken is ERC20, ERC20Snapshot, Ownable {
    constructor() ERC20("Vote", "VOTE") {} // solhint-disable-line no-empty-blocks

    function snapshot() external onlyOwner {
        _snapshot();
    }

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    /// @dev This modification isn't required if you use an oracle function to get the vote weight and push it into Sapphire. This function is only so that the on-chain DAO can access the snapshot ID for bridging.
    function getCurrentSnapshotId() external view returns (uint256) {
        return _getCurrentSnapshotId();
    }

    // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
    }
}
