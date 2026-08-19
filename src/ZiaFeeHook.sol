// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Zia Fee Hook
/// @author Zia
/// @notice Applies bounded, keeper-selected LP fees and collects a bounded fee in the swap's
///         specified currency.
/// @dev The contract has no owner, proxy, upgrade path, pause, or arbitrary fee recipient.
///      Exact-input swaps charge the specified input currency. Exact-output swaps charge the
///      specified output currency. Accrued ERC-6909 claims can only be redeemed to `treasury`.
contract ZiaFeeHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    /// @notice Default LP fee in hundredths of a basis point (0.25%).
    uint24 public constant DEFAULT_LP_FEE = 2_500;

    /// @notice Maximum keeper-selectable LP fee in hundredths of a basis point (1.00%).
    uint24 public constant MAX_LP_FEE = 10_000;

    /// @notice Default hook fee in basis points of the specified swap amount (0.05%).
    uint16 public constant DEFAULT_HOOK_FEE_BPS = 5;

    /// @notice Maximum keeper-selectable hook fee in basis points (0.25%).
    uint16 public constant MAX_HOOK_FEE_BPS = 25;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice The only address that can receive redeemed fee assets.
    address public immutable treasury;

    /// @notice The only address permitted to update bounded per-pool fees.
    address public immutable keeper;

    /// @notice Mutable fee parameters for one initialized pool.
    struct PoolConfig {
        uint24 lpFee;
        uint16 hookFeeBps;
        bool initialized;
    }

    /// @notice Fee configuration keyed by the canonical Uniswap v4 PoolId.
    mapping(PoolId poolId => PoolConfig config) public poolConfigs;

    bool private _collecting;

    error CollectionInProgress();
    error DynamicFeeRequired(uint24 suppliedFee);
    error HookFeeTooLarge(uint16 supplied, uint16 maximum);
    error InvalidKeeper();
    error InvalidPoolManager();
    error InvalidTreasury();
    error LPFeeTooLarge(uint24 supplied, uint24 maximum);
    error NotKeeper(address caller);
    error PoolAlreadyInitialized(PoolId poolId);
    error PoolNotInitialized(PoolId poolId);
    error SwapAmountTooLarge();
    error UnauthorizedUnlock();

    /// @notice Emitted when a dynamic-fee pool is registered under this hook.
    event ZiaPoolInitialized(
        PoolId indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    );

    /// @notice Emitted after the keeper changes a pool's LP fee override.
    event LPFeeChanged(PoolId indexed poolId, uint24 oldFee, uint24 newFee);

    /// @notice Emitted after the keeper changes a pool's hook fee.
    event HookFeeChanged(PoolId indexed poolId, uint16 oldFeeBps, uint16 newFeeBps);

    /// @notice Emitted after nonzero claims are redeemed to treasury as underlying assets.
    event FeesCollected(Currency indexed currency, uint256 amount);

    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    /// @param manager Canonical Uniswap v4 PoolManager for the target chain.
    /// @param treasury_ Immutable recipient of redeemed underlying fee assets.
    /// @param keeper_ Immutable account permitted to update bounded per-pool fees.
    constructor(IPoolManager manager, address treasury_, address keeper_) BaseHook(manager) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
        if (treasury_ == address(0)) revert InvalidTreasury();
        if (keeper_ == address(0)) revert InvalidKeeper();
        treasury = treasury_;
        keeper = keeper_;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Changes one pool's per-swap LP fee override.
    /// @param poolId Pool to update.
    /// @param newFee New LP fee in hundredths of a basis point.
    function setLpFee(PoolId poolId, uint24 newFee) external onlyKeeper {
        if (newFee > MAX_LP_FEE) revert LPFeeTooLarge(newFee, MAX_LP_FEE);

        PoolConfig storage config = poolConfigs[poolId];
        if (!config.initialized) revert PoolNotInitialized(poolId);

        uint24 oldFee = config.lpFee;
        config.lpFee = newFee;
        emit LPFeeChanged(poolId, oldFee, newFee);
    }

    /// @notice Changes one pool's specified-currency hook fee.
    /// @param poolId Pool to update.
    /// @param newFeeBps New hook fee in basis points.
    function setHookFee(PoolId poolId, uint16 newFeeBps) external onlyKeeper {
        if (newFeeBps > MAX_HOOK_FEE_BPS) revert HookFeeTooLarge(newFeeBps, MAX_HOOK_FEE_BPS);

        PoolConfig storage config = poolConfigs[poolId];
        if (!config.initialized) revert PoolNotInitialized(poolId);

        uint16 oldFeeBps = config.hookFeeBps;
        config.hookFeeBps = newFeeBps;
        emit HookFeeChanged(poolId, oldFeeBps, newFeeBps);
    }

    /// @notice Redeems this hook's full ERC-6909 claim balance for `currency` to treasury.
    /// @dev Permissionless and destination-fixed. A zero balance returns silently without unlocking
    ///      PoolManager or emitting an event.
    /// @param currency Currency whose claims will be burned for underlying ERC-20 or native assets.
    /// @return amount Number of claim units redeemed to treasury.
    function collectFees(Currency currency) external returns (uint256 amount) {
        if (_collecting) revert CollectionInProgress();

        amount = poolManager.balanceOf(address(this), currency.toId());
        if (amount == 0) return 0;

        _collecting = true;
        poolManager.unlock(abi.encode(currency, amount));
        _collecting = false;

        emit FeesCollected(currency, amount);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Uses SafeCallback's two-stage pattern: this external entrypoint is PoolManager-gated and
    ///      delegates to an internal callback that additionally requires an active collection.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert DynamicFeeRequired(key.fee);

        PoolId poolId = key.toId();
        if (poolConfigs[poolId].initialized) revert PoolAlreadyInitialized(poolId);

        poolConfigs[poolId] = PoolConfig({lpFee: DEFAULT_LP_FEE, hookFeeBps: DEFAULT_HOOK_FEE_BPS, initialized: true});

        emit ZiaPoolInitialized(poolId, key.currency0, key.currency1, key.tickSpacing, sqrtPriceX96);
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig memory config = poolConfigs[poolId];
        if (!config.initialized) revert PoolNotInitialized(poolId);

        uint24 feeOverride = config.lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        if (config.hookFeeBps == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
        }

        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount;
        if (exactInput) {
            if (params.amountSpecified < -int256(uint256(uint128(type(int128).max)))) revert SwapAmountTooLarge();
            specifiedAmount = uint256(-params.amountSpecified);
        } else {
            if (uint256(params.amountSpecified) > uint256(uint128(type(int128).max))) revert SwapAmountTooLarge();
            specifiedAmount = uint256(params.amountSpecified);
        }

        uint256 hookFee = FullMath.mulDiv(specifiedAmount, config.hookFeeBps, BPS_DENOMINATOR);
        if (hookFee == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
        }
        if (!exactInput && specifiedAmount + hookFee > uint256(uint128(type(int128).max))) {
            revert SwapAmountTooLarge();
        }

        Currency specifiedCurrency = exactInput == params.zeroForOne ? key.currency0 : key.currency1;
        specifiedCurrency.take(poolManager, address(this), hookFee, true);

        // Positive specified delta diverts input from the AMM for exact input and requests extra
        // output from the AMM for exact output. In both cases the hook owns `hookFee` claim units.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(hookFee.toInt128(), 0), feeOverride);
    }

    /// @dev Burns the hook's claims and takes the same underlying amount directly to treasury.
    function _unlockCallback(bytes calldata data) private returns (bytes memory) {
        if (!_collecting) revert UnauthorizedUnlock();

        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, treasury, amount, false);
        return bytes("");
    }

    /// @dev Reverts unless the immutable keeper is calling.
    function _checkKeeper() private view {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
    }
}
