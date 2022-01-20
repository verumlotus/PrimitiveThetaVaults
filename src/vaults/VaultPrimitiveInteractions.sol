// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "primitive/interfaces/IPrimitiveEngine.sol";
import "../interfaces/IPrimitiveCallback.sol";
import "../libraries/ShareMath.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "../libraries/Vault.sol";

/** 
 * Handles logic for interactions between the Vault and Primitive Engines.
 * Follows the upgradeable proxy contract outlined by Openzeppelin and others
 */
contract VaultPrimitiveInteractions is IPrimitiveCallback {

    /************************************************
     *  NON UPGRADEABLE STORAGE
    ***********************************************/

    /// @notice holds state related to the current option the vault is in
    Vault.OptionState optionState;

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
     *  Events
    ***********************************************/

    /// @notice - emitted on pool creation
    event poolCreated(bytes32 indexed poolId);

    /// @notice - emitted on closing a position
    event positionClosed(bytes32 indexed poolId, uint256 delRisky, uint256 delStable);

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
        (bytes32 poolId, ,) = IPrimitiveEngine(engine).create(
            params.strike,
            params.sigma, 
            params.maturity, 
            params.gamma, 
            params.riskyPerLp, 
            params.delLiquidity, 
            ""
        );
        optionState.currentPoolId = poolId;
        optionState.delLiquidity = params.delLiquidity;
        emit poolCreated(poolId);
    }

    /**
     * @notice closes the current covered call position by withdrawing all liquidity from RMM pool
     */
    function _closePosition() internal {
        // First we need to remove our liquidity and transfer it to our margin account within the engine
        (uint256 delRisky, uint256 delStable) = IPrimitiveEngine(engine).remove(optionState.currentPoolId, optionState.delLiquidity);
        // Withdraw asset & stable from margin account and transfer to ourselves
        IPrimitiveEngine(engine).withdraw(address(this), delRisky, delStable);

        emit positionClosed(optionState.currentPoolId, delRisky, delStable);

        // Reset option State since we are no longer an LP in the RMM pool
        optionState.currentPoolId = bytes32(0);
        optionState.delLiquidity = 0;
    }

    /**
     * Source: https://github.com/ribbon-finance/ribbon-v2/blob/master/contracts/libraries/VaultLifecycle.sol
     * @notice Calculates the performance and management fee for this week's round
     * @param currentBalance is the balance of funds held on the vault after closing our position
     * @param assetBalanceBeforeRound is the amount of funds held by the vault before entering our position
     * @param pendingDeposits is the pending deposit amount in assets
     * @param performanceFeePercent is the performance fee pct in 6 decimal places; For example: 20 * 10**6 = 20% 
     * @param managementFeePercent is the management fee pct. Also 6 decimal places
     * @return performanceFeeInAsset is the performance fee
     * @return managementFeeInAsset is the management fee
     * @return vaultFee is the total fees
     */
    function _getVaultFees(
        uint256 currentBalance, 
        uint256 assetBalanceBeforeRound,
        uint256 pendingDeposits,
        uint256 performanceFeePercent,
        uint256 managementFeePercent 
    ) internal pure returns (
        uint256 performanceFeeInAsset,
        uint256 managementFeeInAsset,
        uint256 vaultFee
    ) {
        uint256 lockedBalanceSansPending =
            currentBalance > pendingDeposits
                ? currentBalance - pendingDeposits
                : 0;
        
        uint256 _performanceFeeInAsset;
        uint256 _managementFeeInAsset;
        uint256 _vaultFee;

        // Take performance fee and management fee ONLY if difference between
        // last week and this week's vault deposits, taking into account pending
        // deposits and withdrawals, is positive. If it is negative, last week's
        // option expired ITM past breakeven, and the vault took a loss so we
        // do not collect performance fee for last week
        if (lockedBalanceSansPending > assetBalanceBeforeRound) {
            _performanceFeeInAsset = performanceFeePercent > 0
                ? (lockedBalanceSansPending - assetBalanceBeforeRound) * performanceFeePercent / (100 * Vault.FEE_MULTIPLIER)
                : 0;
            _managementFeeInAsset = managementFeePercent > 0
                ? lockedBalanceSansPending * managementFeePercent / (100 * Vault.FEE_MULTIPLIER)
                : 0;

            _vaultFee = _performanceFeeInAsset + _managementFeeInAsset;
        }

        return (_performanceFeeInAsset, _managementFeeInAsset, _vaultFee);
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