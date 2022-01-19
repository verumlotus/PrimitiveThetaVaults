// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "primitive/interfaces/IPrimitiveEngine.sol";
import "../interfaces/IPrimitiveCallback.sol";
import "../libraries/ShareMath.sol";
import "openzeppelin/token/ERC20/IERC20.sol";

/** 
 * Handles logic for interactions between the Vault and Primitive Engines.
 * Follows the upgradeable proxy contract outlined by Openzeppelin and others
 */
contract VaultPrimitiveInteractions is IPrimitiveCallback {

    /************************************************
     *  NON UPGRADEABLE STORAGE
    ***********************************************/

    /************************************************
     *  IMMUTABLES & CONSTANTS
    ***********************************************/

    /// @notice address of the asset (risky asset in context of RMM Pool)
    address immutable asset;

    /// @notice address of the stable asset
    address immutable stable;

    /// @notice address of the Primitive Engine for this asset/stable pair
    address immutable engine;

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
     *  Constructor & Initializer
    ***********************************************/

    /**
     * @notice Initializes immutables & constants
     * @dev - since we follow the upgradeable proxy pattern, this should on initiliaze constants & immutables (never state)
     * @param _asset - address of asset
     * @param _stable - address of stable
     * @param _engine - address of Primitive Engine for specified asset/stable pair
     */
    constructor(
        address _asset, 
        address _stable, 
        address _engine
    ) {
        asset = _asset;
        stable = _stable;
        engine = _engine;
    }

    /************************************************
     *  Position Management
    ***********************************************/

    /**
     * @notice opens a new covered call position with the specified parameters
     * @dev - note that we assume that a pool with this variables has not yet been configured (determined off-chain)
     * @param params - struct containing config variables for RMM pool
     */
    function _openPosition(OpenPositionParams calldata params) internal {
        IPrimitiveEngine engine = IPrimitiveEngine(params.engine);
        (bytes32 poolId, uint256 delRisky, uint256 delStable) = engine.create(
            params.strike,
            params.sigma, 
            params.maturity, 
            params.gamma, 
            params.riskyPerLp, 
            params.delLiquidity, 
            ""
        );
        // TODO: update necessary vault state and emit events? 

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
        // For the callback, we simply need to transfer the desired amount of assets to the engine 
        require(IERC20(asset).transfer(engine, delRisky) == true, "Error transfering risky to engine on create");
        require(IERC20(stable).transfer(engine, delStable) == true, "Error transfering stable to engine on create");
    }

    /// @notice              Triggered when depositing tokens to an Engine
    /// @param  delRisky     Amount of risky tokens required to deposit to risky margin balance
    /// @param  delStable    Amount of stable tokens required to deposit to stable margin balance
    function depositCallback(
        uint256 delRisky,
        uint256 delStable,
        bytes calldata // data bytes passed in, unused
    ) external {
        if (delRisky != 0) {
            require(IERC20(asset).transfer(engine, delRisky) == true, "Error transfering risky to engine on deposit");
        }
        if (delStable != 0) {
            require(IERC20(stable).transfer(engine, delStable) == true, "Error transfering stable to engine on deposit");
        }
    }

    /// @notice              Triggered when providing liquidity to an Engine
    /// @param  delRisky     Amount of risky tokens required to provide to risky reserve
    /// @param  delStable    Amount of stable tokens required to provide to stable reserve
    function allocateCallback(
        uint256 delRisky,
        uint256 delStable,
        bytes calldata // data bytes passed in, unused
    ) external {
        require(IERC20(asset).transfer(engine, delRisky) == true, "Error transfering risky to engine on allocate");
        require(IERC20(stable).transfer(engine, delStable) == true, "Error transfering stable to engine on allocate");
    }
}