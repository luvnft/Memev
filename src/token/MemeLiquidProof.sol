// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.26;

import { IMemeLiquidProof } from "./interfaces/IMemeLiquidProof.sol";

/**
 * @title Memeverse Liquidity proof Token
 */
contract MemeLiquidProof is IMemeLiquidProof {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    address public memecoin;
    address public memeverse;
    bool public transferable;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public transferWhiteList; // For memeverse launcher and pair

    modifier onlyMemeverse() {
        require(msg.sender == memeverse, PermissionDenied());
        _;
    }

    constructor(
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals, 
        address _memecoin, 
        address _memeverse
    ) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        memecoin = _memecoin;
        memeverse = _memeverse;

        transferWhiteList[_memeverse] = true;
    }

    function enableTransfer() external override onlyMemeverse {
        require(!transferable, AlreadyEnableTransfer());
        transferable = true;
    }

    function addTransferWhiteList(address account) external override onlyMemeverse {
        transferWhiteList[account] = true;
    }
    
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        address msgSender = msg.sender;
        if (transferable || transferWhiteList[msgSender]) {
            balanceOf[msgSender] -= amount;

            unchecked {
                balanceOf[to] += amount;
            }

            if (to == address(0)) {
                unchecked {
                    totalSupply -= amount;
                }
            }

            emit Transfer(msgSender, to, amount);
        } else {
            revert TransferNotEnable();
        }

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        if (transferable || transferWhiteList[from]) {
            uint256 allowed = allowance[from][msg.sender];

            if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

            balanceOf[from] -= amount;

            unchecked {
                balanceOf[to] += amount;
            }

            if (to == address(0)) {
                unchecked {
                    totalSupply -= amount;
                }
            }

            emit Transfer(from, to, amount);
        } else {
            revert TransferNotEnable();
        }

        return true;
    }

    function mint(address account, uint256 amount) external override onlyMemeverse {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyMemeverse {
        require(balanceOf[account] >= amount, InsufficientBalance());
        _burn(account, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;

        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}
