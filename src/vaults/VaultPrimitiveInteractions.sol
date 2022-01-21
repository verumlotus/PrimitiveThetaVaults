// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "primitive/interfaces/IPrimitiveEngine.sol";
import "../interfaces/IPrimitiveCallback.sol";
import "../libraries/ShareMath.sol";
import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "../libraries/Vault.sol";
import "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import "openzeppelin-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../libraries/VaultRollover.sol";

/** 
 * Handles logic for interactions between the Vault and Primitive Engines.
 * Follows the upgradeable proxy contract outlined by Openzeppelin and others
 */
contract VaultPrimitiveInteractions is IPrimitiveCallback, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /************************************************
     *  STORAGE
    ***********************************************/

    /// @notice holds state related to the current option the vault is in
    Vault.OptionState optionState;

    /// @notice Path for swaps
    bytes public swapPath;

    // NOTE: Once deployed, no new state variables can be added to this contract, or we will encouter a storage collision

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
     *  Events & Modifiers
    ***********************************************/

    /// @notice - emitted on pool creation
    event PoolCreated(bytes32 indexed poolId, uint256 delLiquidity);

    /// @notice - emitted on closing a position
    event PositionClosed(bytes32 indexed poolId, uint256 delRisky, uint256 delStable);

    modifier onlyEngine() {
        require(msg.sender == engine, "Caller must be engine");
        _;
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

    /**
     * @notice - intializer for state variables the must be set 
     */
    function vaultPrimitiveInteractionsInitialize(
        address _owner
    ) internal initializer {
        __Ownable_init();
        transferOwnership(_owner);
        __ReentrancyGuard_init();
    }

    /************************************************
     *  Position Management
    ***********************************************/

    /**
     * @notice opens a new covered call position with the specified parameters
     * @dev - note that we assume that a pool with these variables have not yet been configured (determined off-chain)
     * @dev - note that we also assume that the owner has rebalanced the vault holdings to an appropriate amount of 
     * asset (risky) and stable (riskless) to maximize the liquidity received from the RMM pool
     * @param params - struct containing config variables for RMM pool
     */
    function openPosition(OpenPositionParams calldata params) public onlyOwner {
        // Ensure that we have closed out of the previous position
        require(optionState.currentPoolId == bytes32(0), "Previous position not closed");
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
        // Since we are creating the pool, the pool will burn MIN_LIQUIDITY at our expense
        optionState.delLiquidity = params.delLiquidity - IPrimitiveEngine(engine).MIN_LIQUIDITY();
        emit PoolCreated(poolId, optionState.delLiquidity);
    }

    /**
     * @notice closes the current covered call position by withdrawing all liquidity from RMM pool
     * @param minRiskyOut minimum amount of risky token we expect - mitigates sandwich attacks
     * @param minStableOut minimum amount of stable token we expect - mitigates sandwich attacks
     */
    function closePosition(uint256 minRiskyOut, uint256 minStableOut) public onlyOwner {
        // First we need to remove our liquidity and transfer it to our margin account within the engine
        (uint256 delRisky, uint256 delStable) = IPrimitiveEngine(engine).remove(optionState.currentPoolId, optionState.delLiquidity);
        // Make sure creatures from the dark forest have not screwed us over
        if (delRisky < minRiskyOut || delStable < minStableOut) {
            revert("Slippage on removal too high");
        }
        // Withdraw asset & stable from margin account and transfer to ourselves
        IPrimitiveEngine(engine).withdraw(address(this), delRisky, delStable);

        emit PositionClosed(optionState.currentPoolId, delRisky, delStable);

        // Reset option State since we are no longer an LP in the RMM pool
        optionState.currentPoolId = bytes32(0);
        optionState.delLiquidity = 0;
    }

    /**
     * @notice Swaps tokens using UniswapV3 router
     * @param tokenIn is the token address to swap
     * @param minAmountOut is the minimum acceptable amount of tokenOut received from swap
     * @param router is the contract address of UniswapV3 router
     */
    function swap(
        address tokenIn,
        uint256 minAmountOut,
        address router
    ) public onlyOwner {
        VaultRollover.swap(
            tokenIn,
            minAmountOut,
            router,
            swapPath
        );
    }

    /**
     * @notice Check if the path set for swap is valid
     * @param _swapPath is the swap path e.g. encodePacked(tokenIn, poolFee, tokenOut)
     * @param validTokenIn is the contract address of the correct tokenIn
     * @param validTokenOut is the contract address of the correct tokenOut
     * @param uniswapFactory is the contract address of UniswapV3 factory
     * @return isValidPath is whether the path is valid
     */
    function checkPath(
        bytes calldata _swapPath,
        address validTokenIn,
        address validTokenOut,
        address uniswapFactory
    ) internal view returns (bool isValidPath) {
        return VaultRollover.checkPath(_swapPath, validTokenIn, validTokenOut, uniswapFactory);
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
    ) external onlyEngine {
        // For the callback, we simply need to transfer the desired amount of assets to the engine 
        IERC20(asset).safeTransfer(engine, delRisky);
        IERC20(stable).safeTransfer(engine, delStable);
    }

    /// @notice              Triggered when depositing tokens to an Engine
    /// @param  delRisky     Amount of risky tokens required to deposit to risky margin balance
    /// @param  delStable    Amount of stable tokens required to deposit to stable margin balance
    function depositCallback(
        uint256 delRisky,
        uint256 delStable,
        bytes calldata // data bytes passed in, unused
    ) external onlyEngine {
        if (delRisky != 0) {
            IERC20(asset).safeTransfer(engine, delRisky);
        }
        if (delStable != 0) {
            IERC20(stable).safeTransfer(engine, delStable);
        }
    }

    /// @notice              Triggered when providing liquidity to an Engine
    /// @param  delRisky     Amount of risky tokens required to provide to risky reserve
    /// @param  delStable    Amount of stable tokens required to provide to stable reserve
    function allocateCallback(
        uint256 delRisky,
        uint256 delStable,
        bytes calldata // data bytes passed in, unused
    ) external onlyEngine {
        IERC20(asset).safeTransfer(engine, delRisky);
        IERC20(stable).safeTransfer(engine, delStable);
    }
}