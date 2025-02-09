// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

import { IMemeLiquidProof } from "./interfaces/IMemeLiquidProof.sol";
import { OutrunERC20PermitInit } from "../common/OutrunERC20PermitInit.sol";
import { OutrunERC20Init, OutrunERC20Votes } from "../common/governance/OutrunERC20Votes.sol";

/**
 * @title Omnichain Memeverse Proof Of Liquidity Token
 */
contract MemeLiquidProof is IMemeLiquidProof, OutrunERC20PermitInit, OutrunERC20Votes {
    address public memecoin;
    address public memeverseLauncher;

    modifier onlyMemeverseLauncher() {
        require(msg.sender == memeverseLauncher, PermissionDenied());
        _;
    }

    function initialize(
        string memory name_, 
        string memory symbol_, 
        uint8 decimals_, 
        address _memecoin, 
        address _memeverseLauncher
    ) external override initializer {
        __OutrunERC20_init(name_, symbol_, decimals_);

        memecoin = _memecoin;
        memeverseLauncher = _memeverseLauncher;
    }
    
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function mint(address account, uint256 amount) external override onlyMemeverseLauncher {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyMemeverseLauncher {
        require(balanceOf(account) >= amount, InsufficientBalance());
        _burn(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override(OutrunERC20Init, OutrunERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(OutrunERC20PermitInit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
