// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC6909Claims} from "@uniswap/v4-core/interfaces/external/IERC6909Claims.sol";

/**
 * @title ERC6909Base
 * @notice Abstract base contract implementing ERC-6909 functionality
 */
abstract contract ERC6909Base is IERC6909Claims {
    /// @notice ERC-6909 balances per user per currency
    /// @dev Mapping from user => currency ID => balance
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    
    /// @notice ERC-6909 allowances per user per spender per currency
    /// @dev Mapping from owner => spender => currency ID => allowance
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;
    
    /// @notice ERC-6909 operator approvals per user
    /// @dev Mapping from owner => operator => approved
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice Transfers an amount of an id from the caller to a receiver.
    /// @param receiver The address of the receiver.
    /// @param id The id of the token (currency address as uint256).
    /// @param amount The amount of the token.
    /// @return bool True, always, unless the function reverts
    function transfer(address receiver, uint256 id, uint256 amount) external override returns (bool) {
        require(receiver != address(0), "ERC6909: transfer to zero address");
        require(balanceOf[msg.sender][id] >= amount, "ERC6909: insufficient balance");
        
        balanceOf[msg.sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    /// @notice Transfers an amount of an id from a sender to a receiver.
    /// @param sender The address of the sender.
    /// @param receiver The address of the receiver.
    /// @param id The id of the token (currency address as uint256).
    /// @param amount The amount of the token.
    /// @return bool True, always, unless the function reverts
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external override returns (bool) {
        require(receiver != address(0), "ERC6909: transfer to zero address");
        require(balanceOf[sender][id] >= amount, "ERC6909: insufficient balance");
        
        // Check allowance unless caller is the sender or an operator
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            require(allowance[sender][msg.sender][id] >= amount, "ERC6909: insufficient allowance");
            allowance[sender][msg.sender][id] -= amount;
        }
        
        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    /// @notice Approves an amount of an id to a spender.
    /// @param spender The address of the spender.
    /// @param id The id of the token (currency address as uint256).
    /// @param amount The amount of the token.
    /// @return bool True, always
    function approve(address spender, uint256 id, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    /// @notice Sets or removes an operator for the caller.
    /// @param operator The address of the operator.
    /// @param approved The approval status.
    /// @return bool True, always
    function setOperator(address operator, bool approved) external override returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @notice Mint ERC-6909 tokens to a user (internal function for order execution)
    /// @param to The address to mint tokens to
    /// @param currency The currency address
    /// @param amount The amount to mint
    function _mint(address to, address currency, uint256 amount) internal {
        uint256 id = uint256(uint160(currency));
        balanceOf[to][id] += amount;
        emit Transfer(address(0), address(0), to, id, amount);
    }

    /// @notice Burn ERC-6909 tokens from a user (internal function)
    /// @param from The address to burn tokens from
    /// @param currency The currency address
    /// @param amount The amount to burn
    function _burn(address from, address currency, uint256 amount) internal {
        uint256 id = uint256(uint160(currency));
        require(balanceOf[from][id] >= amount, "ERC6909: insufficient balance to burn");
        balanceOf[from][id] -= amount;
        emit Transfer(address(0), from, address(0), id, amount);
    }
}
