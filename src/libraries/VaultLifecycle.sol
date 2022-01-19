// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "primitive/interfaces/IPrimitiveEngine.sol";
import "./ShareMath.sol";

library VaultLifecycle {

    struct OpenPositionParams {
        // Address of the primitive engine for the asset/stable pair
        address engine;
        // asset amount to deposit as LP in RMM Pool
        uint256 assetAmt;
        // stable amount to deposit as LP in RMM Pool
        uint256 stableAmt; 
        // Strike price of the pool to calibrate to, with the same decimals as the stable token
        uint128 strike; 
        // Implied Volatility to calibrate to as an unsigned 32-bit integer w/ precision of 1e4, 10000 = 100%
        uint32 sigma; 
        // Maturity timestamp of the pool, in seconds
        uint32 maturity;
        // Multiplied against swap in amounts to apply fee, equal to 1 - fee %, an unsigned 32-bit integer, w/ precision of 1e4, 10000 = 100%
        uint32 gamma; 
        // Risky reserve per liq. with risky decimals, = 1 - N(d1), d1 = (ln(S/K)+(r*sigma^2/2))/sigma*sqrt(tau)
        uint256 riskyPerLp;
        // Amount of liquidity to allocate to the curve, wei value with 18 decimals of precision
        uint256 delLiquidity;
    }

    /************************************************
     *  Primitive Callbacks
     ***********************************************/
    /// @notice              Triggered when creating a new pool for an Engine
    /// @param  delRisky     Amount of risky tokens required to initialize risky reserve
    /// @param  delStable    Amount of stable tokens required to initialize stable reserve
    function createCallback(
        uint256 delRisky,
        uint256 delStable,
        bytes calldata // data bytes passed in, unused
    ) external {
        
    }


    // TODO: Implement the call backs for Primitive
}