// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test stand-in for the $IMD token with switches that simulate hostile token behaviour.
contract MockIMDToken is ERC20 {
    uint8 private immutable _decimals;
    /// @dev Basis points skimmed on every transfer when non-zero (fee-on-transfer simulation).
    uint256 public feeBps;
    /// @dev Addresses whose incoming transfers revert (blocklist simulation).
    mapping(address => bool) public blocked;
    /// @dev When true, every transfer reverts (paused token simulation).
    bool public frozen;

    constructor(uint8 decimals_) ERC20("IMD", "IMD") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setFrozen(bool isFrozen) external {
        frozen = isFrozen;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!frozen, "frozen");
        require(!blocked[to], "blocked");
        if (feeBps != 0 && from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
