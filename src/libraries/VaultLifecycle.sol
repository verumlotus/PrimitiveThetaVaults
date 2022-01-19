// SPDX-License-Identifier: GPL
pragma solidity 0.8.11;
import "primitive/interfaces/IPrimitiveEngine.sol";
import "./ShareMath.sol";

library VaultLifecycle {

    struct openPositionParams {
        address engine; // Address of the primitive engine for the asset/stable pair
        uint256 assetAmt; // asset amount to deposit as LP in RMM Pool
        uint256 stableAmt; // stable amount to deposit as LP in RMM Pool

    }

    function openPosition()
}