// SPDX-License-Identifier: MIT
import "../libraries/ShareMath.sol";
import "../libraries/Vault.sol";
import "../libraries/VaultRollover.sol";
import "./VaultPrimitiveInteractions.sol";
import "openzeppelin-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract PrimitiveRmm01Vault is VaultPrimitiveInteractions, ERC20Upgradeable {
    using ShareMath for Vault.DepositReceipt;

    /************************************************
     *  STORAGE
    ***********************************************/

    /// @notice Stores the user's pending deposit for the round
    mapping(address => Vault.DepositReceipt) public depositReceipts;

    /// @notice On every round's close, the assetPerShare value is recorded
    /// This is used to determine the number of shares to be returned
    /// to a user with their DepositReceipt.depositAmount
    mapping(uint256 => uint256) public roundPricePerShare;

    /// @notice Stores pending user withdrawals
    mapping(address => Vault.Withdrawal) public withdrawals;

    /// @notice Vault's parameters like cap, decimals
    Vault.VaultParams public vaultParams;

    /// @notice Vault's lifecycle state like round and locked amounts
    Vault.VaultState public vaultState;

    /// @notice Fee recipient for the performance and management fees
    address public feeRecipient;

    /// @notice Performance fee charged on premiums earned in rollToNextOption. Only charged when there is no loss.
    uint256 public performanceFee;

     /// @notice Management fee charged on entire AUM in rollToNextOption. Only charged when there is no loss.
    uint256 public managementFee;

    /// @notice Length of maturity for call options
    uint256 public period;

    /// @notice Amount locked for scheduled withdrawals last week;
    uint256 public lastQueuedWithdrawAssetAmount;

    /************************************************
     *  IMMUTABLES & CONSTANTS
    ***********************************************/

    // Number of weeks per year = 52.142857 weeks * FEE_MULTIPLIER = 52142857
    // Dividing by weeks per year requires doing num.mul(FEE_MULTIPLIER).div(WEEKS_PER_YEAR)
    uint256 private constant WEEKS_PER_YEAR = 52142857;

    /// @notice WETH9 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    address public immutable WETH;

    /// @notice USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    address public immutable USDC;

    // UNISWAP_ROUTER is the contract address of UniswapV3 Router which handles swaps
    // https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/ISwapRouter.sol
    address public immutable UNISWAP_ROUTER;

    // UNISWAP_FACTORY is the contract address of UniswapV3 Factory which stores pool information
    // https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/IUniswapV3Factory.sol
    address public immutable UNISWAP_FACTORY;

    /************************************************
     *  Events & Modifiers
    ***********************************************/

    event Deposit(address indexed account, uint256 amount, uint256 round);

    event InitiateWithdraw(
        address indexed account,
        uint256 shares,
        uint256 round
    );

    event Redeem(address indexed account, uint256 share, uint256 round);

    event ManagementFeeSet(uint256 managementFee, uint256 newManagementFee);

    event PerformanceFeeSet(uint256 performanceFee, uint256 newPerformanceFee);

    event CapSet(uint256 oldCap, uint256 newCap);

    event PeriodSet(uint256 oldPeriod, uint256 newPeriod);

    event Withdraw(address indexed account, uint256 amount, uint256 shares);

    event CollectVaultFees(
        uint256 performanceFee,
        uint256 vaultFee,
        uint256 indexed round,
        address indexed feeRecipient
    );

    /************************************************
     *  Constructor & Initializer
    ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _weth is the Wrapped Ether contract
     * @param _usdc is the USDC contract
     * @param _uniswapRouter is the contract address for UniswapV3 router which handles swaps
     * @param _uniswapFactory is the contract address for UniswapV3 factory
     */
    constructor(
        address _weth, 
        address _usdc, 
        address _uniswapRouter,
        address _uniswapFactory
    ) {
        WETH = _weth;
        USDC = _usdc;  
        UNISWAP_ROUTER = _uniswapRouter;
        UNISWAP_FACTORY = _uniswapFactory;
    }

    /**
     * @notice Initializes the OptionVault contract with storage variables.
    */
    function initialize(
        address _owner,
        address _feeRecipient,
        uint256 _managementFee,
        uint256 _performanceFee,
        uint256 _period,
        string memory _tokenName,
        string memory _tokenSymbol,
        Vault.VaultParams calldata _vaultParams
    ) external initializer {
        // Init VaultPrimitiveInteractions first
        vaultPrimitiveInteractionsInitialize(_owner);
        __ERC20_init(_tokenName, _tokenSymbol);

        feeRecipient = _feeRecipient;
        performanceFee = _performanceFee;
        managementFee = _managementFee * Vault.FEE_MULTIPLIER / WEEKS_PER_YEAR;
        period = _period;
        vaultParams = _vaultParams;

        uint256 assetBalance = IERC20(vaultParams.asset).balanceOf(address(this));
        ShareMath.assertUint104(assetBalance);
        vaultState.lastRoundAssetAmount = uint104(assetBalance);

        vaultState.round = 1;
    }

    /************************************************
     *  Setters
    ***********************************************/

    /**
     * @notice - sets a new period between selling covered calls
     * @param newPeriod - new period (in seconds)
     */
    function setPeriod(uint256 newPeriod) external onlyOwner {
        period = newPeriod;
    }

    /**
     * @notice Sets the new fee recipient
     * @param newFeeRecipient is the address of the new fee recipient
     */
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        feeRecipient = newFeeRecipient;
    }

    /**
     * @notice Sets the management fee for the vault
     * @param newManagementFee is the management fee (6 decimals). ex: 2 * 10 ** 6 = 2%
     */
    function setManagementFee(uint256 newManagementFee) external onlyOwner {
        require(
            newManagementFee < 100 * Vault.FEE_MULTIPLIER,
            "Invalid management fee"
        );

        // We are dividing annualized management fee by num weeks in a year
        uint256 tmpManagementFee =
            newManagementFee * Vault.FEE_MULTIPLIER / WEEKS_PER_YEAR;

        emit ManagementFeeSet(managementFee, newManagementFee);

        managementFee = tmpManagementFee;
    }

    /**
     * @notice Sets the performance fee for the vault
     * @param newPerformanceFee is the performance fee (6 decimals). ex: 20 * 10 ** 6 = 20%
     */
    function setPerformanceFee(uint256 newPerformanceFee) external onlyOwner {
        require(
            newPerformanceFee < 100 * Vault.FEE_MULTIPLIER,
            "Invalid performance fee"
        );

        emit PerformanceFeeSet(performanceFee, newPerformanceFee);

        performanceFee = newPerformanceFee;
    }

    /**
     * @notice Sets a new cap for deposits
     * @param newCap is the new cap for deposits
     */
    function setCap(uint256 newCap) external onlyOwner {
        require(newCap > 0, "!newCap");
        ShareMath.assertUint104(newCap);
        emit CapSet(vaultParams.cap, newCap);
        vaultParams.cap = uint104(newCap);
    }

    /************************************************
     *  VAULT OPERATIONS
    ***********************************************/

    /**
     * @notice Helper function that performs most administrative tasks
     * such as setting next option, minting new shares, getting vault fees, etc.
     * @return newRoundAssetAmount is the new balance used to calculate next option purchase size or collateral size
     * @return queuedWithdrawAssetAmount is the new queued withdraw amount for this round
     */
    function rollToNextOption() external onlyOwner nonReentrant {
        uint256 sharesToMint;
        uint256 performanceFeeInAsset;
        uint256 totalVaultFee;
        uint256 newRoundAssetAmount;
        uint256 queuedWithdrawAssetAmount;
        {
            uint256 newPricePerShare;
            (
                newRoundAssetAmount,
                queuedWithdrawAssetAmount,
                newPricePerShare,
                sharesToMint,
                performanceFeeInAsset,
                totalVaultFee
            ) = VaultRollover.rollover(
                vaultState,
                VaultRollover.RolloverParams(
                    vaultParams.decimals,
                    IERC20(vaultParams.asset).balanceOf(address(this)),
                    totalSupply(),
                    lastQueuedWithdrawAssetAmount,
                    performanceFee,
                    managementFee
                )
            );

            // Finalize the pricePerShare at the end of the round
            uint256 currentRound = vaultState.round;
            roundPricePerShare[currentRound] = newPricePerShare;

            emit CollectVaultFees(
                performanceFeeInAsset,
                totalVaultFee,
                currentRound,
                feeRecipient
            );

            vaultState.totalDepositPending = 0;
            vaultState.round = uint16(currentRound + 1);
        }

        _mint(address(this), sharesToMint);

        if (totalVaultFee > 0) {
            transferAsset(payable(feeRecipient), totalVaultFee);
        }

        lastQueuedWithdrawAssetAmount = queuedWithdrawAssetAmount;

        ShareMath.assertUint104(newRoundAssetAmount);
        vaultState.currentRoundAssetAmount = uint104(newRoundAssetAmount);
        
    }

    /************************************************
     *  DEPOSIT & WITHDRAWALS
    ***********************************************/




}